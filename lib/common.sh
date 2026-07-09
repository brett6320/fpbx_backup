#!/usr/bin/env bash
# lib/common.sh — shared helpers: logging, config load, DB credential detect.
# Sourced by fpbx-backup.sh and fpbx-restore.sh. Not executable on its own.

# ----------------------------------------------------------------------------
# Defaults (overridden by fpbx-backup.conf)
# ----------------------------------------------------------------------------
: "${FPBX_CONFIG:=/etc/fusionpbx/config.conf}"
: "${BACKUP_DIR:=/var/backups/fusionpbx}"
: "${INCLUDE_ETC_FUSIONPBX:=/etc/fusionpbx}"
: "${INCLUDE_ETC_FREESWITCH:=/etc/freeswitch}"
: "${INCLUDE_WEBROOT:=/var/www/fusionpbx}"
: "${INCLUDE_LETSENCRYPT:=/etc/letsencrypt}"
: "${INCLUDE_FS_DATA:=/var/lib/freeswitch}"
: "${BACKUP_RECORDINGS:=yes}"
: "${RETENTION_DAYS:=14}"
: "${ENCRYPTION:=none}"
: "${OFFSITE:=none}"
# Compression for the file tree + SQLite dump (PostgreSQL dumps are already
# compressed via pg_dump custom format). auto = zstd if available else gzip.
: "${COMPRESS:=auto}"
: "${ZSTD_LEVEL:=12}"
: "${GZIP_LEVEL:=6}"
: "${XZ_LEVEL:=6}"
# full | incremental. Incremental captures only files changed since the chain's
# level-0 full (great for voicemail/recordings that rarely change).
: "${BACKUP_MODE:=full}"
# After this many increments, the next run auto-promotes to a fresh full so a
# chain never grows without bound. 0 = never force.
: "${MAX_INCREMENTALS:=30}"
# Ownership applied to restored files. FusionPBX runs FreeSWITCH + PHP as this
# user on Debian; change if your install differs.
: "${OWNER_USER:=www-data}"
: "${OWNER_GROUP:=www-data}"
# If FreeSWITCH runs as its own user (not www-data), set this so restored
# voicemail/recordings get group access for both FreeSWITCH and the web user.
: "${FS_RUN_USER:=}"
# Services stopped during restore and restarted after (space-separated).
: "${SERVICES:=freeswitch nginx php8.2-fpm}"

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
_ts()   { date +'%Y-%m-%d %H:%M:%S'; }
# All logs go to stderr so functions can echo values on stdout for $(...) capture.
log()   { printf '%s [INFO ] %s\n'  "$(_ts)" "$*" >&2; }
warn()  { printf '%s [WARN ] %s\n'  "$(_ts)" "$*" >&2; }
err()   { printf '%s [ERROR] %s\n'  "$(_ts)" "$*" >&2; }
die()   { err "$*"; exit 1; }

# Require a command to exist, else die with install hint.
need() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1${2:+  ($2)}"
}

# Confirm a destructive action unless FORCE=1.
confirm() {
	[ "${FORCE:-0}" = "1" ] && return 0
	local reply
	printf '%s [y/N] ' "$1" >&2
	read -r reply || true
	case "$reply" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac
}

# ----------------------------------------------------------------------------
# Config loading
# ----------------------------------------------------------------------------
# Source the user config file if present. Safe-ish: it is bash we own.
load_config() {
	local cfg="${1:-}"
	if [ -n "$cfg" ] && [ -f "$cfg" ]; then
		# shellcheck disable=SC1090
		. "$cfg"
		log "loaded config: $cfg"
	else
		warn "no config file; using built-in defaults"
	fi
}

# ----------------------------------------------------------------------------
# FusionPBX DB credential detection
# ----------------------------------------------------------------------------
# Supports BOTH config formats:
#   * 5.x   INI  /etc/fusionpbx/config.conf   (database.0.host = 127.0.0.1)
#   * <=4.x PHP  /etc/fusionpbx/config.php    ($db_host = '127.0.0.1';)
# Auto-detects which is present so a 4.5.1 box can be backed up and a 5.x box
# restored. Exports: DB_TYPE DB_HOST DB_PORT DB_NAME DB_USER DB_PASS
# DB_SSLMODE DB_PATH. DB_TYPE normalized to  pgsql  or  sqlite .

