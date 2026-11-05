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
app="$PWD/dist/Current.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# Replace the executable by rename so an already-running process keeps its old inode.
cp "$bin_dir/Current" "$app/Contents/MacOS/.Current.next"
chmod 755 "$app/Contents/MacOS/.Current.next"
mv -f "$app/Contents/MacOS/.Current.next" "$app/Contents/MacOS/Current"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Current</string>
<key>CFBundleIdentifier</key><string>app.current.downloadmanager</string>
<key>CFBundleName</key><string>Current</string>
<key>CFBundleDisplayName</key><string>Current</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>CurrentIcon</string>
<key>NSDownloadsFolderUsageDescription</key><string>Current saves the files you request to your Downloads folder.</string>
</dict></plist>
PLIST
swift -module-cache-path "$cache_dir/modules" scripts/icon.swift "$PWD/assets/AppIcon.png" "$cache_dir/AppIcon.png"
mkdir -p "$cache_dir/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$cache_dir/AppIcon.png" --out "$cache_dir/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$cache_dir/AppIcon.png" --out "$cache_dir/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$cache_dir/AppIcon.iconset" -o "$app/Contents/Resources/CurrentIcon.icns"
codesign --force --sign - "$app"
(cd dist && /usr/bin/zip -qr Current-macOS.zip Current.app)
printf 'Built %s\n' "$app"
