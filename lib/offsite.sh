#!/usr/bin/env bash
# lib/offsite.sh — push/pull archives to remote storage. Sourced, not run.
# Modes: none | s3 | rclone | rsync.

# offsite_push FILE — copy FILE to the configured remote. Non-fatal on failure.
offsite_push() {
	local f="$1" base; base="$(basename "$f")"
	case "$OFFSITE" in
		none|"") return 0 ;;
		s3)
			need aws "install awscli"
			local dst="s3://$S3_BUCKET/${S3_PREFIX:+$S3_PREFIX/}$base"
			log "offsite s3 -> $dst"
			aws ${AWS_PROFILE:+--profile "$AWS_PROFILE"} s3 cp "$f" "$dst" \
				|| { warn "s3 upload failed"; return 1; } ;;
		rclone)
			need rclone "install rclone"
			log "offsite rclone -> $RCLONE_DEST/$base"
			rclone copyto "$f" "$RCLONE_DEST/$base" \
				|| { warn "rclone upload failed"; return 1; } ;;
		rsync)
			need rsync "install rsync"
			local sshopt=""
			[ -n "${RSYNC_SSH_KEY:-}" ] && sshopt="-e 'ssh -i $RSYNC_SSH_KEY'"
			log "offsite rsync -> $RSYNC_DEST/"
			eval rsync -a $sshopt "'$f'" "'$RSYNC_DEST/'" \
				|| { warn "rsync upload failed"; return 1; } ;;
		*) warn "unknown OFFSITE: $OFFSITE"; return 1 ;;
	esac
}

# offsite_pull NAME DESTDIR — fetch archive NAME from remote into DESTDIR.
# Echoes the local path on success.
offsite_pull() {
	local name="$1" f="$2/$1"
	case "$OFFSITE" in
		s3)
			need aws; aws ${AWS_PROFILE:+--profile "$AWS_PROFILE"} \
				s3 cp "s3://$S3_BUCKET/${S3_PREFIX:+$S3_PREFIX/}$name" "$f" \
				|| die "s3 fetch failed" ;;
		rclone)
			need rclone; rclone copyto "$RCLONE_DEST/$name" "$f" \
				|| die "rclone fetch failed" ;;
		rsync)
			need rsync
			local sshopt=""
			[ -n "${RSYNC_SSH_KEY:-}" ] && sshopt="-e 'ssh -i $RSYNC_SSH_KEY'"
			eval rsync -a $sshopt "'$RSYNC_DEST/$name'" "'$f'" \
				|| die "rsync fetch failed" ;;
		*) die "OFFSITE not configured for pull" ;;
	esac
	echo "$f"
}
