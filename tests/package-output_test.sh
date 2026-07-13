#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/netwatch-package-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

mkdir -p "$tmp/scripts" "$tmp/work/sdk/bin/packages/base"
cp "$root/scripts/package-output.sh" "$tmp/scripts/package-output.sh"
cp "$root/README.md" "$tmp/README.md"
printf 'runtime apk fixture\n' > "$tmp/work/sdk/bin/packages/base/netwatch-1.0.0-r1.apk"
printf 'luci apk fixture\n' > "$tmp/work/sdk/bin/packages/base/luci-app-netwatch-1.0.0-r1.apk"

git --git-dir="$tmp/work/git-metadata" --work-tree="$tmp" init -q
git --git-dir="$tmp/work/git-metadata" --work-tree="$tmp" \
	config user.name 'Netwatch Tests'
git --git-dir="$tmp/work/git-metadata" --work-tree="$tmp" \
	config user.email 'netwatch-tests@example.invalid'
git --git-dir="$tmp/work/git-metadata" --work-tree="$tmp" \
	add README.md scripts/package-output.sh
git --git-dir="$tmp/work/git-metadata" --work-tree="$tmp" \
	commit -q -m 'fixture source'

printf 'must not be released\n' > "$tmp/local-only.secret"
(
	cd "$tmp"
	./scripts/package-output.sh >/dev/null
)

archive=$tmp/outputs/openwrt-netwatch-1.0.0-source.tar.gz
if tar -tzf "$archive" | grep -Fq 'local-only.secret'; then
	echo 'source archive includes an untracked local file' >&2
	exit 1
fi

duplicates=$(tar -tzf "$archive" | LC_ALL=C sort | uniq -d)
if [ -n "$duplicates" ]; then
	echo 'source archive contains duplicate paths' >&2
	printf '%s\n' "$duplicates" >&2
	exit 1
fi

first_hash=$(shasum -a 256 "$archive" | awk '{ print $1 }')
touch "$tmp/README.md" "$tmp/scripts/package-output.sh"
(
	cd "$tmp"
	./scripts/package-output.sh >/dev/null
)
second_hash=$(shasum -a 256 "$archive" | awk '{ print $1 }')
if [ "$first_hash" != "$second_hash" ]; then
	echo 'source archive changes with working-tree mtimes' >&2
	exit 1
fi

printf '\ntracked modification\n' >> "$tmp/README.md"
if (
	cd "$tmp"
	./scripts/package-output.sh >/dev/null 2>&1
); then
	echo 'packaging succeeds with tracked source changes' >&2
	exit 1
fi

echo 'package output tests passed'
