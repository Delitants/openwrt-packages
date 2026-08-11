#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
archive=${1:-$root/outputs/openwrt-netwatch-1.1.0-source.tar.gz}
git_dir=$root/work/git-metadata
archive_name=${archive##*/}
case "$archive_name" in
	*-source.tar.gz) ;;
	*)
		echo "error: unexpected source archive name: $archive_name" >&2
		exit 1
		;;
esac
source_name=${archive_name%-source.tar.gz}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/netwatch-source-archive.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

git_repo() {
	git --git-dir="$git_dir" --work-tree="$root" "$@"
}

[ -f "$archive" ] || {
	echo "error: missing source archive: $archive" >&2
	exit 1
}
git_repo rev-parse --verify HEAD >/dev/null 2>&1 || {
	echo "error: source Git metadata is unavailable at $git_dir" >&2
	exit 1
}

git_repo ls-tree -r --name-only HEAD feed/x86_64 |
	grep -E '^feed/x86_64/netwatch-[^/]+[.]apk$' > "$tmp/runtime-feed" || true
git_repo ls-tree -r --name-only HEAD feed/x86_64 |
	grep -E '^feed/x86_64/luci-app-netwatch-[^/]+[.]apk$' > "$tmp/luci-feed" || true

for kind in runtime luci; do
	count=$(awk 'END { print NR + 0 }' "$tmp/$kind-feed")
	if [ "$count" -ne 1 ]; then
		echo "error: committed HEAD must contain exactly one $kind Netwatch feed APK, found $count" >&2
		exit 1
	fi
done

tar -tzf "$archive" > "$tmp/archive-files"
for expected in $(cat "$tmp/runtime-feed" "$tmp/luci-feed"); do
	prefixed=$source_name/$expected
	grep -Fxq "$prefixed" "$tmp/archive-files" || {
		echo "error: source archive is missing committed feed APK: $expected" >&2
		exit 1
	}
done

grep -E "^$source_name/feed/x86_64/(netwatch|luci-app-netwatch)-[^/]+[.]apk$" \
	"$tmp/archive-files" | sed "s#^$source_name/##" | LC_ALL=C sort \
	> "$tmp/archive-netwatch-feed"
cat "$tmp/runtime-feed" "$tmp/luci-feed" | LC_ALL=C sort \
	> "$tmp/expected-netwatch-feed"
if ! cmp -s "$tmp/expected-netwatch-feed" "$tmp/archive-netwatch-feed"; then
	echo 'error: source archive contains stale or unexpected Netwatch feed APKs' >&2
	diff -u "$tmp/expected-netwatch-feed" "$tmp/archive-netwatch-feed" >&2 || true
	exit 1
fi

expected=$tmp/$source_name.tar
git_repo -c tar.umask=0022 archive \
	--format=tar --prefix="$source_name/" HEAD > "$expected"
gzip -n -f "$expected"
if ! cmp -s "$expected.gz" "$archive"; then
	echo 'error: source archive does not exactly match the committed release HEAD' >&2
	exit 1
fi

echo 'source archive matches committed release HEAD and exact Netwatch feed APKs'
