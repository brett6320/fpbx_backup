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
# Reads FPBX_CONFIG (INI-ish, keys like  database.0.host = 127.0.0.1 ).
# Exports: DB_TYPE DB_HOST DB_PORT DB_NAME DB_USER DB_PASS DB_SSLMODE DB_PATH
# DB_TYPE is normalized to  pgsql  or  sqlite .
detect_db() {
	[ -f "$FPBX_CONFIG" ] || die "FusionPBX config not found: $FPBX_CONFIG"

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

	# Normalize type.
	case "$DB_TYPE" in
		pgsql|postgres|postgresql) DB_TYPE="pgsql" ;;
		sqlite|sqlite3)            DB_TYPE="sqlite" ;;
		"") die "could not read database.0.type from $FPBX_CONFIG" ;;
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
		# SQLite: path may be relative to FusionPBX; default location.
		: "${DB_PATH:=/var/lib/fusionpbx/database/fusionpbx.db}"
	fi

	export DB_TYPE DB_HOST DB_PORT DB_NAME DB_USER DB_PASS DB_SSLMODE DB_PATH
	log "detected DB: type=$DB_TYPE${DB_NAME:+ name=$DB_NAME}${DB_PATH:+ path=$DB_PATH}"
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
		echo "encryption=${ENCRYPTION}"
		echo "tool_version=1.0.0"
		echo "fusionpbx_version=$(sed -n 's/.*full[^0-9]*\([0-9.]*\).*/\1/p' \
			/var/www/fusionpbx/resources/version.php 2>/dev/null | head -n1)"
		echo "freeswitch_version=$(fs_cli -x 'version' 2>/dev/null | head -n1)"
	} > "$dir/MANIFEST"
}
