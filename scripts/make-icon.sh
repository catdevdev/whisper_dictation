#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 source.png" >&2
    exit 64
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$1"
ICONSET="$ROOT/.build/AppIcon.iconset"
OUTPUT="$ROOT/Resources/AppIcon.icns"

mkdir -p "$ROOT/Resources" "$ROOT/.build"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
cp "$SOURCE" "$ROOT/Resources/AppIcon.png"

for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "$OUTPUT"
