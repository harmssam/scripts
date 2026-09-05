#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_png="$project_dir/Assets/AppIcon.png"
iconset_dir="$project_dir/.build/AppIcon.iconset"
output_icns="$project_dir/Assets/AppIcon.icns"

[[ -f "$source_png" ]] || {
    echo "Missing icon source: $source_png" >&2
    exit 1
}

rm -rf -- "$iconset_dir"
mkdir -p "$iconset_dir"

make_icon() {
    local pixels="$1"
    local filename="$2"
    sips -z "$pixels" "$pixels" "$source_png" --out "$iconset_dir/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

iconutil -c icns "$iconset_dir" -o "$output_icns"
echo "Generated $output_icns"
