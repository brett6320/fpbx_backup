#!/usr/bin/env bash
# fpbx-backup.sh — safe backup of a FusionPBX host (DB + configs + data).
# Supports full and incremental (tar snapshot) file backups, encryption, offsite.
#
# Usage:
#   ./fpbx-backup.sh [--mode full|incremental] [--config PATH]
#
# Run as root (needs read on /etc/freeswitch, /var/lib/freeswitch, DB creds).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SELF_DIR/lib/common.sh"

# ----------------------------------------------------------------------------
# Args
# ----------------------------------------------------------------------------
CONFIG="${FPBX_BACKUP_CONF:-/etc/fpbx-backup.conf}"
CLI_MODE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--mode)   CLI_MODE="$2"; shift 2 ;;
		--config) CONFIG="$2";   shift 2 ;;
		-h|--help)
			sed -n '2,9p' "$0"; exit 0 ;;
		*) die "unknown arg: $1" ;;
	esac
done

load_config "$CONFIG"
. "$SELF_DIR/lib/db.sh"
. "$SELF_DIR/lib/crypto.sh"
. "$SELF_DIR/lib/offsite.sh"

[ -n "$CLI_MODE" ] && BACKUP_MODE="$CLI_MODE"
case "$BACKUP_MODE" in full|incremental) ;; *) die "bad --mode: $BACKUP_MODE";; esac

[ "$(id -u)" = "0" ] || warn "not root; some files/DB creds may be unreadable"
need tar
need gzip

RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
HOST="$(hostname -s 2>/dev/null || hostname)"
STATE_DIR="$BACKUP_DIR/state"
mkdir -p "$BACKUP_DIR" "$STATE_DIR"

detect_db

# ----------------------------------------------------------------------------
# Decide chain + level for the file-tree portion (incremental engine)
# ----------------------------------------------------------------------------
# CURRENT_CHAIN file holds:  <chainId> <lastLevel>
CURRENT_FILE="$STATE_DIR/CURRENT_CHAIN"
CHAIN_ID=""; LEVEL=0; SNAR=""

resolve_chain() {
	if [ "$BACKUP_MODE" = "full" ]; then
		CHAIN_ID="$RUN_TS"; LEVEL=0
		log "mode=full: starting new chain $CHAIN_ID"
		return
	fi
	# incremental
	if [ ! -f "$CURRENT_FILE" ]; then
		warn "no existing chain; promoting first run to full"
		BACKUP_MODE="full"; CHAIN_ID="$RUN_TS"; LEVEL=0; return
	fi
	local cid last; read -r cid last < "$CURRENT_FILE"
	if [ ! -f "$STATE_DIR/$cid.snar" ]; then
		warn "snapshot for chain $cid missing; promoting to full"
		BACKUP_MODE="full"; CHAIN_ID="$RUN_TS"; LEVEL=0; return
	fi
	if [ "${MAX_INCREMENTALS:-0}" != "0" ] && [ "$last" -ge "$MAX_INCREMENTALS" ]; then
		log "chain $cid hit MAX_INCREMENTALS=$MAX_INCREMENTALS; starting new full"
		BACKUP_MODE="full"; CHAIN_ID="$RUN_TS"; LEVEL=0; return
	fi
	CHAIN_ID="$cid"; LEVEL=$(( last + 1 ))
	log "mode=incremental: chain $CHAIN_ID level $LEVEL"
}
resolve_chain
SNAR="$STATE_DIR/$CHAIN_ID.snar"
# For a fresh full, ensure no stale snapshot lingers.
[ "$LEVEL" = "0" ] && rm -f "$SNAR"

# ----------------------------------------------------------------------------
# Stage
# ----------------------------------------------------------------------------
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/fpbx-bkp.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
mkdir -p "$STAGE/db"

# 1) Database — always a full, self-contained dump.
db_dump "$STAGE/db" >/dev/null

