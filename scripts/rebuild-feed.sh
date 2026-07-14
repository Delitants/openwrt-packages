#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
arch=${1:-}
key_arg=${2:-}

[ -n "$arch" ] || {
	echo "usage: $0 ARCH PRIVATE_KEY" >&2
	exit 2
}
[ -n "$key_arg" ] || {
	echo "usage: $0 ARCH PRIVATE_KEY" >&2
	exit 2
}

case "$key_arg" in
	"$root"/*) key_rel=${key_arg#"$root"/} ;;
	/*)
		echo 'error: private key must be inside the repository working tree' >&2
		exit 2
		;;
	*) key_rel=$key_arg ;;
esac

case "/$key_rel/" in
	*/../*|*/./*)
		echo 'error: private key path must not contain dot segments' >&2
		exit 2
		;;
esac

[ -f "$root/$key_rel" ] || {
	echo "error: private key not found: $key_rel" >&2
	exit 2
}

feed_dir=$root/feed/$arch
[ -d "$feed_dir" ] || {
	echo "error: feed directory not found: feed/$arch" >&2
	exit 2
}

set -- "$feed_dir"/*.apk
[ "$1" != "$feed_dir/*.apk" ] || {
	echo "error: no APK files in feed/$arch" >&2
	exit 2
}

container_feed=/src/feed/$arch
container_key=/src/$key_rel

"$root/scripts/in-sdk.sh" sh -eu -c '
	apk=/sdk/staging_dir/host/bin/apk
	feed_dir=$1
	key=$2
	keys=/src/keys
	tmp=$feed_dir/packages.adb.tmp
	trap "rm -f \"$tmp\"" EXIT HUP INT TERM

	set -- "$feed_dir"/*.apk
	for package do
		"$apk" verify --keys-dir "$keys" "$package"
	done

	"$apk" --allow-untrusted mkndx \
		--description "Delitants OpenWrt package feed" \
		--sign-key "$key" \
		--output "$tmp" \
		"$@"
	"$apk" verify --keys-dir "$keys" "$tmp"
	"$apk" adbdump --format json "$tmp" >/dev/null
	mv "$tmp" "$feed_dir/packages.adb"
	trap - EXIT HUP INT TERM
' sh "$container_feed" "$container_key"

echo "rebuilt and verified feed/$arch/packages.adb"
