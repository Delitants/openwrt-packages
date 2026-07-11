#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail=0

require_file() {
	if [ ! -f "$root/$1" ]; then
		echo "missing: $1" >&2
		fail=1
	fi
}

require_file netwatch/Makefile
require_file netwatch/files/etc/config/netwatch
require_file netwatch/files/etc/init.d/netwatch
require_file luci-app-netwatch/Makefile
require_file tools/sdk/Dockerfile
require_file scripts/fetch-sdk.sh
require_file scripts/in-sdk.sh

exit "$fail"
