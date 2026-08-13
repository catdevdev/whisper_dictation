#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd -P)"
DIST="$ROOT/dist"
APP="$DIST/Whisper.app"
BUILD="$ROOT/.build/manual"
IDENTITY_FILE="$ROOT/Config/LocalCodeSigningIdentity.sha1"
ALLOW_ADHOC="${WHISPER_ALLOW_ADHOC:-0}"

die() {
    echo "error: $*" >&2
    exit 1
}

assert_safe_output_parent() {
    local path="$1"
    local label="$2"
    local relative
    local component
    local current
    local resolved

    [[ "$ROOT" == /* && "$ROOT" != "/" ]] || \
        die "unsafe canonical repository root: $ROOT"
    case "$path" in
        "$ROOT"/*) ;;
        *) die "$label escapes the repository: $path" ;;
    esac

    relative="${path#"$ROOT"/}"
    current="$ROOT"
    while [[ -n "$relative" ]]; do
        component="${relative%%/*}"
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || \
            die "$label contains an unsafe path component: $path"
        current="$current/$component"
        [[ ! -L "$current" ]] || \
            die "$label contains a symbolic-link path component: $current"
        if [[ -e "$current" && ! -d "$current" ]]; then
            die "$label path component is not a directory: $current"
        fi
        if [[ "$relative" == */* ]]; then
            relative="${relative#*/}"
        else
            relative=""
        fi
    done

    if [[ -d "$path" ]]; then
        resolved="$(cd -P -- "$path" && pwd -P)" || \
            die "could not resolve $label: $path"
        case "$resolved" in
            "$ROOT"/*) ;;
            *) die "$label resolves outside the repository: $resolved" ;;
        esac
    fi
}

assert_safe_output_target() {
    local path="$1"
    local label="$2"

    case "$path" in
        "$ROOT"/*) ;;
        *) die "$label escapes the repository: $path" ;;
    esac
    [[ ! -L "$path" ]] || die "$label must not be a symbolic link: $path"
}

assert_no_output_symlinks() {
    local path="$1"
    local label="$2"
    local first_symlink
    local status

    [[ -d "$path" ]] || return 0
    if first_symlink="$(find "$path" -type l -print -quit 2>&1)"; then
        :
    else
        status=$?
        die "could not inspect $label for symbolic links (exit $status): $first_symlink"
    fi
    [[ -z "$first_symlink" ]] || \
        die "$label contains a symbolic link: $first_symlink"
}

validate_output_paths() {
    assert_safe_output_parent "$DIST" "dist output parent"
    assert_safe_output_parent "$BUILD" ".build output parent"
    assert_safe_output_target "$APP" "application output"
    assert_safe_output_target "$BUILD/Whisper" "executable output"
    assert_safe_output_target "$BUILD/Whisper.designated-requirement" \
        "designated-requirement output"
    assert_no_output_symlinks "$BUILD" ".build/manual output tree"
}

normalize_fingerprint() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

identity_is_valid() {
    local fingerprint="$1"
    local listing
    local status

    if listing="$(security find-identity -v -p codesigning 2>&1)"; then
        :
    else
        status=$?
        die "security find-identity failed (exit $status): $listing"
    fi
    printf '%s\n' "$listing" | awk -v wanted="$fingerprint" '
        {
            for (i = 1; i <= NF; i++) {
                token = toupper($i)
                gsub(/[^0-9A-F]/, "", token)
                if (token == wanted) found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

# Validate every output ancestor before tests or compilers can write into them.
# In particular, an existing dist, .build, .build/manual, test-output, or output
# file symlink must never redirect rm, swiftc, or signing output outside this
# canonical repository.
validate_output_paths

[[ "$ALLOW_ADHOC" == "0" || "$ALLOW_ADHOC" == "1" ]] || \
    die "WHISPER_ALLOW_ADHOC must be 0 or 1"

SIGNING_IDENTITY=""
if [[ -n "${WHISPER_CODESIGN_IDENTITY:-}" ]]; then
    SIGNING_IDENTITY="$WHISPER_CODESIGN_IDENTITY"
elif [[ -f "$IDENTITY_FILE" ]]; then
    SIGNING_IDENTITY="$(tr -d '[:space:]' < "$IDENTITY_FILE")"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
    if [[ "$ALLOW_ADHOC" == "1" ]]; then
        SIGNING_IDENTITY="-"
    else
        die "no signing identity configured; run ./scripts/setup-local-signing.sh or set WHISPER_CODESIGN_IDENTITY to a SHA-1 fingerprint"
    fi
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    [[ "$ALLOW_ADHOC" == "1" ]] || \
        die "ad-hoc signing requires WHISPER_ALLOW_ADHOC=1"
    SIGNING_MODE="adhoc"
else
    [[ "$SIGNING_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] || \
        die "the signing identity must be a 40-character SHA-1 certificate fingerprint"
    SIGNING_IDENTITY="$(normalize_fingerprint "$SIGNING_IDENTITY")"
    identity_is_valid "$SIGNING_IDENTITY" || \
        die "signing identity $SIGNING_IDENTITY is not a valid code-signing identity in the keychain"
    SIGNING_MODE="certificate"
fi

cd "$ROOT"
validate_output_paths
"$ROOT/scripts/test-core.sh"
validate_output_paths
"$ROOT/scripts/test-app-state.sh"
validate_output_paths
"$ROOT/scripts/test-hud-layout.sh"
validate_output_paths
"$ROOT/scripts/test-services.sh"
validate_output_paths
"$ROOT/scripts/test-speech-language.sh"
validate_output_paths

if [[ -d "$ROOT/ChromeExtension" ]]; then
    command -v npm >/dev/null 2>&1 || \
        die "npm is required to validate the bundled Chrome extension"
    npm --prefix "$ROOT/ChromeExtension" test
    npm --prefix "$ROOT/ChromeExtension" run check
fi
validate_output_paths

app_sources=()
while IFS= read -r source; do
    app_sources+=("$source")
done < <(find "$ROOT/Sources/WhisperApp" -name '*.swift' -type f | sort)

swiftc \
    -target arm64-apple-macosx14.0 \
    -swift-version 5 \
    -strict-concurrency=complete \
    -warn-concurrency \
    -warnings-as-errors \
    -O \
    -parse-as-library \
    -module-name WhisperApp \
    -I "$BUILD" \
    -L "$BUILD" \
    -lWhisperCore \
    "${app_sources[@]}" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework AVFoundation \
    -framework CoreGraphics \
    -framework CryptoKit \
    -framework NaturalLanguage \
    -framework Network \
    -framework Security \
    -framework ServiceManagement \
    -o "$BUILD/Whisper"

validate_output_paths
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Whisper" "$APP/Contents/MacOS/Whisper"
cp "$ROOT/Config/Info.plist" "$APP/Contents/Info.plist"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist"
fi

QWEN_WORKER="$ROOT/Resources/qwen_tts_worker.py"
[[ -f "$QWEN_WORKER" && ! -L "$QWEN_WORKER" ]] || \
    die "Qwen TTS worker source is missing or unsafe: $QWEN_WORKER"
command -v python3 >/dev/null 2>&1 || \
    die "python3 is required to validate the bundled Qwen worker"
python3 -I -c \
    'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' \
    "$QWEN_WORKER"
cp "$QWEN_WORKER" "$APP/Contents/Resources/qwen_tts_worker.py"
chmod 0644 "$APP/Contents/Resources/qwen_tts_worker.py"

if [[ -d "$ROOT/ChromeExtension" ]]; then
    assert_no_output_symlinks "$ROOT/ChromeExtension" "Chrome extension source"
    ditto "$ROOT/ChromeExtension" "$APP/Contents/Resources/ChromeExtension"
fi

plutil -lint "$APP/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || die "unsafe CFBundleIdentifier: $BUNDLE_ID"

if [[ "$SIGNING_MODE" == "certificate" ]]; then
    REQUIREMENT_FILE="$BUILD/Whisper.designated-requirement"
    EXPECTED_EXPRESSION="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$SIGNING_IDENTITY\""
    EXPECTED_REQUIREMENT="designated => $EXPECTED_EXPRESSION"
    printf '%s\n' "$EXPECTED_REQUIREMENT" > "$REQUIREMENT_FILE"
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp=none \
        --requirements "$REQUIREMENT_FILE" \
        --entitlements "$ROOT/Config/Whisper.entitlements" "$APP"
else
    echo "warning: building with an unstable ad-hoc identity" >&2
    codesign --force --sign - --options runtime --timestamp=none \
        --entitlements "$ROOT/Config/Whisper.entitlements" "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE_INFO="$(codesign --display --verbose=4 "$APP" 2>&1)"

if [[ "$SIGNING_MODE" == "certificate" ]]; then
    [[ "$SIGNATURE_INFO" != *"Signature=adhoc"* ]] || die "unexpected ad-hoc signature"
    codesign --verify --deep --strict --verbose=2 \
        -R="$EXPECTED_EXPRESSION" "$APP"
    DESIGNATED_REQUIREMENT="$(codesign --display --requirements - "$APP" 2>&1)"
    DESIGNATED_REQUIREMENT="$(printf '%s' "$DESIGNATED_REQUIREMENT" | tr '[:lower:]' '[:upper:]')"
    [[ "$DESIGNATED_REQUIREMENT" == *"CERTIFICATE LEAF"* ]] || \
        die "designated requirement is not certificate-backed"
    [[ "$DESIGNATED_REQUIREMENT" == *"$SIGNING_IDENTITY"* ]] || \
        die "designated requirement does not bind the selected certificate"
    [[ "$DESIGNATED_REQUIREMENT" != *"CDHASH"* ]] || \
        die "designated requirement unexpectedly depends on cdhash"
else
    [[ "$SIGNATURE_INFO" == *"Signature=adhoc"* ]] || die "expected an ad-hoc signature"
fi

echo "$APP"
