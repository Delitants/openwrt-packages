#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
package_dir=$root/work/sdk/bin/packages
output_dir=$root/outputs
tmp=$(mktemp -d "${TMPDIR:-/tmp}/netwatch-package-output.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

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

runtime_apk=$(find_one_apk runtime 'netwatch-1.0.0-r1.apk')
luci_apk=$(find_one_apk LuCI 'luci-app-netwatch-1.0.0-r1.apk')

mkdir -p "$output_dir"
runtime_output=$output_dir/netwatch_1.0.0-r1_all.apk
luci_output=$output_dir/luci-app-netwatch_1.0.0-r1_all.apk
source_output=$output_dir/openwrt-netwatch-1.0.0-source.tar.gz
checksums=$output_dir/SHA256SUMS
rm -f "$runtime_output" "$luci_output" "$source_output" "$checksums"
cp "$runtime_apk" "$runtime_output"
cp "$luci_apk" "$luci_output"

source_name=openwrt-netwatch-1.0.0
source_tree=$tmp/$source_name
source_list=$tmp/source-files
tar_list=$tmp/tar-files
archive=$tmp/$source_name.tar
mkdir -p "$source_tree"

(
	cd "$root"
	find . \
		\( -path './.git' -o -path './.superpowers' -o -path './work' -o -path './outputs' \) -prune -o \
		\( -type f -o -type l \) -print
) | sed 's#^\./##' | LC_ALL=C sort > "$source_list"

while IFS= read -r path; do
	[ -n "$path" ] || continue
	mkdir -p "$source_tree/$(dirname -- "$path")"
	cp -pP "$root/$path" "$source_tree/$path"
done < "$source_list"

# Give generated directory entries a stable timestamp tied to a source file.
find "$source_tree" -type d -exec touch -r "$root/README.md" {} \;
(
	cd "$tmp"
	find "$source_name" -print | LC_ALL=C sort > "$tar_list"
	COPYFILE_DISABLE=1 tar --no-recursion -cf "$archive" -T "$tar_list"
)
gzip -n -f "$archive"
mv "$archive.gz" "$source_output"

(
	cd "$root"
	shasum -a 256 \
		outputs/netwatch_1.0.0-r1_all.apk \
		outputs/luci-app-netwatch_1.0.0-r1_all.apk \
		outputs/openwrt-netwatch-1.0.0-source.tar.gz \
		> outputs/SHA256SUMS
)

printf 'packaged artifacts in %s\n' "$output_dir"
