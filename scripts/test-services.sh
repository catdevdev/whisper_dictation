#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build/manual/services"

mkdir -p "$BUILD"

core_sources=()
while IFS= read -r source; do
    core_sources+=("$source")
done < <(find "$ROOT/Sources/WhisperCore" -name '*.swift' -type f | sort)

swiftc \
    -target arm64-apple-macosx14.0 \
    -swift-version 5 \
    -strict-concurrency=complete \
    -warn-concurrency \
    -warnings-as-errors \
    -parse-as-library \
    -emit-module \
    -emit-library \
    -static \
    -module-name WhisperCore \
    -emit-module-path "$BUILD/WhisperCore.swiftmodule" \
    "${core_sources[@]}" \
    -o "$BUILD/libWhisperCore.a"

service_sources=(
    "$ROOT/Sources/WhisperApp/Services/AudioRecorderService.swift"
    "$ROOT/Sources/WhisperApp/Services/KeychainCredentialStore.swift"
    "$ROOT/Sources/WhisperApp/Services/OpenAITranscriptionClient.swift"
    "$ROOT/Sources/WhisperApp/Services/SingleInstanceGuard.swift"
    "$ROOT/Sources/WhisperApp/Services/TextInsertionService.swift"
)

swiftc \
    -target arm64-apple-macosx14.0 \
    -swift-version 5 \
    -strict-concurrency=complete \
    -warn-concurrency \
    -warnings-as-errors \
    -parse-as-library \
    -I "$BUILD" \
    -L "$BUILD" \
    -lWhisperCore \
    "${service_sources[@]}" \
    "$ROOT/Tests/Manual/WhisperServicesVerification.swift" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework AVFoundation \
    -framework CoreGraphics \
    -framework Security \
    -o "$BUILD/WhisperServicesVerification"

"$BUILD/WhisperServicesVerification"
