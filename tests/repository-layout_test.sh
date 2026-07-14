#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for path in \
	packages/netwatch/netwatch/Makefile \
	packages/netwatch/luci-app-netwatch/Makefile
do
	[ -f "$root/$path" ] || {
		echo "missing nested package source: $path" >&2
		exit 1
	}
done

[ ! -e "$root/netwatch" ] || {
	echo 'legacy root package directory remains: netwatch' >&2
	exit 1
}
[ ! -e "$root/luci-app-netwatch" ] || {
	echo 'legacy root package directory remains: luci-app-netwatch' >&2
	exit 1
}

grep -Fq '/src/packages/netwatch/netwatch' "$root/scripts/build-packages.sh"
grep -Fq '/src/packages/netwatch/luci-app-netwatch' "$root/scripts/build-packages.sh"

echo 'repository layout tests passed'
