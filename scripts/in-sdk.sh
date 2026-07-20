#!/bin/sh
set -eu

version=25.12.5
archive=openwrt-sdk-25.12.5-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
sha256=0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image=netwatch-openwrt-sdk:$version
volume="netwatch-openwrt-sdk-$version-x86-64-$sha256"
container="netwatch-openwrt-sdk-$version-x86-64-$sha256"
archive_path=$root/work/downloads/$archive

if [ "$#" -eq 0 ]; then
	echo "usage: $0 COMMAND [ARGUMENTS ...]" >&2
	exit 64
fi

if [ ! -f "$archive_path" ]; then
	echo "error: missing pinned SDK archive: $archive_path" >&2
	echo 'run ./scripts/fetch-sdk.sh first' >&2
	exit 1
fi

docker image inspect "$image" >/dev/null 2>&1 || \
	docker build --platform linux/amd64 -t "$image" "$root/tools/sdk"

exec docker run --rm --name "$container" --platform linux/amd64 \
	--mount "type=bind,src=$root,dst=/src" \
	--mount "type=volume,src=$volume,dst=/sdk" \
	--mount "type=bind,src=$archive_path,dst=/sdk-archive/$archive,readonly" \
	-w /src "$image" sh -eu -c '
	version=$1
	archive=$2
	sha256=$3
	shift 3
	archive_path=/sdk-archive/$archive
	stamp=/sdk/.netwatch-sdk-$version-$sha256
	export_dir=/src/work/sdk/bin/packages

	if [ ! -f "$stamp" ] ||
		[ ! -x /sdk/scripts/feeds ] ||
		[ ! -x /sdk/staging_dir/host/bin/apk ]; then
		printf '\''%s  %s\n'\'' "$sha256" "$archive_path" | sha256sum -c -
		find /sdk -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
		tar --zstd -xf "$archive_path" -C /sdk --strip-components=1

		for executable in \
			/sdk/scripts/feeds \
			/sdk/staging_dir/host/bin/apk
		do
			if [ ! -x "$executable" ]; then
				echo "error: pinned SDK is missing required executable: $executable" >&2
				exit 1
			fi
		done

		: > "$stamp"
	fi

	set +e
	"$@"
	command_status=$?

	mkdir -p "$export_dir"
	sync_status=$?
	if [ "$sync_status" -eq 0 ]; then
		rsync -a --delete /sdk/bin/packages/ "$export_dir/"
		sync_status=$?
	fi
	set -e

	if [ "$command_status" -ne 0 ]; then
		exit "$command_status"
	fi

	exit "$sync_status"
' in-sdk "$version" "$archive" "$sha256" "$@"
