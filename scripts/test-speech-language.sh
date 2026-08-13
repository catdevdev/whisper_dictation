#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build/manual/speech-language"

mkdir -p "$BUILD"

swiftc \
    -target arm64-apple-macosx14.0 \
    -swift-version 5 \
    -strict-concurrency=complete \
    -warn-concurrency \
    -warnings-as-errors \
    -parse-as-library \
    "$ROOT/Sources/WhisperApp/Services/QwenTTSModels.swift" \
    "$ROOT/Sources/WhisperApp/Services/SpeechLanguageResolver.swift" \
    "$ROOT/Tests/Manual/SpeechLanguageResolverVerification.swift" \
    -framework NaturalLanguage \
    -o "$BUILD/SpeechLanguageResolverVerification"

"$BUILD/SpeechLanguageResolverVerification"
