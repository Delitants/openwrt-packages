#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime=outputs/netwatch_1.1.0-r1_all.apk
luci=outputs/luci-app-netwatch_1.1.0-r1_all.apk
scheduled=outputs/luci-app-scheduled-backup_1.0.0-r3_all.apk
source_archive=outputs/openwrt-netwatch-1.1.0-source.tar.gz
tmp=$(mktemp -d "$root/work/verify-artifacts.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

for path in "$runtime" "$luci" "$scheduled" "$source_archive" outputs/SHA256SUMS; do
	if [ ! -f "$root/$path" ]; then
		echo "error: missing artifact: $path" >&2
		exit 1
	fi
done

(
	cd "$root"
	shasum -a 256 -c outputs/SHA256SUMS
)

container_tmp=/src${tmp#"$root"}
"$root/scripts/in-sdk.sh" sh -ec '
	apk=/sdk/staging_dir/host/bin/apk
	tmp=$1
	runtime=$2
	luci=$3
	scheduled=$4
	"$apk" adbdump --format json "$runtime" > "$tmp/runtime.json"
	"$apk" adbdump --format json "$luci" > "$tmp/luci.json"
	"$apk" adbdump --format json "$scheduled" > "$tmp/scheduled.json"
	mkdir -p "$tmp/extracted/runtime" "$tmp/extracted/luci" \
		"$tmp/extracted/scheduled"
	"$apk" --allow-untrusted extract --no-chown \
		--destination "$tmp/extracted/runtime" "$runtime"
	"$apk" --allow-untrusted extract --no-chown \
		--destination "$tmp/extracted/luci" "$luci"
	"$apk" --allow-untrusted extract --no-chown \
		--destination "$tmp/extracted/scheduled" "$scheduled"
' sh "$container_tmp" "/src/$runtime" "/src/$luci" "/src/$scheduled"

jq -e '
	.info.name == "netwatch" and
	.info.version == "1.1.0-r1" and
	.info.arch == "noarch" and
	(.info.depends | sort == [
		"ca-bundle", "libc", "msmtp", "ucode", "ucode-mod-fs",
		"ucode-mod-log", "ucode-mod-socket", "ucode-mod-ubus",
		"ucode-mod-uci", "ucode-mod-uloop"
	])
' "$tmp/runtime.json" >/dev/null

jq -e '
	.info.name == "luci-app-netwatch" and
	.info.version == "1.1.0-r1" and
	.info.arch == "noarch" and
	(.info.depends | sort == [
		"libc", "luci-base", "netwatch", "rpcd-mod-luci"
	])
' "$tmp/luci.json" >/dev/null

jq -e '
	.info.name == "luci-app-scheduled-backup" and
	.info.version == "1.0.0-r3" and
	.info.arch == "noarch" and
	(.info.depends | sort == [
		"lftp", "libc", "luci-base", "openssh-client",
		"openssh-client-utils", "openssh-keygen", "rpcd",
		"rpcd-mod-file", "uci"
	])
' "$tmp/scheduled.json" >/dev/null

jq -e '
	any(.paths[];
		.name == "www/luci-static/resources/view" and
		any(.files[]?; .name == "scheduled-backup.js")) and
	(any(.paths[];
		.name == "luci-static/resources/view" and
		any(.files[]?; .name == "scheduled-backup.js")) | not) and
	any(.paths[];
		.name == "usr/share/luci/menu.d" and
		any(.files[]?; .name == "luci-app-scheduled-backup.json")) and
	any(.paths[];
		.name == "usr/share/rpcd/acl.d" and
		any(.files[]?; .name == "luci-app-scheduled-backup.json")) and
	(.scripts["post-install"] | contains("rm -f /tmp/luci-indexcache.*")) and
	(.scripts["post-install"] | contains("rm -rf /tmp/luci-modulecache/")) and
	(.scripts["post-install"] | contains("/etc/init.d/rpcd reload"))
' "$tmp/scheduled.json" >/dev/null

jq -e '
	any(.paths[];
		.name == "etc/config" and
		any(.files[]?; .name == "netwatch" and .acl.mode == 384)) and
	any(.paths[];
		.name == "etc/init.d" and
		any(.files[]?; .name == "netwatch" and .acl.mode == 493)) and
	any(.paths[];
		.name == "lib/apk/packages" and
		any(.files[]?; .name == "netwatch.conffiles"))
' "$tmp/runtime.json" >/dev/null

jq -r '
	.paths[] | .name as $dir | (.files // [])[] |
	[$dir, .name] | join("/")
' "$tmp/runtime.json" | LC_ALL=C sort > "$tmp/runtime-files"
printf '%s\n' \
	'etc/config/netwatch' \
	'etc/init.d/netwatch' \
	'lib/apk/packages/netwatch.conffiles' \
	'lib/apk/packages/netwatch.conffiles_static' \
	'lib/apk/packages/netwatch.list' \
	'usr/share/netwatch/alerts.uc' \
	'usr/share/netwatch/config.uc' \
	'usr/share/netwatch/diagnostics.uc' \
	'usr/share/netwatch/interface_probe.uc' \
	'usr/share/netwatch/interfaces.uc' \
	'usr/share/netwatch/message.uc' \
	'usr/share/netwatch/netwatchd.uc' \
	'usr/share/netwatch/ping.uc' \
	'usr/share/netwatch/probe.uc' \
	'usr/share/netwatch/result.uc' \
	'usr/share/netwatch/state.uc' \
	'usr/share/netwatch/store.uc' > "$tmp/runtime-files.expected"
diff -u "$tmp/runtime-files.expected" "$tmp/runtime-files"

jq -r '
	.paths[] | .name as $dir | (.files // [])[] |
	[$dir, .name] | join("/")
' "$tmp/luci.json" | LC_ALL=C sort > "$tmp/luci-files"
printf '%s\n' \
	'lib/apk/packages/luci-app-netwatch.list' \
	'usr/share/luci/menu.d/luci-app-netwatch.json' \
	'usr/share/rpcd/acl.d/luci-app-netwatch.json' \
	'usr/share/ucitrack/luci-app-netwatch.json' \
	'www/luci-static/resources/view/netwatch/email.js' \
	'www/luci-static/resources/view/netwatch/monitors.js' \
	'www/luci-static/resources/view/netwatch/status.js' > "$tmp/luci-files.expected"
diff -u "$tmp/luci-files.expected" "$tmp/luci-files"

grep -Fxq '/etc/config/netwatch' \
	"$tmp/extracted/runtime/lib/apk/packages/netwatch.conffiles"

grep -Fxq '/etc/config/scheduled-backup' \
	"$tmp/extracted/scheduled/lib/apk/packages/luci-app-scheduled-backup.conffiles"
grep -Fxq '/etc/scheduled-backup/' \
	"$tmp/extracted/scheduled/lib/apk/packages/luci-app-scheduled-backup.conffiles"

scheduled_view="$tmp/extracted/scheduled/www/luci-static/resources/view/scheduled-backup.js"
if find "$tmp/extracted/scheduled/www/luci-static/resources" -type f -name '*.js.o' \
	-print | grep -q .; then
	echo 'error: failed LuCI minifier output found in Scheduled Backup APK' >&2
	exit 1
fi

for class in \
	'table cbi-section-table' \
	'tr cbi-section-table-row' \
	'th cbi-section-table-cell left' \
	'td cbi-section-table-cell left'
do
	grep -Fq "$class" "$scheduled_view" || {
		echo "error: built Scheduled Backup view lacks layout class: $class" >&2
		exit 1
	}
done

if find "$tmp/extracted" -type f -perm -022 -print | grep -q .; then
	echo 'error: group- or world-writable file found in APK contents' >&2
	find "$tmp/extracted" -type f -perm -022 -print >&2
	exit 1
fi

if grep -R -E -i \
	'top-secret-value|router-user|smtp\.example\.test|password stolen|test-password|fixture-password|supersecret|alerts@example|router@example|replace-with-an-app-password' \
	"$tmp/extracted"; then
	echo 'error: test fixture or documentation credential found in APK contents' >&2
	exit 1
fi

if find "$tmp/extracted/luci" -type f \( -name '*.pot' -o -name '*.po' \) \
	-print | grep -q .; then
	echo 'error: source-only translation catalog found in LuCI APK' >&2
	exit 1
fi

tar -tzf "$root/$source_archive" > "$tmp/source-files"
duplicates=$(LC_ALL=C sort "$tmp/source-files" | uniq -d)
if [ -n "$duplicates" ]; then
	echo 'error: duplicate source archive paths' >&2
	printf '%s\n' "$duplicates" >&2
	exit 1
fi

if grep -E '/(\.git|\.superpowers|work|outputs)(/|$)' "$tmp/source-files"; then
	echo 'error: excluded local path found in source archive' >&2
	exit 1
fi

for required in \
	openwrt-netwatch-1.1.0/README.md \
	openwrt-netwatch-1.1.0/scripts/build-packages.sh \
	openwrt-netwatch-1.1.0/scripts/package-output.sh \
	openwrt-netwatch-1.1.0/scripts/verify-artifacts.sh \
	openwrt-netwatch-1.1.0/packages/netwatch/netwatch/Makefile \
	openwrt-netwatch-1.1.0/packages/netwatch/luci-app-netwatch/Makefile \
	openwrt-netwatch-1.1.0/packages/scheduled-backup/luci-app-scheduled-backup/Makefile
do
	grep -Fxq "$required" "$tmp/source-files"
done

echo 'artifact verification passed: manifests, dependencies, contents, LuCI post-install, modes, conffiles, credential scan, source archive, and checksums'
