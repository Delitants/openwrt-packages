#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ "$#" -ne 1 ] || [ ! -f "$root/$1" ]; then
	echo "usage: $0 tests/unit/<test>.uc" >&2
	exit 2
fi

exec "$root/scripts/in-sdk.sh" \
	ucode \
	-L /src/tests/lib \
	-L /src/netwatch/files/usr/share/netwatch \
	"/src/$1"
