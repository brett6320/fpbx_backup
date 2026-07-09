#!/usr/bin/env bash
# lib/db.sh — database dump/restore for PostgreSQL and SQLite.
# Requires detect_db() to have run (DB_* exported). Sourced, not run.

# Build a libpq env line for pg tools. Echoes nothing; sets PG* in caller env.
_pg_env() {
	export PGHOST="$DB_HOST" PGPORT="$DB_PORT" PGDATABASE="$DB_NAME" \
	       PGUSER="$DB_USER" PGSSLMODE="${DB_SSLMODE:-prefer}"
	[ -n "${DB_PASS:-}" ] && export PGPASSWORD="$DB_PASS"
}

# db_dump OUTDIR — write DB dump into OUTDIR. Echoes the dump filename.
db_dump() {
	local out="$1"
	if [ "$DB_TYPE" = "pgsql" ]; then
		need pg_dump "install postgresql-client"
		_pg_env
		local f="$out/db_${DB_NAME}.pg.dump"
		# Custom format (-Fc): compressed, selective restore, parallel-capable.
		log "pg_dump $DB_NAME -> $(basename "$f")"
		pg_dump -Fc --no-owner --no-privileges -f "$f" \
			|| die "pg_dump failed"
		# Also capture roles/globals so a fresh host can recreate the login role.
		if command -v pg_dumpall >/dev/null 2>&1; then
			pg_dumpall --roles-only --no-role-passwords \
				> "$out/db_globals.sql" 2>/dev/null \
				|| warn "pg_dumpall roles skipped (needs superuser)"
		fi
		echo "$f"
	else
		need sqlite3 "install sqlite3"
		[ -f "$DB_PATH" ] || die "sqlite db not found: $DB_PATH"
		local f="$out/db_fusionpbx.sqlite"
		log "sqlite backup $DB_PATH -> $(basename "$f")"
		# .backup is safe against a live/locked DB (online backup API).
		sqlite3 "$DB_PATH" ".backup '$f'" || die "sqlite backup failed"
		# Compress the raw .sqlite (pg dumps are already compressed; this isn't).
		if [ -z "${COMPRESS_PROG+x}" ] && command -v compress_resolve >/dev/null 2>&1; then
			compress_resolve
		fi
		f="$(compress_file "$f")"
		echo "$f"
	fi
}

# db_restore DUMPFILE [GLOBALSSQL] — restore DB from a dump produced above.
db_restore() {
	local dump="$1" globals="${2:-}"
	[ -f "$dump" ] || die "dump file missing: $dump"

	if [ "$DB_TYPE" = "pgsql" ]; then
		need pg_restore "install postgresql-client"
		need psql "install postgresql-client"
		_pg_env

		# Recreate roles first (ignored if they exist).
		if [ -n "$globals" ] && [ -f "$globals" ]; then
			log "restoring roles/globals"
			PGDATABASE="postgres" psql -v ON_ERROR_STOP=0 -q -f "$globals" \
				>/dev/null 2>&1 || warn "some globals not applied (may already exist)"
		fi

		# Ensure target DB exists.
		if ! PGDATABASE="postgres" psql -tAc \
			"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
			log "creating database $DB_NAME"
			PGDATABASE="postgres" createdb -O "$DB_USER" "$DB_NAME" \
				|| die "createdb failed"
		fi

		log "pg_restore -> $DB_NAME (clean)"
		# --clean drops objects first so restore is idempotent; ignore benign errs.
		pg_restore --no-owner --no-privileges --clean --if-exists \
			-d "$DB_NAME" "$dump" \
			|| warn "pg_restore reported errors (often benign with --clean)"
	else
		need sqlite3 "install sqlite3"
		log "restoring sqlite -> $DB_PATH"
		mkdir -p "$(dirname "$DB_PATH")"
		[ -f "$DB_PATH" ] && cp -a "$DB_PATH" "$DB_PATH.pre-restore.$(date +%s)"
		# Decompress the dump if it was compressed at backup time.
		case "$dump" in
			*.zst) need zstd; zstd -dc "$dump" > "$DB_PATH" ;;
			*.gz)  need gzip; gzip -dc "$dump" > "$DB_PATH" ;;
			*.xz)  need xz;   xz   -dc "$dump" > "$DB_PATH" ;;
			*)     cp -a "$dump" "$DB_PATH" ;;
		esac
		# Fix ownership so FreeSWITCH/php can write.
		chown www-data:www-data "$DB_PATH" 2>/dev/null || true
	fi
}
