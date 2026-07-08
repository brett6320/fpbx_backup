#!/usr/bin/env bash
# lib/crypto.sh — encrypt/decrypt archives at rest. Modes: none | age | gpg.
# Sourced, not run.

# crypto_suffix — filename suffix for the active mode ("" for none).
crypto_suffix() {
	case "$ENCRYPTION" in
		age) echo ".age" ;;
		gpg) echo ".gpg" ;;
		none|"") echo "" ;;
		*) die "unknown ENCRYPTION: $ENCRYPTION" ;;
	esac
}

# crypto_encrypt INFILE — encrypt in place, echo resulting path.
# For none, echoes INFILE unchanged.
crypto_encrypt() {
	local in="$1" out
	case "$ENCRYPTION" in
		none|"") echo "$in"; return 0 ;;
		age)
			need age "install age"
			[ -n "${AGE_RECIPIENTS:-}" ] || die "ENCRYPTION=age but AGE_RECIPIENTS unset"
			out="$in.age"
			local rargs=() r
			for r in $AGE_RECIPIENTS; do rargs+=(-r "$r"); done
			age -e "${rargs[@]}" -o "$out" "$in" || die "age encrypt failed"
			;;
		gpg)
			need gpg "install gnupg"
			[ -n "${GPG_RECIPIENT:-}" ] || die "ENCRYPTION=gpg but GPG_RECIPIENT unset"
			out="$in.gpg"
			gpg --batch --yes --trust-model always \
				-r "$GPG_RECIPIENT" -o "$out" -e "$in" || die "gpg encrypt failed"
			;;
	esac
	rm -f "$in"          # remove plaintext archive
	echo "$out"
}

# crypto_decrypt INFILE — decrypt to a plaintext path, echo it.
# Detects mode from extension so restore works regardless of config.
crypto_decrypt() {
	local in="$1" out
	case "$in" in
		*.age)
			need age "install age"
			[ -n "${AGE_IDENTITY:-}" ] || die "set AGE_IDENTITY=/path/to/private age key"
			out="${in%.age}"
			age -d -i "$AGE_IDENTITY" -o "$out" "$in" || die "age decrypt failed"
			echo "$out" ;;
		*.gpg)
			need gpg "install gnupg"
			out="${in%.gpg}"
			gpg --batch --yes -o "$out" -d "$in" || die "gpg decrypt failed"
			echo "$out" ;;
		*)
			echo "$in" ;;   # already plaintext
	esac
}
