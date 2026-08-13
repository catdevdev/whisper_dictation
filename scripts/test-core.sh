#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build/manual"

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
    "$ROOT/Tests/Manual/WhisperCoreVerification.swift" \
    -o "$BUILD/WhisperCoreVerification"

"$BUILD/WhisperCoreVerification"
