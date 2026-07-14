#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ "$#" -lt 1 ]; then
	echo "usage: $0 tests/unit/<test>.uc [...]" >&2
	exit 2
fi

for test_file in "$@"; do
	if [ ! -f "$root/$test_file" ]; then
		echo "error: test file not found: $test_file" >&2
		exit 2
	fi
done

for test_file in "$@"; do
	"$root/scripts/in-sdk.sh" \
		ucode \
		-L /src/tests/lib \
		-L /src/packages/netwatch/netwatch/files/usr/share/netwatch \
		"/src/$test_file"
done
