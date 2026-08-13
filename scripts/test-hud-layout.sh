#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build/manual/hud-layout"

mkdir -p "$BUILD"

swiftc \
    -target arm64-apple-macosx14.0 \
    -swift-version 5 \
    -strict-concurrency=complete \
    -warn-concurrency \
    -warnings-as-errors \
    -parse-as-library \
    "$ROOT/Sources/WhisperApp/UI/HUD/HUDLayout.swift" \
    "$ROOT/Tests/Manual/WhisperHUDLayoutVerification.swift" \
    -framework CoreGraphics \
    -o "$BUILD/WhisperHUDLayoutVerification"

"$BUILD/WhisperHUDLayoutVerification"
