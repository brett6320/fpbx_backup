#!/usr/bin/env bash
# fpbx-selftest.sh — non-destructive preflight. Verifies the host can actually
# produce (and, where possible, restore) a backup BEFORE you rely on it.
# Exits non-zero if any check fails. Safe to run on a live PBX.
#
# Usage: ./fpbx-selftest.sh [--config PATH]
set -uo pipefail   # NOT -e: we want to run every check and tally results.

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SELF_DIR/lib/common.sh"

CONFIG="${FPBX_BACKUP_CONF:-/etc/fpbx-backup.conf}"
[ "${1:-}" = "--config" ] && { CONFIG="$2"; shift 2; }
load_config "$CONFIG"
. "$SELF_DIR/lib/db.sh"
. "$SELF_DIR/lib/crypto.sh"

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mWARN\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
have() { command -v "$1" >/dev/null 2>&1; }

echo "== fpbx-selftest =="

# --- privileges -------------------------------------------------------------
[ "$(id -u)" = "0" ] && ok "running as root" \
	|| skip "not root — real backups need root to read all files/DB creds"

# --- core tools -------------------------------------------------------------
have tar  && ok "tar present"  || no "tar missing"
have gzip && ok "gzip present" || no "gzip missing"

# GNU tar + incremental support (BSD tar cannot do --listed-incremental).
if tar --version 2>/dev/null | grep -qi 'GNU tar'; then
	ok "GNU tar"
	td="$(mktemp -d)"; : > "$td/f"
	if tar -C "$td" --listed-incremental="$td/snar" -cf "$td/a.tar" f 2>/dev/null; then
		ok "tar --listed-incremental works (incremental backups supported)"
	else
		no "tar --listed-incremental failed — incremental mode unavailable"
	fi
	rm -rf "$td"
else
	no "not GNU tar — incremental backups will NOT work"
fi

# --- config + DB ------------------------------------------------------------
if [ -f "$CONFIG" ]; then
	ok "config file: $CONFIG"
	mode="$(stat -c '%a' "$CONFIG" 2>/dev/null || echo '?')"
	case "$mode" in 600|400) ok "config perms $mode";; *) skip "config perms $mode (want 600 — holds secrets)";; esac
else
	skip "no config file; using defaults ($CONFIG)"
fi

if [ ! -f "$FPBX_CONFIG" ]; then
	no "FusionPBX config missing: $FPBX_CONFIG"
elif ( detect_db >/dev/null 2>&1 ); then
	# Probe passed in a subshell (detect_db exits on bad config); safe to run
	# in this shell now to export DB_* without aborting the whole self-test.
	detect_db >/dev/null 2>&1
	ok "DB detected: $DB_TYPE"
	if [ "$DB_TYPE" = "pgsql" ]; then
		have pg_dump && ok "pg_dump present" || no "pg_dump missing (postgresql-client)"
		if have pg_isready; then
			if pg_isready -h "$DB_HOST" -p "$DB_PORT" -t 5 >/dev/null 2>&1; then
				ok "postgres reachable $DB_HOST:$DB_PORT"
			else
				no "postgres NOT reachable $DB_HOST:$DB_PORT"
			fi
		else skip "pg_isready missing; skipped reachability"; fi
		# Auth test — SELECT 1 against the target DB.
		_pg_env
		if have psql && timeout 8 psql -tAc 'SELECT 1' >/dev/null 2>&1; then
			ok "postgres auth OK (SELECT 1 on $DB_NAME)"
		else
			no "postgres auth/connect failed for $DB_USER@$DB_NAME (check creds/pg_hba)"
		fi
	else
		have sqlite3 && ok "sqlite3 present" || no "sqlite3 missing"
		if [ -f "$DB_PATH" ]; then
			ok "sqlite db exists: $DB_PATH"
			if have sqlite3 && [ "$(sqlite3 "$DB_PATH" 'PRAGMA integrity_check;' 2>/dev/null)" = "ok" ]; then
				ok "sqlite integrity_check ok"
			else skip "sqlite integrity_check not ok / unreadable"; fi
		else no "sqlite db not found: $DB_PATH"; fi
	fi
else
	no "DB detection failed (check $FPBX_CONFIG)"
fi

# --- source paths -----------------------------------------------------------
for p in "$INCLUDE_ETC_FUSIONPBX" "$INCLUDE_ETC_FREESWITCH" "$INCLUDE_WEBROOT" "$INCLUDE_FS_DATA"; do
	[ -e "$p" ] && ok "source exists: $p" || skip "source missing: $p"
done

# --- backup dir writable ----------------------------------------------------
if mkdir -p "$BACKUP_DIR/state" 2>/dev/null && touch "$BACKUP_DIR/.selftest" 2>/dev/null; then
	rm -f "$BACKUP_DIR/.selftest"; ok "BACKUP_DIR writable: $BACKUP_DIR"
else no "BACKUP_DIR not writable: $BACKUP_DIR"; fi

# --- encryption roundtrip ---------------------------------------------------
case "$ENCRYPTION" in
	none) skip "encryption disabled (ENCRYPTION=none)";;
	age|gpg)
		tf="$(mktemp)"; echo "fpbx-selftest-canary" > "$tf"
		enc="$(crypto_encrypt "$tf" 2>/dev/null)" && [ -f "$enc" ] \
			&& ok "encrypt ($ENCRYPTION) works -> $(basename "$enc")" \
			|| no "encrypt ($ENCRYPTION) failed — check recipients/keys"
		# Roundtrip decrypt only if a private identity is available.
		if [ "$ENCRYPTION" = "age" ] && [ -n "${AGE_IDENTITY:-}" ] && [ -f "${enc:-/nonexist}" ]; then
			dec="$(crypto_decrypt "$enc" 2>/dev/null)"
			[ -f "$dec" ] && grep -q canary "$dec" && ok "age decrypt roundtrip OK" \
				|| no "age decrypt roundtrip FAILED (AGE_IDENTITY wrong?)"
			rm -f "$dec"
		elif [ "$ENCRYPTION" = "gpg" ] && [ -f "${enc:-/nonexist}" ]; then
			dec="$(crypto_decrypt "$enc" 2>/dev/null)" && grep -q canary "${dec:-/x}" 2>/dev/null \
				&& ok "gpg decrypt roundtrip OK" || skip "gpg decrypt roundtrip skipped (no secret key here)"
			rm -f "${dec:-}"
		else
			skip "decrypt roundtrip skipped (set AGE_IDENTITY to test full restore path)"
		fi
		rm -f "$tf" "${enc:-}"
		;;
	*) no "unknown ENCRYPTION=$ENCRYPTION";;
esac

# --- offsite reachability (best effort, read-only) --------------------------
case "$OFFSITE" in
	none) skip "offsite disabled";;
	s3)     have aws && timeout 15 aws ${AWS_PROFILE:+--profile "$AWS_PROFILE"} s3 ls "s3://$S3_BUCKET" >/dev/null 2>&1 \
	          && ok "s3 bucket reachable: $S3_BUCKET" || no "s3 unreachable / awscli missing";;
	rclone) have rclone && timeout 15 rclone lsd "${RCLONE_DEST%%:*}:" >/dev/null 2>&1 \
	          && ok "rclone remote reachable" || no "rclone remote unreachable / missing";;
	rsync)  have rsync && ok "rsync present (dest not probed)" || no "rsync missing";;
	*) no "unknown OFFSITE=$OFFSITE";;
esac

echo
printf 'Result: %d pass, %d warn, %d fail\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ] && { log "self-test PASSED"; exit 0; } || { err "self-test FAILED"; exit 1; }