# Legacy config.php candidates, most-specific first (override: FPBX_CONFIG_LEGACY).
_legacy_config() {
	local c
	for c in "${FPBX_CONFIG_LEGACY:-}" \
	         /etc/fusionpbx/config.php \
	         /var/www/fusionpbx/resources/config.php; do
		[ -n "$c" ] && [ -f "$c" ] && { echo "$c"; return 0; }
	done
	return 1
}

# Parse legacy PHP config: pull  $db_<key> = 'value';  (single or double quotes).
detect_db_php() {
	local f="$1"
	_php() {
		sed -n "s/^[[:space:]]*\$db_$1[[:space:]]*=[[:space:]]*['\"]\{0,1\}\([^'\";]*\).*/\1/p" \
			"$f" | head -n1 | tr -d '\r'
	}
	DB_TYPE="$(_php type)"
	DB_HOST="$(_php host)"
	DB_PORT="$(_php port)"
	DB_NAME="$(_php name)"
	# 4.x uses $db_username; some builds use $db_user — try both.
	DB_USER="$(_php username)"; [ -n "$DB_USER" ] || DB_USER="$(_php user)"
	DB_PASS="$(_php password)"
	DB_PATH="$(_php path)"
	DB_SSLMODE=""
	log "parsed legacy PHP config: $f"
}

detect_db() {
	# Prefer the 5.x INI config when it actually carries a database.0 block;
	# otherwise fall back to a legacy PHP config (4.x and older).
	local legacy=""
	if [ -f "$FPBX_CONFIG" ] && grep -q '^[[:space:]]*database\.0\.type' "$FPBX_CONFIG" 2>/dev/null; then
		: # use INI path below
	elif legacy="$(_legacy_config)"; then
		detect_db_php "$legacy"
		_finalize_db
		return
	else
		die "no FusionPBX DB config found (looked for $FPBX_CONFIG and config.php)"
	fi

	# Pull the first database.N.* block (FusionPBX numbers them; 0 is primary).
	local n=0
	_ini() { # key -> value from FPBX_CONFIG for index $n
		sed -n "s/^[[:space:]]*database\.$n\.$1[[:space:]]*=[[:space:]]*//p" \
			"$FPBX_CONFIG" | head -n1 | tr -d '\r'
	}

	DB_TYPE="$(_ini type)"
	DB_HOST="$(_ini host)"
	DB_PORT="$(_ini port)"
	DB_NAME="$(_ini name)"
	DB_USER="$(_ini username)"
	DB_PASS="$(_ini password)"
	DB_SSLMODE="$(_ini sslmode)"
	DB_PATH="$(_ini path)"
	_finalize_db
}

# Normalize DB_TYPE, apply defaults, export. Shared by INI + PHP paths.
_finalize_db() {
	case "$DB_TYPE" in
		pgsql|postgres|postgresql) DB_TYPE="pgsql" ;;
		sqlite|sqlite3)            DB_TYPE="sqlite" ;;
		"") die "could not read database type from FusionPBX config" ;;
		*)  die "unsupported database type: $DB_TYPE" ;;
	esac

	if [ "$DB_TYPE" = "pgsql" ]; then
		: "${DB_HOST:=127.0.0.1}"
		: "${DB_PORT:=5432}"
		: "${DB_NAME:=fusionpbx}"
		: "${DB_USER:=fusionpbx}"
		: "${DB_SSLMODE:=prefer}"
		[ -n "$DB_PASS" ] || warn "no DB password parsed; relying on ~/.pgpass or peer auth"
	else
		# SQLite: FusionPBX stores $db_path as a DIRECTORY and $db_name as the
		# file. Join them unless DB_PATH already points at a .db/.sqlite file.
		if [ -n "$DB_PATH" ]; then
			case "$DB_PATH" in
				*.db|*.sqlite|*.sqlite3) : ;;                 # already a file
				*) [ -n "$DB_NAME" ] && DB_PATH="${DB_PATH%/}/$DB_NAME" ;;
			esac
		else
			: "${DB_PATH:=/var/lib/fusionpbx/database/fusionpbx.db}"
		fi
	fi

	export DB_TYPE DB_HOST DB_PORT DB_NAME DB_USER DB_PASS DB_SSLMODE DB_PATH
	log "detected DB: type=$DB_TYPE${DB_NAME:+ name=$DB_NAME}${DB_PATH:+ path=$DB_PATH}"
}

