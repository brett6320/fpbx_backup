#!/usr/bin/env bash
# fpbx-restore.sh — restore a FusionPBX host from fpbx-backup archives.
# Replays an incremental chain (level 0 full + increments) and restores the DB.
#
# Usage:
#   ./fpbx-restore.sh --list
#   ./fpbx-restore.sh --chain <CHAIN_ID> [--level N] [--target same|migrate]
#   ./fpbx-restore.sh --archive <FILE>            (resolves its chain siblings)
#   ./fpbx-restore.sh --chain <CHAIN_ID> --data-only   (cross-version migrate)
#   Options: --db-only | --files-only | --data-only | --verify | --no-services
#            | --force | --config PATH
#
# --data-only restores DB + voicemail/recordings ONLY (not app source or
# /etc/freeswitch) — the correct mode for a cross-major migration such as
# 4.5.1 -> 5.x, followed by the FusionPBX schema upgrade it prints.
#
# Run as root. DESTRUCTIVE: overwrites DB and system files. Confirm prompts
# unless --force.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SELF_DIR/lib/common.sh"

CONFIG="${FPBX_BACKUP_CONF:-/etc/fpbx-backup.conf}"
CHAIN=""; LEVEL=""; ARCHIVE=""; TARGET="same"
DO_DB=1; DO_FILES=1; MANAGE_SVC=1; DATA_ONLY=0
while [ $# -gt 0 ]; do
	case "$1" in
		--chain)   CHAIN="$2"; shift 2 ;;
		--level)   LEVEL="$2"; shift 2 ;;
		--archive) ARCHIVE="$2"; shift 2 ;;
		--target)  TARGET="$2"; shift 2 ;;
		--config)  CONFIG="$2"; shift 2 ;;
		--db-only)    DO_FILES=0; shift ;;
		--files-only) DO_DB=0; shift ;;
		--data-only)  DATA_ONLY=1; TARGET="migrate"; shift ;;
		--no-services) MANAGE_SVC=0; shift ;;
		--force)   FORCE=1; export FORCE; shift ;;   # read by confirm() in common.sh
		--list)    LIST=1; shift ;;
		--verify)  VERIFY=1; shift ;;
		-h|--help) sed -n '2,19p' "$0"; exit 0 ;;
		*) die "unknown arg: $1" ;;
	esac
done
case "$TARGET" in same|migrate) ;; *) die "bad --target: $TARGET";; esac

load_config "$CONFIG"
. "$SELF_DIR/lib/db.sh"
. "$SELF_DIR/lib/crypto.sh"
. "$SELF_DIR/lib/offsite.sh"
need tar

# ----------------------------------------------------------------------------
# --list: show chains/levels available locally.
# ----------------------------------------------------------------------------
list_chains() {
	local f b
	printf '%-22s %-6s %-24s %s\n' CHAIN_ID LEVEL RUN_TS FILE
	for f in "$BACKUP_DIR"/fpbx_*_L*; do
		[ -e "$f" ] || continue
		b="$(basename "$f")"
		local cid lvl rts
		cid="$(echo "$b" | sed -n 's/^fpbx_.*_\([0-9TZ]*\)_L[0-9]*_.*/\1/p')"
		lvl="$(echo "$b" | sed -n 's/^fpbx_.*_L\([0-9]*\)_.*/\1/p')"
		rts="$(echo "$b" | sed -n 's/^fpbx_.*_L[0-9]*_\([0-9TZ]*\)\..*/\1/p')"
		printf '%-22s %-6s %-24s %s\n' "$cid" "$lvl" "$rts" "$b"
	done | sort -k1,1 -k2,2n
}
if [ "${LIST:-0}" = "1" ]; then list_chains; exit 0; fi

