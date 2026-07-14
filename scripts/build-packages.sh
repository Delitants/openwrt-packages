#!/bin/sh
set -eu

cd /sdk

if [ ! -x ./scripts/feeds ]; then
	echo 'error: this script must run in a complete OpenWrt SDK at /sdk' >&2
	exit 1
fi

for source_dir in \
	/src/packages/netwatch/netwatch \
	/src/packages/netwatch/luci-app-netwatch
do
	if [ ! -f "$source_dir/Makefile" ]; then
		echo "error: missing package source: $source_dir" >&2
		exit 1
	fi
done

feed_dir=/sdk/package/netwatch-feed
case "$feed_dir" in
	/sdk/package/netwatch-feed) ;;
	*)
		echo "error: refusing to replace unexpected path: $feed_dir" >&2
		exit 1
		;;
esac

rm -rf "$feed_dir"
mkdir -p "$feed_dir"
ln -s /src/packages/netwatch/netwatch "$feed_dir/netwatch"
ln -s /src/packages/netwatch/luci-app-netwatch "$feed_dir/luci-app-netwatch"

./scripts/feeds update -a
./scripts/feeds install -a

config_tmp=/sdk/.config.netwatch.$$
trap 'rm -f "$config_tmp"' EXIT HUP INT TERM
: > "$config_tmp"
printf '%s\n' \
	'# CONFIG_ALL is not set' \
	'# CONFIG_ALL_KMODS is not set' \
	'# CONFIG_ALL_NONSHARED is not set' \
	'CONFIG_PACKAGE_netwatch=y' \
	'CONFIG_PACKAGE_luci-app-netwatch=y' >> "$config_tmp"
mv "$config_tmp" .config
make defconfig

for check_target in package/netwatch/check package/luci-app-netwatch/check; do
	if make -n "$check_target" V=s -j1 >/dev/null 2>&1; then
		make "$check_target" V=s -j1
	else
		printf 'skipping unsupported SDK target: %s\n' "$check_target"
	fi
done
make package/netwatch/clean package/luci-app-netwatch/clean
find /sdk/bin/packages -type f \
	\( -name 'netwatch-*.apk' -o -name 'luci-app-netwatch-*.apk' \) \
	-delete 2>/dev/null || true
make package/netwatch/compile package/luci-app-netwatch/compile V=s -j1

assert_one_apk() {
	label=$1
	pattern=$2
	matches=$(find /sdk/bin/packages -type f -name "$pattern" -print 2>/dev/null || true)
	count=$(printf '%s\n' "$matches" | awk 'NF { count++ } END { print count + 0 }')

	if [ "$count" -ne 1 ]; then
		echo "error: expected exactly one $label APK matching $pattern, found $count" >&2
		if [ -n "$matches" ]; then
			printf '%s\n' "$matches" >&2
		fi
		exit 1
	fi

	printf 'built %s APK: %s\n' "$label" "$matches"
}

# The runtime basename starts with exactly "netwatch-", so the LuCI package
# can never satisfy the runtime assertion.
assert_one_apk runtime 'netwatch-*.apk'
assert_one_apk LuCI 'luci-app-netwatch-*.apk'
