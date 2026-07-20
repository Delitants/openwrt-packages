#!/bin/sh
set -eu
version=25.12.5
archive=openwrt-sdk-25.12.5-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
sha256=0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c
url=https://downloads.openwrt.org/releases/$version/targets/x86/64/$archive
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$root/work/downloads" "$root/work/sdk/bin/packages"
test -f "$root/work/downloads/$archive" || curl -fL "$url" -o "$root/work/downloads/$archive"
printf '%s  %s\n' "$sha256" "$root/work/downloads/$archive" | shasum -a 256 -c -