# ----------------------------------------------------------------------------
# Resolve which chain + up-to-level to restore.
# ----------------------------------------------------------------------------
if [ -n "$ARCHIVE" ]; then
	[ -f "$ARCHIVE" ] || die "archive not found: $ARCHIVE"
	local_b="$(basename "$ARCHIVE")"
	CHAIN="$(echo "$local_b" | sed -n 's/^fpbx_.*_\([0-9TZ]*\)_L[0-9]*_.*/\1/p')"
	LEVEL="$(echo "$local_b" | sed -n 's/^fpbx_.*_L\([0-9]*\)_.*/\1/p')"
	BACKUP_DIR="$(cd "$(dirname "$ARCHIVE")" && pwd)"
	log "archive belongs to chain $CHAIN level $LEVEL"
fi
[ -n "$CHAIN" ] || die "specify --chain, --archive, or --list"

# Collect chain members present locally, ordered by level.
declare -a MEMBERS
while IFS= read -r f; do MEMBERS+=("$f"); done < <(
	ls "$BACKUP_DIR"/fpbx_*_"${CHAIN}"_L* 2>/dev/null \
		| sed -E 's/.*_L([0-9]+)_.*/\1 &/' | sort -n | awk '{print $2}'
)
[ ${#MEMBERS[@]} -gt 0 ] || die "no members for chain $CHAIN in $BACKUP_DIR"

# Default: restore to the highest available level.
if [ -z "$LEVEL" ]; then
	LEVEL="$(basename "${MEMBERS[-1]}" | sed -n 's/.*_L\([0-9]*\)_.*/\1/p')"
fi
log "restore chain=$CHAIN up to level=$LEVEL target=$TARGET"

# Verify contiguous 0..LEVEL exist (incremental replay requires no gaps).
for want in $(seq 0 "$LEVEL"); do
	ls "$BACKUP_DIR"/fpbx_*_"${CHAIN}"_L"${want}"_* >/dev/null 2>&1 \
		|| die "missing level $want for chain $CHAIN (need contiguous 0..$LEVEL)"
done

# ----------------------------------------------------------------------------
# --verify: read-only integrity check of the chain. No system changes.
# ----------------------------------------------------------------------------
if [ "${VERIFY:-0}" = "1" ]; then
	VW="$(mktemp -d "${TMPDIR:-/tmp}/fpbx-vfy.XXXXXX")"
	trap 'rm -rf "$VW"' EXIT
	vfail=0
	for lvl in $(seq 0 "$LEVEL"); do
		f="$(ls "$BACKUP_DIR"/fpbx_*_"${CHAIN}"_L"${lvl}"_* 2>/dev/null | head -n1)"
		b="$(basename "$f")"; d="$VW/L$lvl"; mkdir -p "$d"
		cp -a "$f" "$d/$b"
		if ! src="$(crypto_decrypt "$d/$b" 2>/dev/null)"; then
			printf '  FAIL L%s decrypt failed: %s\n' "$lvl" "$b"; vfail=1; continue
		fi
		if ! tar -tf "$src" >"$d/list" 2>/dev/null; then
			printf '  FAIL L%s outer tar corrupt: %s\n' "$lvl" "$b"; vfail=1; continue
		fi
		mkdir -p "$d/x"; tar -C "$d/x" -xf "$src" 2>/dev/null
		# Inner file tree — any compression (tar auto-detects gz/zst/xz on read).
		inner="$(ls "$d"/x/files.tar* 2>/dev/null | head -n1)"
		if [ -n "$inner" ] && tar -tf "$inner" >/dev/null 2>&1; then
			nfiles="$(tar -tf "$inner" 2>/dev/null | wc -l | tr -d ' ')"
		else
			printf '  FAIL L%s inner file archive corrupt/missing\n' "$lvl"; vfail=1; continue
		fi
		hasdb=no; ls "$d"/x/db/db_*.pg.dump "$d"/x/db/db_*.sqlite* >/dev/null 2>&1 && hasdb=yes
		printf '  OK   L%-2s %-52s files=%-6s db=%s\n' "$lvl" "$b" "$nfiles" "$hasdb"
		[ "$hasdb" = "yes" ] || { printf '       ^ WARNING: no DB dump in this member\n'; vfail=1; }
	done
	echo
	if [ "$vfail" = "0" ]; then log "verify PASSED for chain $CHAIN (levels 0..$LEVEL)"; exit 0
	else err "verify FAILED for chain $CHAIN"; exit 1; fi
fi

echo
warn "About to OVERWRITE this host's FusionPBX DB and system files from backup."
warn "Chain $CHAIN, levels 0..$LEVEL, target=$TARGET."
confirm "Proceed with restore?" || die "aborted by user"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fpbx-rst.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------
# Stop services during restore.
# ----------------------------------------------------------------------------
if [ "$MANAGE_SVC" = "1" ]; then
	for s in $SERVICES; do svc stop "$s"; done
fi

# extract_member LEVEL DESTDIR — decrypt + unpack one chain member's outer tar.
extract_member() {
	local lvl="$1" dest="$2" f base src
	f="$(ls "$BACKUP_DIR"/fpbx_*_"${CHAIN}"_L"${lvl}"_* 2>/dev/null | head -n1)"
	[ -n "$f" ] || die "level $lvl archive vanished"
	base="$(basename "$f")"
	log "unpack level $lvl: $base"
	# Work on a copy so the original archive is never modified/deleted.
	cp -a "$f" "$dest/$base"
	# crypto_decrypt keys off the .age/.gpg extension; returns path as-is if plain.
	src="$(crypto_decrypt "$dest/$base")"
	mkdir -p "$dest/x"
	tar -C "$dest/x" -xf "$src"
}

detect_db   # need DB target coordinates for the restore

# ----------------------------------------------------------------------------
# Files: replay level 0..LEVEL in order (GNU incremental restore to /).
# ----------------------------------------------------------------------------
if [ "$DO_FILES" = "1" ]; then
	# In --data-only mode restore ONLY user data (voicemail/recordings), never
	# the application source or /etc/freeswitch — those must stay the target's
	# own (5.x) versions in a cross-version migration.
	MEMBER_FILTER=()
	if [ "$DATA_ONLY" = "1" ]; then
		MEMBER_FILTER=("${INCLUDE_FS_DATA#/}")   # e.g. var/lib/freeswitch
		log "data-only: restoring ONLY $INCLUDE_FS_DATA (excluding app source + /etc/freeswitch)"
	fi
	for lvl in $(seq 0 "$LEVEL"); do
		md="$WORK/L$lvl"; mkdir -p "$md"
		extract_member "$lvl" "$md"
		inner="$(ls "$md"/x/files.tar* 2>/dev/null | head -n1)"
		[ -n "$inner" ] || die "level $lvl missing file archive"
		log "extracting file tree (level $lvl)${DATA_ONLY:+ [data-only]}${TARGET:+ target=$TARGET}"
		# --incremental restores deletions recorded in the snapshot too. tar
		# auto-detects the compression (gz/zst/xz); trailing members[] limits
		# extraction to those paths (data-only).
		tar --incremental --numeric-owner --acls --xattrs \
			-C / -xf "$inner" "${MEMBER_FILTER[@]}" \
			|| warn "tar reported errors on level $lvl (check output)"
	done

	# Ownership. Voicemail/recordings must be reachable by BOTH FreeSWITCH and
	# the web user; on package installs both are www-data, but honor overrides.
	if [ "$DATA_ONLY" = "1" ]; then
		log "fixing ownership on $INCLUDE_FS_DATA -> $OWNER_USER:$OWNER_GROUP"
		[ -e "$INCLUDE_FS_DATA" ] && chown -R "$OWNER_USER:$OWNER_GROUP" "$INCLUDE_FS_DATA" 2>/dev/null || true
		# If FreeSWITCH runs as a distinct user, add group read/write.
		if [ -n "${FS_RUN_USER:-}" ] && [ "$FS_RUN_USER" != "$OWNER_USER" ]; then
			chgrp -R "$FS_RUN_USER" "$INCLUDE_FS_DATA" 2>/dev/null || true
			chmod -R g+rw "$INCLUDE_FS_DATA" 2>/dev/null || true
		fi
	else
		log "fixing ownership -> $OWNER_USER:$OWNER_GROUP"
		for p in "$INCLUDE_ETC_FUSIONPBX" "$INCLUDE_ETC_FREESWITCH" \
		         "$INCLUDE_WEBROOT" "$INCLUDE_FS_DATA"; do
			[ -e "$p" ] && chown -R "$OWNER_USER:$OWNER_GROUP" "$p" 2>/dev/null || true
		done
	fi
fi

# ----------------------------------------------------------------------------
# DB: restore the chosen level's full dump (point-in-time = that run).
# ----------------------------------------------------------------------------
if [ "$DO_DB" = "1" ]; then
	md="$WORK/L$LEVEL"
	[ -d "$md/x" ] || { md="$WORK/dbonly"; mkdir -p "$md"; extract_member "$LEVEL" "$md"; }
	dump="$(ls "$md"/x/db/db_*.pg.dump "$md"/x/db/db_*.sqlite* 2>/dev/null | head -n1)"
	[ -n "$dump" ] || die "no DB dump inside level $LEVEL archive"
	globals="$md/x/db/db_globals.sql"
	log "restoring database from level $LEVEL dump"
	db_restore "$dump" "$globals"
fi

# ----------------------------------------------------------------------------
# Restart services.
# ----------------------------------------------------------------------------
if [ "$MANAGE_SVC" = "1" ]; then
	for s in $SERVICES; do svc start "$s"; done
fi

echo
log "restore complete: chain=$CHAIN level=$LEVEL target=$TARGET${DATA_ONLY:+ (data-only)}"
if [ "$DATA_ONLY" = "1" ]; then
	cat >&2 <<'EOF'
[WARN ] CROSS-VERSION MIGRATION (e.g. 4.5.1 -> 5.x) — REQUIRED NEXT STEPS:
  The old DB was loaded into this host. It is still at the OLD schema version
  and MUST be upgraded to match this host's FusionPBX source, or the GUI breaks.

  1) Point /etc/fusionpbx/config.conf database.0.* at the restored DB.
  2) Run the FusionPBX schema/data upgrade (brings the old schema forward):
        php /var/www/fusionpbx/core/upgrade/upgrade.php -s   # schema + data types
        php /var/www/fusionpbx/core/upgrade/upgrade.php -d   # app defaults
        php /var/www/fusionpbx/core/upgrade/upgrade.php -d   # run defaults TWICE
        php /var/www/fusionpbx/core/upgrade/upgrade.php -p -m # permissions + menu
     (GUI equivalent: Advanced > Upgrade > Schema, App Defaults x2, Permissions.)
  3) Regenerate FreeSWITCH config from the DB and clear caches:
        fs_cli -x 'reloadxml'
        rm -rf /var/cache/fusionpbx/*
  4) Confirm voicemail/recordings are owned so BOTH FreeSWITCH and www-data can
     read them (set FS_RUN_USER in the config if FreeSWITCH runs as 'freeswitch').
  5) Test: place a call, leave + retrieve a voicemail, check an old recording.
        fs_cli -x 'sofia status'
  NOTE: this mode did NOT restore old app source or /etc/freeswitch — correct
  for a version migration; those stay at this host's version.
EOF
elif [ "$TARGET" = "migrate" ]; then
	cat >&2 <<'EOF'
[WARN ] MIGRATION CHECKLIST (same-version, new host):
  * Verify /etc/fusionpbx/config.conf DB host/creds match THIS host's Postgres.
  * If the DB user/password differ here, update config.conf then rerun services.
  * Re-point DNS / SIP domains if the public IP changed.
  * Re-issue or copy TLS certs; check /etc/freeswitch/tls and /etc/letsencrypt.
  * In FusionPBX GUI: Advanced > Upgrade > run "App Defaults" + "Permissions".
  * Confirm gateways/registrations with: fs_cli -x 'sofia status'
  * DIFFERENT major versions (e.g. 4.5.1 -> 5.x)? Use --data-only instead; a
    wholesale file restore would overwrite this host's app source and break it.
EOF
fi
