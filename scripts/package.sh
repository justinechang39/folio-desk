#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
app='dist-release/Folio Desk.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
arch=$(uname -m)
python3 scripts/collect-licenses.py
xcrun swiftc -O -swift-version 5 -target "$arch-apple-macosx13.3" \
  -emit-library -module-name FolioNative \
  -Xlinker -install_name -Xlinker '@rpath/libFolioNative.dylib' \
  -framework AppKit -framework PDFKit native/*.swift \
  -o "$app/Contents/Frameworks/libFolioNative.dylib"
FOLIO_NATIVE_LIB_DIR="$PWD/$app/Contents/Frameworks" MACOSX_DEPLOYMENT_TARGET=13.3 cargo build --release --features native-ui
cp target/release/folio-desk "$app/Contents/MacOS/folio-desk"
cp assets/icon.icns LICENSE THIRD_PARTY_NOTICES.md licenses/ThirdPartyLicenses.txt "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.justinechang39.foliodesk</string>
<key>CFBundleName</key><string>Folio Desk</string>
<key>CFBundleDisplayName</key><string>Folio Desk</string>
<key>CFBundleExecutable</key><string>folio-desk</string>
<key>CFBundleIconFile</key><string>icon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Justine Chang. MIT licensed.</string>
<key>LSMinimumSystemVersion</key><string>13.3</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>PDF document</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/libFolioNative.dylib"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
zip="Folio-Desk-macOS-${arch}.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "dist-release/$zip"
(cd dist-release && shasum -a 256 "$zip" > SHA256SUMS)
printf 'Built %s\n' "$app"
