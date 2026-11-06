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
"$bin_dir/DownloadCoreChecks" "$@"
if [[ "$#" -eq 0 ]]; then
    check_dir="$cache_dir/store-checks"
    mkdir -p "$check_dir"
    compiler_args=(-swift-version 5 -target "$(uname -m)-apple-macosx14.0" -O -module-cache-path "$cache_dir/modules")
    # Build a self-contained module rather than depend on SwiftPM/Xcode cache layout.
    swiftc "${compiler_args[@]}" -parse-as-library -whole-module-optimization \
        -emit-module -emit-object -module-name DownloadCore Sources/DownloadCore/*.swift \
        -emit-module-path "$check_dir/DownloadCore.swiftmodule" -o "$check_dir/DownloadCore.o"
    swiftc "${compiler_args[@]}" -I "$check_dir" \
        Sources/DownloadJet/Store.swift Tests/DownloadStoreChecks/DownloadStoreChecks.swift \
        "$check_dir/DownloadCore.o" -o "$check_dir/DownloadStoreChecks"
    "$check_dir/DownloadStoreChecks"
fi
