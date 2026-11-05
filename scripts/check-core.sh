#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cache_dir="${DOWNLOADJET_BUILD_DIR:-$PWD/.build}"
mkdir -p "$cache_dir"
cache_dir="$(cd "$cache_dir" && pwd)"
export CLANG_MODULE_CACHE_PATH="$cache_dir/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir/modules"
args=(--disable-sandbox --cache-path "$cache_dir/cache" --scratch-path "$cache_dir" -Xswiftc -module-cache-path -Xswiftc "$cache_dir/modules")
swift build -c release --product DownloadCoreChecks "${args[@]}" >&2
bin_dir=$(swift build -c release "${args[@]}" --show-bin-path)
exec "$bin_dir/DownloadCoreChecks" "$@"