# 2) Build the list of file-tree sources that actually exist.
SRC=()
add_src() { [ -e "$1" ] && SRC+=("$1") || warn "skip missing: $1"; }
add_src "$INCLUDE_ETC_FUSIONPBX"
add_src "$INCLUDE_ETC_FREESWITCH"
add_src "$INCLUDE_WEBROOT"
[ -d "$INCLUDE_LETSENCRYPT" ] && add_src "$INCLUDE_LETSENCRYPT"
if [ "${BACKUP_RECORDINGS:-yes}" = "yes" ]; then
	add_src "$INCLUDE_FS_DATA"
else
	warn "BACKUP_RECORDINGS=no: excluding $INCLUDE_FS_DATA"
fi
[ ${#SRC[@]} -gt 0 ] || die "no source paths exist; nothing to back up"

# 3) tar the file tree with a GNU listed-incremental snapshot.
#    Paths stored relative to / so restore extracts cleanly to /.
#    On level 0 the snapshot is created; increments only add changed files.
REL=(); for p in "${SRC[@]}"; do REL+=("${p#/}"); done
log "archiving file tree (level $LEVEL, ${#SRC[@]} sources)"
tar --numeric-owner --acls --xattrs \
	--listed-incremental="$SNAR" \
	-C / -czf "$STAGE/files.tar.gz" "${REL[@]}" \
	|| die "file tar failed"

# 4) Metadata inside the archive (portable / offsite self-describing).
manifest_write "$STAGE"
cp -a "$SNAR" "$STAGE/files.snar"          # snapshot state after this run
{
	echo "chain_id=$CHAIN_ID"
	echo "level=$LEVEL"
	echo "run_ts=$RUN_TS"
	echo "mode=$BACKUP_MODE"
	printf 'sources='; printf '%s ' "${SRC[@]}"; echo
} > "$STAGE/CHAININFO"

# 5) Pack outer archive (plain tar; members already compressed).
NAME="fpbx_${HOST}_${CHAIN_ID}_L${LEVEL}_${RUN_TS}.tar"
OUT="$BACKUP_DIR/$NAME"
tar -C "$STAGE" -cf "$OUT" .
log "wrote $OUT ($(du -h "$OUT" | cut -f1))"

# 6) Encrypt at rest.
OUT="$(crypto_encrypt "$OUT")"
[ "$ENCRYPTION" != "none" ] && log "encrypted -> $(basename "$OUT")"

# 7) Record chain state only AFTER a successful archive.
echo "$CHAIN_ID $LEVEL" > "$CURRENT_FILE"

# 8) Offsite push (non-fatal).
offsite_push "$OUT" || warn "offsite push failed; local copy retained"

# 9) Retention — prune whole chains older than RETENTION_DAYS.
prune_chains() {
	local days="${RETENTION_DAYS:-0}"; [ "$days" = "0" ] && return 0
	log "retention: pruning chains with no member newer than ${days}d"
	# Gather chain ids from archive names.
	local cid
	for cid in $(ls "$BACKUP_DIR" 2>/dev/null \
			| sed -n 's/^fpbx_.*_\([0-9TZ]*\)_L[0-9]*_.*/\1/p' | sort -u); do
		# Newest member of this chain, in minutes old.
		local newest
		newest="$(find "$BACKUP_DIR" -maxdepth 1 -name "fpbx_*_${cid}_L*" \
			-printf '%T@\n' 2>/dev/null | sort -rn | head -n1)"
		[ -z "$newest" ] && continue
		local age_days
		age_days=$(( ( $(date +%s) - ${newest%.*} ) / 86400 ))
		if [ "$age_days" -ge "$days" ]; then
			log "  drop chain $cid (newest ${age_days}d old)"
			rm -f "$BACKUP_DIR"/fpbx_*_"${cid}"_L*
			rm -f "$STATE_DIR/$cid.snar"
		fi
	done
}
prune_chains

log "backup complete: $(basename "$OUT")  chain=$CHAIN_ID level=$LEVEL"
