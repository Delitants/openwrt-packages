#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
wrapper=$root/scripts/in-sdk.sh
fetcher=$root/scripts/fetch-sdk.sh
fail=0

require_literal() {
	literal=$1
	message=$2
	if ! grep -Fq -- "$literal" "$wrapper"; then
		echo "in-sdk wrapper: $message" >&2
		fail=1
	fi
}

fetch_version=$(sed -n 's/^version=//p' "$fetcher")
fetch_archive=$(sed -n 's/^archive=//p' "$fetcher")
fetch_sha256=$(sed -n 's/^sha256=//p' "$fetcher")
wrapper_version=$(sed -n 's/^version=//p' "$wrapper")
wrapper_archive=$(sed -n 's/^archive=//p' "$wrapper")
wrapper_sha256=$(sed -n 's/^sha256=//p' "$wrapper")

if [ "$wrapper_version" != "$fetch_version" ] ||
	[ "$wrapper_archive" != "$fetch_archive" ] ||
	[ "$wrapper_sha256" != "$fetch_sha256" ]; then
	echo 'in-sdk wrapper: SDK version, archive, and SHA must exactly match fetch-sdk.sh' >&2
	fail=1
fi

require_literal 'volume="netwatch-openwrt-sdk-$version-x86-64-$sha256"' \
	'missing versioned, checksum-qualified Docker volume'
require_literal 'container="netwatch-openwrt-sdk-$version-x86-64-$sha256"' \
	'missing single-writer container name for the SDK volume'
require_literal '--mount "type=volume,src=$volume,dst=/sdk"' \
	'/sdk is not mounted from the dedicated named volume'
require_literal '--mount "type=bind,src=$archive_path,dst=/sdk-archive/$archive,readonly"' \
	'SDK archive is not mounted read-only'
require_literal 'mkdir -p "$root/work/sdk/bin/packages"' \
	'host package export directory is not created before canonicalization'
require_literal 'sdk_export=$(CDPATH= cd -- "$root/work/sdk" && pwd -P)' \
	'host package export directory is not canonicalized'
require_literal '--mount "type=bind,src=$sdk_export,dst=/sdk-export"' \
	'canonical host package export is not mounted separately'
require_literal 'stamp=/sdk/.netwatch-sdk-$version-$sha256' \
	'initialization stamp is not tied to the SDK version and checksum'
require_literal '"$sha256" "$archive_path" | sha256sum -c -' \
	'archive is not checksum-verified inside the SDK container'
require_literal 'find /sdk -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' \
	'stale SDK volume is not reset inside its mount boundary'
require_literal 'tar --zstd -xf "$archive_path" -C /sdk --strip-components=1' \
	'SDK is not initialized directly from the pinned archive'
require_literal '/sdk/scripts/feeds' 'missing exact feeds executable validation'
require_literal '/sdk/staging_dir/host/bin/apk' 'missing exact apk executable validation'
require_literal 'mkdir -p /sdk/bin/packages' \
	'fresh SDK package tree is not created during initialization'
require_literal '[ ! -d /sdk/bin/packages ]; then' \
	'missing package tree does not invalidate an incomplete SDK volume'
require_literal 'export_dir=/sdk-export/bin/packages' \
	'missing legacy host package export destination'
require_literal 'rsync -a --delete /sdk/bin/packages/ "$export_dir/"' \
	'host package export is not synchronized from the named volume'
require_literal 'command_status=$?' 'child command exit status is not captured'
require_literal 'sync_status=$?' 'package export exit status is not captured'
require_literal 'exit "$command_status"' 'child command failure is not preserved'
require_literal 'exit "$sync_status"' 'package export failure is not propagated'

if grep -Fq -- '-v "$root/work/sdk:/sdk"' "$wrapper" ||
	grep -Fq -- 'src=$root/work/sdk,dst=/sdk' "$wrapper"; then
	echo 'in-sdk wrapper: host work/sdk must not be mounted at /sdk' >&2
	fail=1
fi

if grep -Fq -- '/src/work/sdk' "$wrapper"; then
	echo 'in-sdk wrapper: package exports must not resolve through /src' >&2
	fail=1
fi

if grep -Fq -- 'FORCE=1' "$wrapper"; then
	echo 'in-sdk wrapper: FORCE=1 must not bypass OpenWrt prerequisites' >&2
	fail=1
fi

node - "$wrapper" <<'NODE' || fail=1
const fs = require('fs');
const source = fs.readFileSync(process.argv[2], 'utf8');

function requireOrder(labels) {
	let cursor = -1;
	for (const [label, text] of labels) {
		const next = source.indexOf(text, cursor + 1);
		if (next < 0)
			throw new Error(`missing ${label}`);
		if (next <= cursor)
			throw new Error(`${label} is out of order`);
		cursor = next;
	}
}

requireOrder([
	['stamp check', 'if [ ! -f "$stamp" ] ||'],
	['archive verification', 'sha256sum -c -'],
	['bounded stale reset', 'find /sdk -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'],
	['archive extraction', 'tar --zstd -xf "$archive_path" -C /sdk --strip-components=1'],
	['feeds validation', '/sdk/scripts/feeds'],
	['apk validation', '/sdk/staging_dir/host/bin/apk'],
	['fresh package tree', 'mkdir -p /sdk/bin/packages'],
	['stamp creation', ': > "$stamp"'],
	['child command', '"$@"'],
	['child status capture', 'command_status=$?'],
	['package sync', 'rsync -a --delete /sdk/bin/packages/ "$export_dir/"'],
	['sync status capture', 'sync_status=$?'],
	['child status precedence', 'exit "$command_status"'],
	['sync status fallback', 'exit "$sync_status"']
]);
NODE

if grep -Fq -- 'rm -rf "$root/work/sdk"' "$fetcher" ||
	grep -Fq -- 'tar --zstd' "$fetcher"; then
	echo 'fetch-sdk wrapper: host SDK extraction must not occur on a case-insensitive filesystem' >&2
	fail=1
fi
if ! grep -Fq -- 'mkdir -p "$root/work/downloads" "$root/work/sdk/bin/packages"' "$fetcher"; then
	echo 'fetch-sdk wrapper: archive and package export directories are not prepared' >&2
	fail=1
fi

sh -n "$wrapper" "$fetcher" || fail=1

if [ "$fail" -ne 0 ]; then
	exit 1
fi

echo 'in-sdk source tests passed'
