#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
wrapper_source=${IN_SDK_WRAPPER:-$root/scripts/in-sdk.sh}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/netwatch-in-sdk-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

archive=openwrt-sdk-25.12.5-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
repo=$tmp/repo
export_target=$tmp/shared-sdk
archive_root=$tmp/sdk-archive
fixture=$tmp/sdk-fixture
fakebin=$tmp/fakebin
docker_log=$tmp/docker.args

mkdir -p "$repo/scripts" "$repo/tools/sdk" "$repo/work/downloads" \
	"$export_target" "$archive_root" "$fixture/scripts" \
	"$fixture/staging_dir/host/bin" "$fakebin"
cp "$wrapper_source" "$repo/scripts/in-sdk.sh"
ln -s ../../shared-sdk "$repo/work/sdk"
touch "$repo/work/downloads/$archive" "$archive_root/$archive"
printf '#!/bin/sh\nexit 0\n' > "$fixture/scripts/feeds"
printf '#!/bin/sh\nexit 0\n' > "$fixture/staging_dir/host/bin/apk"
chmod +x "$fixture/scripts/feeds" "$fixture/staging_dir/host/bin/apk"

cat > "$fakebin/docker" <<'SH'
#!/bin/sh
set -eu

if [ "$1" = image ] && [ "$2" = inspect ]; then
	exit 0
fi

if [ "$1" != run ]; then
	echo "unexpected docker command: $*" >&2
	exit 90
fi

printf '%s\n' "$@" > "$FAKE_DOCKER_LOG"
while [ "$#" -gt 0 ] && [ "$1" != sh ]; do
	shift
done
[ "$#" -ge 4 ] && [ "$1" = sh ] && [ "$2" = -eu ] && [ "$3" = -c ]
shift 3
script=$1
shift
translated=$(printf '%s\n' "$script" | sed \
	-e "s|/sdk-archive|$FAKE_ARCHIVE_ROOT|g" \
	-e "s|/sdk-export|$FAKE_EXPORT_ROOT|g" \
	-e "s|/sdk|$FAKE_SDK_ROOT|g")
exec sh -eu -c "$translated" "$@"
SH

cat > "$fakebin/sha256sum" <<'SH'
#!/bin/sh
set -eu
[ "$1" = -c ] && [ "$2" = - ]
cat >/dev/null
exit 0
SH

cat > "$fakebin/tar" <<'SH'
#!/bin/sh
set -eu
destination=
while [ "$#" -gt 0 ]; do
	if [ "$1" = -C ]; then
		destination=$2
		shift 2
	else
		shift
	fi
done
[ -n "$destination" ]
cp -R "$FAKE_SDK_FIXTURE"/. "$destination"/
SH

cat > "$fakebin/rsync" <<'SH'
#!/bin/sh
set -eu
status=${FAKE_RSYNC_STATUS:-0}
if [ "$status" -ne 0 ]; then
	exit "$status"
fi
[ "$1" = -a ] && [ "$2" = --delete ]
source=$3
destination=$4
mkdir -p "$destination"
find "$destination" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -R "$source"/. "$destination"/
SH

chmod +x "$fakebin/docker" "$fakebin/sha256sum" "$fakebin/tar" "$fakebin/rsync"
canonical_export=$(CDPATH= cd -- "$export_target" && pwd -P)

run_wrapper() {
	env \
		PATH="$fakebin:$PATH" \
		FAKE_DOCKER_LOG="$docker_log" \
		FAKE_ARCHIVE_ROOT="$archive_root" \
		FAKE_EXPORT_ROOT="$canonical_export" \
		FAKE_SDK_ROOT="$tmp/sdk-volume" \
		FAKE_SDK_FIXTURE="$fixture" \
		FAKE_RSYNC_STATUS="${FAKE_RSYNC_STATUS:-0}" \
		"$repo/scripts/in-sdk.sh" "$@"
}

mkdir -p "$tmp/sdk-volume"
run_wrapper true

if ! grep -Fxq -- "type=bind,src=$canonical_export,dst=/sdk-export" "$docker_log"; then
	echo 'in-sdk behavior: linked work/sdk target was not mounted canonically at /sdk-export' >&2
	exit 1
fi
if grep -Fq -- '/src/work/sdk' "$docker_log"; then
	echo 'in-sdk behavior: export must not be routed through the /src worktree mount' >&2
	exit 1
fi
if grep -Eq -- '^type=bind,.*dst=/sdk$' "$docker_log"; then
	echo 'in-sdk behavior: a host directory was bind-mounted at /sdk' >&2
	exit 1
fi
if ! grep -Eq -- '^type=volume,.*dst=/sdk$' "$docker_log"; then
	echo 'in-sdk behavior: /sdk is not backed by a named volume' >&2
	exit 1
fi
if [ ! -d "$tmp/sdk-volume/bin/packages" ] ||
	[ ! -d "$canonical_export/bin/packages" ] ||
	find "$canonical_export/bin/packages" -mindepth 1 -print -quit | grep -q .; then
	echo 'in-sdk behavior: fresh SDK empty package export was not mirrored successfully' >&2
	exit 1
fi

set +e
FAKE_RSYNC_STATUS=41 run_wrapper sh -c 'exit 23'
child_status=$?
set -e
if [ "$child_status" -ne 23 ]; then
	echo "in-sdk behavior: child status 23 was returned as $child_status" >&2
	exit 1
fi

set +e
FAKE_RSYNC_STATUS=41 run_wrapper true
sync_status=$?
set -e
if [ "$sync_status" -ne 41 ]; then
	echo "in-sdk behavior: sync status 41 was returned as $sync_status" >&2
	exit 1
fi

fetch_repo=$tmp/fetch-repo
fetch_fakebin=$tmp/fetch-fakebin
mkdir -p "$fetch_repo/scripts" "$fetch_repo/work/downloads" \
	"$fetch_repo/work/sdk/bin/packages" "$fetch_fakebin"
cp "$root/scripts/fetch-sdk.sh" "$fetch_repo/scripts/fetch-sdk.sh"
touch "$fetch_repo/work/downloads/$archive"
printf 'preserve me\n' > "$fetch_repo/work/sdk/bin/packages/sentinel"

cat > "$fetch_fakebin/shasum" <<'SH'
#!/bin/sh
set -eu
[ "$1" = -a ] && [ "$2" = 256 ] && [ "$3" = -c ] && [ "$4" = - ]
cat >/dev/null
exit 0
SH
cat > "$fetch_fakebin/tar" <<'SH'
#!/bin/sh
echo 'fetch-sdk must not extract the archive on the host' >&2
exit 91
SH
chmod +x "$fetch_fakebin/shasum" "$fetch_fakebin/tar"

PATH="$fetch_fakebin:$PATH" "$fetch_repo/scripts/fetch-sdk.sh"
if [ ! -f "$fetch_repo/work/sdk/bin/packages/sentinel" ]; then
	echo 'fetch-sdk behavior: existing host package exports were removed' >&2
	exit 1
fi

echo 'in-sdk behavior tests passed'
