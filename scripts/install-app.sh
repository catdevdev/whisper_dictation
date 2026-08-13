#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_APP="${1:-$ROOT/dist/Whisper.app}"
DESTINATION_APP="${2:-/Applications/Whisper.app}"
ALLOW_IDENTITY_MIGRATION="${WHISPER_ALLOW_IDENTITY_MIGRATION:-0}"
IDENTITY_FILE="$ROOT/Config/LocalCodeSigningIdentity.sha1"
RENAME_EXCLUSIVE_SOURCE="$ROOT/scripts/rename-exclusive.c"

die() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: ./scripts/install-app.sh [source.app] [destination.app]

Verifies a certificate-backed signature, refuses designated-requirement drift,
then replaces the destination bundle. No privilege escalation is attempted.

The one-time migration from an older ad-hoc build requires:
  WHISPER_ALLOW_IDENTITY_MIGRATION=1 ./scripts/install-app.sh
EOF
}

designated_requirement() {
    local output
    output="$(codesign --display --requirements - "$1" 2>&1)" || return 1
    printf '%s\n' "$output" | awk '/^[[:space:]]*designated => / { sub(/^[[:space:]]*/, ""); print; exit }'
}

signature_snapshot() {
    local app="$1"
    local signature_info requirement cdhash identifier signature_kind

    [[ -d "$app" ]] || {
        echo "error: app bundle not found: $app" >&2
        return 1
    }
    codesign --verify --deep --strict --verbose=2 "$app" || {
        echo "error: code signature verification failed: $app" >&2
        return 1
    }
    signature_info="$(codesign --display --verbose=4 "$app" 2>&1)" || {
        echo "error: cannot read code signature metadata: $app" >&2
        return 1
    }
    requirement="$(designated_requirement "$app")" || {
        echo "error: cannot read designated requirement: $app" >&2
        return 1
    }
    cdhash="$(printf '%s\n' "$signature_info" | awk -F= '/^CDHash=/ { print $2; exit }')"
    [[ "$cdhash" =~ ^[0-9A-Fa-f]+$ ]] || {
        echo "error: cannot read code-directory hash: $app" >&2
        return 1
    }
    identifier="$(printf '%s\n' "$signature_info" | awk -F= '/^Identifier=/ { print $2; exit }')"
    [[ "$identifier" =~ ^[A-Za-z0-9.-]+$ ]] || {
        echo "error: cannot read a safe bundle identifier: $app" >&2
        return 1
    }
    if [[ "$signature_info" == *"Signature=adhoc"* ]]; then
        signature_kind="adhoc"
    else
        signature_kind="certificate"
    fi

    printf '%s\t%s\t%s\t%s\n' "$signature_kind" "$cdhash" "$identifier" "$requirement"
}

verify_certificate_backed_app() {
    local app="$1"
    local snapshot signature_kind remainder identifier requirement

    snapshot="$(signature_snapshot "$app")" || die "cannot verify app identity: $app"
    signature_kind="${snapshot%%$'\t'*}"
    remainder="${snapshot#*$'\t'}"
    remainder="${remainder#*$'\t'}"
    identifier="${remainder%%$'\t'*}"
    requirement="${remainder#*$'\t'}"
    [[ "$signature_kind" == "certificate" ]] || die "refusing to install an ad-hoc signed app"
    [[ -n "$requirement" && "$requirement" == *"certificate"* ]] || \
        die "designated requirement is not certificate-backed: $app"
    [[ "$requirement" != *"cdhash"* ]] || \
        die "designated requirement depends on cdhash: $app"
    printf '%s\n' "$requirement"
}

file_identity() {
    /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null
}

