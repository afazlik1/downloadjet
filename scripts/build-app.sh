#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cache_dir="${CURRENT_BUILD_DIR:-$PWD/.build}"
mkdir -p "$cache_dir"
cache_dir="$(cd "$cache_dir" && pwd)"
export CLANG_MODULE_CACHE_PATH="$cache_dir/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir/modules"
args=(--disable-sandbox --cache-path "$cache_dir/cache" --scratch-path "$cache_dir" -Xswiftc -module-cache-path -Xswiftc "$cache_dir/modules")
swift build -c release "${args[@]}"
bin_dir=$(swift build -c release "${args[@]}" --show-bin-path)
app="$PWD/dist/IDM.app"
legacy_app="$PWD/dist/Current.app"
if [[ -d "$legacy_app" && ! -e "$app" ]]; then
    mv "$legacy_app" "$app"
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# Replace the executable by rename so an already-running process keeps its old inode.
cp "$bin_dir/IDM" "$app/Contents/MacOS/.IDM.next"
chmod 755 "$app/Contents/MacOS/.IDM.next"
mv -f "$app/Contents/MacOS/.IDM.next" "$app/Contents/MacOS/IDM"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>IDM</string>
<key>CFBundleIdentifier</key><string>app.current.downloadmanager</string>
<key>CFBundleName</key><string>IDM</string>
<key>CFBundleDisplayName</key><string>IDM</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.2</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>IDMIcon</string>
<key>NSDownloadsFolderUsageDescription</key><string>IDM saves the files you request to your Downloads folder.</string>
</dict></plist>
PLIST
swift -module-cache-path "$cache_dir/modules" scripts/icon.swift "$PWD/assets/AppIcon.png" "$cache_dir/AppIcon.png"
mkdir -p "$cache_dir/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$cache_dir/AppIcon.png" --out "$cache_dir/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$cache_dir/AppIcon.png" --out "$cache_dir/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$cache_dir/AppIcon.iconset" -o "$app/Contents/Resources/IDMIcon.icns"
# Remove obsolete files retained when an older app bundle was renamed.
rm -f "$app/Contents/MacOS/Current" "$app/Contents/Resources/CurrentIcon.icns" "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
rm -f "$PWD/dist/IDM-macOS.zip"
(cd dist && /usr/bin/zip -qr IDM-macOS.zip IDM.app)
rm -f "$PWD/dist/Current-macOS.zip"
printf 'Built %s\n' "$app"
