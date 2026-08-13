#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
IDENTITY_NAME="Whisper Local Code Signing"
IDENTITY_FILE="$ROOT/Config/LocalCodeSigningIdentity.sha1"

die() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./scripts/setup-local-signing.sh

Validates the existing login-keychain identity "Whisper Local Code Signing"
and writes only its public SHA-1 fingerprint to
Config/LocalCodeSigningIdentity.sha1. An existing fingerprint is never rotated
automatically: it must be valid and match the discovered identity.

The script never creates, imports, exports, unlocks, or changes trust for keys.
Create the identity with macOS Keychain Access Certificate Assistant first.
EOF
}

valid_identity_hashes() {
    local listing
    local status

    if listing="$(security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>&1)"; then
        :
    else
        status=$?
        die "security find-identity failed (exit $status) for $LOGIN_KEYCHAIN: $listing"
    fi
    printf '%s\n' "$listing" | awk -v wanted="\"$IDENTITY_NAME\"" '
        index($0, wanted) {
            for (i = 1; i <= NF; i++) {
                token = toupper($i)
                gsub(/[^0-9A-F]/, "", token)
                if (length(token) == 40 && !seen[token]++) print token
            }
        }
    '
}

login_keychain_path() {
    local keychain
    local status

    if keychain="$(security login-keychain 2>&1)"; then
        :
    else
        status=$?
        die "security login-keychain failed (exit $status): $keychain"
    fi

    keychain="${keychain#"${keychain%%[![:space:]]*}"}"
    keychain="${keychain%"${keychain##*[![:space:]]}"}"
    if [[ "$keychain" == \"*\" ]]; then
        keychain="${keychain#\"}"
        keychain="${keychain%\"}"
    fi
    [[ -n "$keychain" ]] || die "could not locate the login keychain"
    printf '%s\n' "$keychain"
}

write_fingerprint() {
    local fingerprint="$1"
    local temporary_file
    mkdir -p "$ROOT/Config"
    temporary_file="$(mktemp "$IDENTITY_FILE.tmp.XXXXXX")"
    printf '%s\n' "$fingerprint" > "$temporary_file"
    mv "$temporary_file" "$IDENTITY_FILE"
    echo "Configured $IDENTITY_NAME ($fingerprint)."
}

configure_fingerprint() {
    local fingerprint="$1"
    local pinned

    if [[ -e "$IDENTITY_FILE" || -L "$IDENTITY_FILE" ]]; then
        [[ -f "$IDENTITY_FILE" && ! -L "$IDENTITY_FILE" ]] || \
            die "existing signing identity pin is not a regular file: $IDENTITY_FILE"
        [[ -r "$IDENTITY_FILE" ]] || \
            die "existing signing identity pin is not readable: $IDENTITY_FILE"
        pinned="$(< "$IDENTITY_FILE")"
        [[ "$pinned" =~ ^[0-9A-Fa-f]{40}$ ]] || \
            die "existing signing identity pin must contain exactly 40 hexadecimal characters"
        pinned="$(printf '%s' "$pinned" | tr '[:lower:]' '[:upper:]')"
        [[ "$pinned" == "$fingerprint" ]] || \
            die "existing signing identity pin $pinned does not match $fingerprint; refusing automatic identity rotation"
        echo "Already configured $IDENTITY_NAME ($fingerprint)."
        return
    fi

    [[ ! -L "$ROOT/Config" ]] || \
        die "Config must not be a symbolic link: $ROOT/Config"
    if [[ -e "$ROOT/Config" && ! -d "$ROOT/Config" ]]; then
        die "Config is not a directory: $ROOT/Config"
    fi
    write_fingerprint "$fingerprint"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi
[[ $# -eq 0 ]] || die "unknown argument: $1"

# Argument handling, especially --help, must finish before querying Keychain.
LOGIN_KEYCHAIN="$(login_keychain_path)"

VALID_HASHES="$(valid_identity_hashes)"
VALID_COUNT="$(printf '%s\n' "$VALID_HASHES" | awk 'NF { count++ } END { print count + 0 }')"

if [[ "$VALID_COUNT" -eq 1 ]]; then
    configure_fingerprint "$VALID_HASHES"
    exit 0
fi

[[ "$VALID_COUNT" -eq 0 ]] || \
    die "multiple valid identities named $IDENTITY_NAME; remove the duplicate safely"

cat >&2 <<'EOF'
No valid "Whisper Local Code Signing" identity was found.

Create it in Keychain Access > Certificate Assistant > Create a Certificate:
  Name: Whisper Local Code Signing
  Identity Type: Self Signed Root
  Certificate Type: Code Signing
  Override defaults: enabled
  Validity: 3650 days
  Key: RSA, 4096 bits
  Key Usage: Signature + Certificate Signing, critical
  Extended Key Usage: Code Signing only, critical
  Basic Constraints: CA, path length 0
  Subject Alternate Name: disabled
  Keychain: login

Then set only Trust > Code Signing to Always Trust, leave the general trust
setting at System Defaults, and rerun this script.
EOF
exit 1
