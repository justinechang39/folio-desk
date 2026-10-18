#!/bin/sh
# Independent experiment: never replaces Folio Desk or reads/writes its session.
set -eu
cd "$(dirname "$0")/.."
app='dist-release/Folio Native Preview.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
arch=$(uname -m)
xcrun swiftc -O -swift-version 5 -target "$arch-apple-macosx13.3" \
  -emit-library -module-name FolioNative \
  -Xlinker -install_name -Xlinker '@rpath/libFolioNative.dylib' \
  -framework AppKit -framework PDFKit native-preview/Viewer.swift \
  -o "$app/Contents/Frameworks/libFolioNative.dylib"
MACOSX_DEPLOYMENT_TARGET=13.3 rustc --edition 2021 -O native-preview/launcher.rs \
  -L "native=$app/Contents/Frameworks" -l dylib=FolioNative \
  -C 'link-arg=-Wl,-rpath,@executable_path/../Frameworks' \
  -o "$app/Contents/MacOS/folio-native-preview"
cp src-tauri/icons/icon.icns "$app/Contents/Resources/icon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.justinechang39.foliodesk.nativepreview</string>
<key>CFBundleName</key><string>Folio Native Preview</string>
<key>CFBundleDisplayName</key><string>Folio Native Preview</string>
<key>CFBundleExecutable</key><string>folio-native-preview</string>
<key>CFBundleIconFile</key><string>icon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.3</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/libFolioNative.dylib"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"
