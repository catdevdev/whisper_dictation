#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build/manual/app-state"

mkdir -p "$BUILD"

swiftc \
    -target arm64-apple-macosx14.0 \
    -swift-version 5 \
    -strict-concurrency=complete \
    -warn-concurrency \
    -warnings-as-errors \
    -parse-as-library \
    "$ROOT/Sources/WhisperApp/Application/AppState.swift" \
    "$ROOT/Tests/Manual/WhisperAppStateVerification.swift" \
    -o "$BUILD/WhisperAppStateVerification"

"$BUILD/WhisperAppStateVerification"
