#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/netwatch-package-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

mkdir -p "$tmp/scripts" "$tmp/work/sdk/bin/packages/base"
cp "$root/scripts/package-output.sh" "$tmp/scripts/package-output.sh"
cp "$root/README.md" "$tmp/README.md"
printf 'runtime apk fixture\n' > "$tmp/work/sdk/bin/packages/base/netwatch-1.1.0-r1.apk"
printf 'luci apk fixture\n' > "$tmp/work/sdk/bin/packages/base/luci-app-netwatch-1.1.0-r1.apk"
printf 'scheduled backup apk fixture\n' > \
	"$tmp/work/sdk/bin/packages/base/luci-app-scheduled-backup-1.0.0-r3.apk"

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
git --git-dir="$tmp/work/git-metadata" --work-tree="$tmp" \
	config tar.umask 0002
(
	cd "$tmp"
	./scripts/package-output.sh >/dev/null
)

archive=$tmp/outputs/openwrt-netwatch-1.1.0-source.tar.gz
for artifact in \
	netwatch_1.1.0-r1_all.apk \
	luci-app-netwatch_1.1.0-r1_all.apk \
	luci-app-scheduled-backup_1.0.0-r3_all.apk \
	openwrt-netwatch-1.1.0-source.tar.gz \
	SHA256SUMS
do
	if [ ! -f "$tmp/outputs/$artifact" ]; then
		echo "missing stable output artifact: $artifact" >&2
		exit 1
	fi
done

for artifact in \
	netwatch_1.1.0-r1_all.apk \
	luci-app-netwatch_1.1.0-r1_all.apk \
	luci-app-scheduled-backup_1.0.0-r3_all.apk \
	openwrt-netwatch-1.1.0-source.tar.gz
do
	grep -Fq "  outputs/$artifact" "$tmp/outputs/SHA256SUMS" || {
		echo "checksum manifest omits artifact: $artifact" >&2
		exit 1
	}
done

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
git --git-dir="$tmp/work/git-metadata" --work-tree="$tmp" \
	config tar.umask 0077
(
	cd "$tmp"
	umask 0077
	./scripts/package-output.sh >/dev/null
)
second_hash=$(shasum -a 256 "$archive" | awk '{ print $1 }')
if [ "$first_hash" != "$second_hash" ]; then
	echo 'source archive changes with working-tree mtimes or host umask' >&2
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
