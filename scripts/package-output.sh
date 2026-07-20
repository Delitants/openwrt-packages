#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
package_dir=$root/work/sdk/bin/packages
output_dir=$root/outputs
git_dir=$root/work/git-metadata
tmp=$(mktemp -d "${TMPDIR:-/tmp}/netwatch-package-output.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

git_repo() {
	git --git-dir="$git_dir" --work-tree="$root" "$@"
}

if ! git_repo rev-parse --verify HEAD >/dev/null 2>&1; then
	echo "error: source Git metadata is unavailable at $git_dir" >&2
	exit 1
fi

if ! git_repo diff --quiet -- || ! git_repo diff --cached --quiet --; then
	echo 'error: refusing to package a source tree with tracked changes' >&2
	exit 1
fi

find_one_apk() {
	label=$1
	pattern=$2
	matches=$(find "$package_dir" -type f -name "$pattern" -print 2>/dev/null || true)
	count=$(printf '%s\n' "$matches" | awk 'NF { count++ } END { print count + 0 }')

	if [ "$count" -ne 1 ]; then
		echo "error: expected exactly one $label APK matching $pattern, found $count" >&2
		if [ -n "$matches" ]; then
			printf '%s\n' "$matches" >&2
		fi
		exit 1
	fi

	printf '%s\n' "$matches"
}

runtime_apk=$(find_one_apk runtime 'netwatch-1.1.0-r1.apk')
luci_apk=$(find_one_apk LuCI 'luci-app-netwatch-1.1.0-r1.apk')

mkdir -p "$output_dir"
runtime_output=$output_dir/netwatch_1.1.0-r1_all.apk
luci_output=$output_dir/luci-app-netwatch_1.1.0-r1_all.apk
source_output=$output_dir/openwrt-netwatch-1.1.0-source.tar.gz
checksums=$output_dir/SHA256SUMS
rm -f "$runtime_output" "$luci_output" "$source_output" "$checksums"
cp "$runtime_apk" "$runtime_output"
cp "$luci_apk" "$luci_output"

source_name=openwrt-netwatch-1.1.0
archive=$tmp/$source_name.tar
git_repo -c tar.umask=0022 archive \
	--format=tar --prefix="$source_name/" HEAD > "$archive"
gzip -n -f "$archive"
mv "$archive.gz" "$source_output"

(
	cd "$root"
	shasum -a 256 \
		outputs/netwatch_1.1.0-r1_all.apk \
		outputs/luci-app-netwatch_1.1.0-r1_all.apk \
		outputs/openwrt-netwatch-1.1.0-source.tar.gz \
		> outputs/SHA256SUMS
)

printf 'packaged artifacts in %s\n' "$output_dir"