move_directory_exact() {
    local source="$1"
    local target="$2"
    local source_identity target_identity helper_status current_source_identity

    source_identity="$(file_identity "$source")" || return 1
    if "$RENAME_EXCLUSIVE_TOOL" "$source" "$target"; then
        :
    else
        helper_status=$?
        if [[ -e "$source" || -L "$source" ]]; then
            current_source_identity="$(file_identity "$source")" || return 3
            [[ "$current_source_identity" == "$source_identity" ]] || return 3
            return "$helper_status"
        fi
        if [[ -e "$target" || -L "$target" ]]; then
            target_identity="$(file_identity "$target")" || return 3
            [[ "$target_identity" == "$source_identity" ]] && return 0
        fi
        return 3
    fi

    target_identity="$(file_identity "$target")" || return 3
    [[ "$target_identity" == "$source_identity" ]] || return 3
}

restore_install_signal_traps() {
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

ignore_install_signals() {
    trap '' HUP INT TERM
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi
[[ $# -le 2 ]] || die "too many arguments"
[[ "$ALLOW_IDENTITY_MIGRATION" == "0" || "$ALLOW_IDENTITY_MIGRATION" == "1" ]] || \
    die "WHISPER_ALLOW_IDENTITY_MIGRATION must be 0 or 1"

EXPECTED_IDENTITY="${WHISPER_CODESIGN_IDENTITY:-}"
if [[ -z "$EXPECTED_IDENTITY" && -f "$IDENTITY_FILE" ]]; then
    EXPECTED_IDENTITY="$(tr -d '[:space:]' < "$IDENTITY_FILE")"
fi
[[ "$EXPECTED_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] || \
    die "a pinned 40-character signing fingerprint is required"
EXPECTED_IDENTITY="$(printf '%s' "$EXPECTED_IDENTITY" | tr '[:upper:]' '[:lower:]')"
EXPECTED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/Config/Info.plist")"
[[ "$EXPECTED_BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || \
    die "unsafe configured bundle identifier: $EXPECTED_BUNDLE_ID"
EXPECTED_REQUIREMENT="designated => identifier \"$EXPECTED_BUNDLE_ID\" and certificate leaf = H\"$EXPECTED_IDENTITY\""

SOURCE_NAME="$(basename -- "$SOURCE_APP")"
[[ "$SOURCE_NAME" == *.app && "$SOURCE_NAME" != "." && "$SOURCE_NAME" != ".." ]] || \
    die "source must name a specific .app bundle"
[[ -d "$SOURCE_APP" && ! -L "$SOURCE_APP" ]] || \
    die "source app is missing, not a directory, or a symbolic link: $SOURCE_APP"
SOURCE_APP="$(cd -P -- "$SOURCE_APP" && pwd -P)"

DESTINATION_NAME="$(basename -- "$DESTINATION_APP")"
[[ "$DESTINATION_NAME" == *.app && "$DESTINATION_NAME" != "." && "$DESTINATION_NAME" != ".." ]] || \
    die "destination must name a specific .app bundle"
DESTINATION_PARENT="$(cd -P -- "$(dirname -- "$DESTINATION_APP")" && pwd -P)"
DESTINATION_APP="$DESTINATION_PARENT/$DESTINATION_NAME"
[[ "$DESTINATION_APP" != "/" && "$DESTINATION_APP" != "$DESTINATION_PARENT" ]] || \
    die "unsafe destination: $DESTINATION_APP"
[[ ! -L "$DESTINATION_APP" ]] || die "refusing to replace a symlink: $DESTINATION_APP"
case "$DESTINATION_PARENT/" in
    "$SOURCE_APP/"*)
        die "destination parent must not be the source bundle or its descendant"
        ;;
esac

SOURCE_REQUIREMENT="$(verify_certificate_backed_app "$SOURCE_APP")"
[[ "$SOURCE_REQUIREMENT" == "$EXPECTED_REQUIREMENT" ]] || {
    echo "error: refusing an app that does not match the pinned Whisper identity" >&2
    echo "expected: $EXPECTED_REQUIREMENT" >&2
    echo "actual:   $SOURCE_REQUIREMENT" >&2
    exit 1
}
[[ -d "$DESTINATION_PARENT" ]] || die "destination directory does not exist: $DESTINATION_PARENT"
STAGING_DIR="$(mktemp -d "$DESTINATION_PARENT/.whisper-install.XXXXXX")"
LOCK_DIR="$DESTINATION_PARENT/.$DESTINATION_NAME.whisper-install-lock"
BACKUP_APP=""
BACKUP_CREATED=0
DESTINATION_REPLACED=0
INSTALL_COMMITTED=0
LOCK_CREATED=0
PRESERVE_TRANSACTION=0
EXPECTED_DESTINATION_FILE_ID=""

cleanup() {
    local exit_status=$?
    local failed_app="$STAGING_DIR/Failed.app"
    trap - EXIT HUP INT TERM

    if [[ "$INSTALL_COMMITTED" == "0" && "$PRESERVE_TRANSACTION" == "0" ]]; then
        if [[ "$DESTINATION_REPLACED" == "1" && -e "$DESTINATION_APP" ]]; then
            current_destination_file_id="$(file_identity "$DESTINATION_APP" || true)"
            if [[ -z "$current_destination_file_id" || \
                  "$current_destination_file_id" != "$EXPECTED_DESTINATION_FILE_ID" ]]; then
                echo "critical: destination changed during rollback; transaction preserved at $STAGING_DIR" >&2
                return "$exit_status"
            fi
            if ! move_directory_exact "$DESTINATION_APP" "$failed_app"; then
                echo "critical: rollback could not isolate the failed app; transaction preserved at $STAGING_DIR" >&2
                return "$exit_status"
            fi
        fi
        if [[ "$BACKUP_CREATED" == "1" && -e "$BACKUP_APP" ]]; then
            if ! move_directory_exact "$BACKUP_APP" "$DESTINATION_APP"; then
                echo "critical: rollback failed; backup preserved at $BACKUP_APP" >&2
                return "$exit_status"
            fi
        fi
    fi
    if [[ "$PRESERVE_TRANSACTION" == "1" ]]; then
        echo "critical: transaction preserved for manual recovery at $STAGING_DIR" >&2
        return "$exit_status"
    fi
    rm -rf "$STAGING_DIR"
    if [[ "$LOCK_CREATED" == "1" ]] && ! rmdir "$LOCK_DIR"; then
        echo "critical: could not remove install lock: $LOCK_DIR" >&2
        [[ "$exit_status" != "0" ]] || exit_status=1
    fi
    return "$exit_status"
}
trap cleanup EXIT
restore_install_signal_traps

ignore_install_signals
if mkdir "$LOCK_DIR"; then
    LOCK_CREATED=1
    restore_install_signal_traps
else
    restore_install_signal_traps
    die "another install is active or a stale lock exists: $LOCK_DIR"
fi

[[ -f "$RENAME_EXCLUSIVE_SOURCE" && ! -L "$RENAME_EXCLUSIVE_SOURCE" ]] || \
    die "exclusive-rename helper source is missing or unsafe"
RENAME_EXCLUSIVE_TOOL="$STAGING_DIR/rename-exclusive"
/usr/bin/xcrun clang -std=c11 -Wall -Wextra -Werror -Os \
    "$RENAME_EXCLUSIVE_SOURCE" -o "$RENAME_EXCLUSIVE_TOOL"
[[ -x "$RENAME_EXCLUSIVE_TOOL" && ! -L "$RENAME_EXCLUSIVE_TOOL" ]] || \
    die "exclusive-rename helper was not created safely"

STAGED_COMPONENT="$(basename "$STAGING_DIR").incoming.app"
STAGED_APP="$STAGING_DIR/$STAGED_COMPONENT"
ditto "$SOURCE_APP" "$STAGED_APP"
STAGED_REQUIREMENT="$(verify_certificate_backed_app "$STAGED_APP")"
[[ "$STAGED_REQUIREMENT" == "$SOURCE_REQUIREMENT" ]] || die "signature identity changed while staging"

if [[ -e "$DESTINATION_APP" ]]; then
    DESTINATION_SNAPSHOT="$(signature_snapshot "$DESTINATION_APP")" || \
        die "installed app has an invalid or unreadable signature"
    DESTINATION_KIND="${DESTINATION_SNAPSHOT%%$'\t'*}"
    DESTINATION_REMAINDER="${DESTINATION_SNAPSHOT#*$'\t'}"
    DESTINATION_REMAINDER="${DESTINATION_REMAINDER#*$'\t'}"
    DESTINATION_IDENTIFIER="${DESTINATION_REMAINDER%%$'\t'*}"
    DESTINATION_REQUIREMENT="${DESTINATION_REMAINDER#*$'\t'}"
    [[ "$DESTINATION_IDENTIFIER" == "$EXPECTED_BUNDLE_ID" ]] || \
        die "installed app has an unexpected bundle identifier: $DESTINATION_IDENTIFIER"
    if [[ "$DESTINATION_KIND" == "certificate" && \
          "$DESTINATION_REQUIREMENT" != "$SOURCE_REQUIREMENT" ]]; then
        die "installed app uses a different certificate; automatic identity rotation is refused"
    fi
    if [[ "$DESTINATION_KIND" == "adhoc" ]]; then
        [[ "$ALLOW_IDENTITY_MIGRATION" == "1" ]] || {
            echo "error: installed app is ad-hoc signed; explicit one-time migration is required" >&2
            echo "installed: $DESTINATION_REQUIREMENT" >&2
            echo "incoming:  $SOURCE_REQUIREMENT" >&2
            exit 1
        }
        echo "warning: performing explicitly authorized one-time identity migration" >&2
    fi

    BACKUP_APP="$STAGING_DIR/Previous.app"
    ignore_install_signals
    if move_directory_exact "$DESTINATION_APP" "$BACKUP_APP"; then
        BACKUP_CREATED=1
        restore_install_signal_traps
    else
        move_status=$?
        [[ "$move_status" != "3" ]] || PRESERVE_TRANSACTION=1
        restore_install_signal_traps
        die "could not move installed app to backup safely (status $move_status)"
    fi
    BACKUP_SNAPSHOT="$(signature_snapshot "$BACKUP_APP")" || \
        die "installed app changed or became unreadable while it was moved to backup"
    [[ "$BACKUP_SNAPSHOT" == "$DESTINATION_SNAPSHOT" ]] || \
        die "installed app identity changed during installation; refusing replacement"
fi
EXPECTED_DESTINATION_FILE_ID="$(file_identity "$STAGED_APP")" || die "cannot identify staged app"
ignore_install_signals
if move_directory_exact "$STAGED_APP" "$DESTINATION_APP"; then
    DESTINATION_REPLACED=1
    restore_install_signal_traps
else
    move_status=$?
    [[ "$move_status" != "3" ]] || PRESERVE_TRANSACTION=1
    restore_install_signal_traps
    die "destination appeared or changed during install (status $move_status)"
fi
INSTALLED_REQUIREMENT="$(verify_certificate_backed_app "$DESTINATION_APP")"
[[ "$INSTALLED_REQUIREMENT" == "$SOURCE_REQUIREMENT" ]] || \
    die "installed app does not match the verified staged identity"
FINAL_DESTINATION_FILE_ID="$(file_identity "$DESTINATION_APP")" || {
    PRESERVE_TRANSACTION=1
    die "cannot identify the verified installed app"
}
[[ "$FINAL_DESTINATION_FILE_ID" == "$EXPECTED_DESTINATION_FILE_ID" ]] || {
    PRESERVE_TRANSACTION=1
    die "installed app changed after verification; transaction preserved"
}
INSTALL_COMMITTED=1
echo "Installed $DESTINATION_APP"