# ----------------------------------------------------------------------------
# Compression
# ----------------------------------------------------------------------------
# Resolve COMPRESS -> COMPRESS_PROG (compressor command, may include flags) and
# COMPRESS_EXT (filename suffix). Used as a pipe so it works across tar versions
# and old source hosts. Extraction is by GNU tar auto-detect, so the restore
# side needs no matching config. Falls back gzip->none if a tool is missing.
compress_resolve() {
	if [ "$COMPRESS" = "auto" ]; then
		if command -v zstd >/dev/null 2>&1; then COMPRESS=zstd; else COMPRESS=gzip; fi
	fi
	case "$COMPRESS" in
		zstd) command -v zstd >/dev/null 2>&1 || { warn "zstd missing; using gzip"; COMPRESS=gzip; } ;;
		xz)   command -v xz   >/dev/null 2>&1 || { warn "xz missing; using gzip";   COMPRESS=gzip; } ;;
	esac
	case "$COMPRESS" in
		zstd) COMPRESS_PROG="zstd -${ZSTD_LEVEL} -T0"; COMPRESS_EXT="zst" ;;
		gzip) command -v gzip >/dev/null 2>&1 || { warn "gzip missing; storing uncompressed"; COMPRESS=none; }
		      COMPRESS_PROG="gzip -${GZIP_LEVEL}"; COMPRESS_EXT="gz" ;;
		xz)   COMPRESS_PROG="xz -${XZ_LEVEL} -T0"; COMPRESS_EXT="xz" ;;
		none) COMPRESS_PROG=""; COMPRESS_EXT="" ;;
		*) die "unknown COMPRESS: $COMPRESS" ;;
	esac
	[ "$COMPRESS" = "none" ] && { COMPRESS_PROG=""; COMPRESS_EXT=""; }
	export COMPRESS COMPRESS_PROG COMPRESS_EXT
	log "compression: ${COMPRESS}${COMPRESS_PROG:+ ($COMPRESS_PROG)}"
}

# compress_file FILE — compress in place with COMPRESS_PROG, echo new path.
# No-op (echoes FILE) when compression is disabled.
compress_file() {
	local f="$1"
	[ -z "${COMPRESS_PROG:-}" ] && { echo "$f"; return 0; }
	$COMPRESS_PROG -c "$f" > "$f.$COMPRESS_EXT" && rm -f "$f" || die "compress failed: $f"
	echo "$f.$COMPRESS_EXT"
}

# ----------------------------------------------------------------------------
# Service control (best-effort; systemd assumed, no-op if absent)
# ----------------------------------------------------------------------------
svc() { # svc start|stop|status name
	command -v systemctl >/dev/null 2>&1 || { warn "no systemctl; skip $1 $2"; return 0; }
	systemctl "$1" "$2" 2>/dev/null || warn "systemctl $1 $2 failed"
}

# manifest_write DIR — record what/when/versions into the staging dir.
manifest_write() {
	local dir="$1"
	{
		echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "host=$(hostname -f 2>/dev/null || hostname)"
		echo "db_type=$DB_TYPE"
		echo "db_name=${DB_NAME:-}"
		echo "recordings=${BACKUP_RECORDINGS}"
		echo "compression=${COMPRESS}"
		echo "encryption=${ENCRYPTION}"
		echo "tool_version=1.2.0"
		echo "fusionpbx_version=$(sed -n 's/.*full[^0-9]*\([0-9.]*\).*/\1/p' \
			/var/www/fusionpbx/resources/version.php 2>/dev/null | head -n1)"
		echo "freeswitch_version=$(fs_cli -x 'version' 2>/dev/null | head -n1)"
	} > "$dir/MANIFEST"
}
