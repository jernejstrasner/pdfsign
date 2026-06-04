#!/usr/bin/env bash
# Render AppIcon.svg into the app's asset catalog at every size macOS needs.
# Rendering each size straight from the vector (rsvg-convert) keeps small
# sizes crisp instead of downscaling one master bitmap.
set -euo pipefail

cd "$(dirname "$0")"
SVG="AppIcon.svg"
OUT="../PDFSign/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$OUT"

for px in 16 32 64 128 256 512 1024; do
  rsvg-convert -w "$px" -h "$px" "$SVG" -o "$OUT/icon_${px}.png"
done

echo "Wrote icons to $OUT"
