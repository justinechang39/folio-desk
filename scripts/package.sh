#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
npm run tauri -- build --bundles app
app='src-tauri/target/release/bundle/macos/Folio Desk.app'
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
mkdir -p dist-release
arch=$(uname -m)
zip="Folio-Desk-macOS-${arch}.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "dist-release/$zip"
(cd dist-release && shasum -a 256 "$zip" > SHA256SUMS)
echo "Created dist-release/$zip"
