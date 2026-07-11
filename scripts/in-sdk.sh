#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
docker image inspect netwatch-openwrt-sdk:25.12.5 >/dev/null 2>&1 || \
	docker build --platform linux/amd64 -t netwatch-openwrt-sdk:25.12.5 "$root/tools/sdk"
exec docker run --rm --platform linux/amd64 \
	-v "$root:/src" -v "$root/work/sdk:/sdk" \
	-w /src netwatch-openwrt-sdk:25.12.5 "$@"
