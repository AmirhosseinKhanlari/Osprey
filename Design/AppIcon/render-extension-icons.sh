#!/bin/zsh
# Renders the browser extensions' PNG icons from osprey-icon-default.svg (needs rsvg-convert: brew install librsvg).
# 16 and 32 (the toolbar sizes) are cropped to the tile so they stay legible; 48 and 128 use the full canvas.
# The same files go to the Chrome extension and the Safari extension's resources.
set -euo pipefail
here=${0:A:h}
root=${here:h:h}
source_svg="$here/osprey-icon-default.svg"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The tile alone: the canvas's 100..924 square.
sed -e 's/viewBox="0 0 1024 1024" width="1024" height="1024"/viewBox="100 100 824 824" width="824" height="824"/' \
    "$source_svg" > "$work/tile.svg"
grep -q 'viewBox="100 100 824 824"' "$work/tile.svg"
for size in 16 32 48 128; do
  input="$source_svg"
  (( size <= 32 )) && input="$work/tile.svg"
  rsvg-convert --width "$size" --height "$size" --keep-aspect-ratio --format png --output "$work/icon-$size.png" "$input"
done
for target in "$root/Extensions/chrome/icons" "$root/Extensions/safari/Resources/icons"; do
  mkdir -p "$target"
  cp "$work"/icon-{16,32,48,128}.png "$target/"
  echo "rendered ${target#$root/}/icon-{16,32,48,128}.png"
done
