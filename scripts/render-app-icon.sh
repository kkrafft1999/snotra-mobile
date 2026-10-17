#!/bin/sh
# Renders design/app-icon.svg into the asset catalog as the 1024 x 1024 app
# icon. App Store Connect rejects an icon with an alpha channel, so the PNG is
# flattened to RGB. Needs rsvg-convert (brew install librsvg).
set -eu
cd "$(dirname "$0")/.."
out=SnotraMobile/Assets.xcassets/AppIcon.appiconset/AppIcon.png
rsvg-convert -w 1024 -h 1024 -b '#00658A' design/app-icon.svg -o "$out.tmp.png"
sips -s format jpeg -s formatOptions 100 "$out.tmp.png" --out "$out.tmp.jpg" >/dev/null
sips -s format png "$out.tmp.jpg" --out "$out" >/dev/null
rm "$out.tmp.png" "$out.tmp.jpg"
sips -g pixelWidth -g pixelHeight -g hasAlpha "$out"
