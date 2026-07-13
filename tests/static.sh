#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail=0

require_file() {
	if [ ! -f "$root/$1" ]; then
		echo "missing: $1" >&2
		fail=1
	fi
}

require_file netwatch/Makefile
require_file netwatch/files/etc/config/netwatch
require_file netwatch/files/etc/init.d/netwatch
require_file netwatch/files/usr/share/netwatch/store.uc
require_file netwatch/files/usr/share/netwatch/netwatchd.uc
require_file luci-app-netwatch/Makefile
require_file tools/sdk/Dockerfile
require_file scripts/fetch-sdk.sh
require_file scripts/in-sdk.sh

if [ "$fail" -eq 0 ]; then
	sh -n "$root/netwatch/files/etc/init.d/netwatch" || fail=1

	"$root/scripts/in-sdk.sh" sh -ec '
		mkdir -p /tmp/ucode-modules
		touch /tmp/ucode-modules/fs.so \
			/tmp/ucode-modules/log.so \
			/tmp/ucode-modules/socket.so \
			/tmp/ucode-modules/ubus.so \
			/tmp/ucode-modules/uci.so \
			/tmp/ucode-modules/uloop.so

		for file in netwatch/files/usr/share/netwatch/*.uc; do
			module=${file##*/}
			module=${module%.uc}
			printf "import * as checked from '\''%s'\'';\n" "$module" > /tmp/check.uc
			ucode -L /tmp/ucode-modules \
				-L /src/netwatch/files/usr/share/netwatch -c \
				-o /tmp/netwatch.ucb /tmp/check.uc
		done
	' || fail=1

	for declaration in \
		"conn.publish('netwatch'" \
		'status:' \
		'check:' \
		'test_email:' \
		"uloop.signal('HUP'" \
		'request.defer()' \
		'--timeout=60' \
		'const MSMTP_PROCESS_TIMEOUT_MS = 65000;' \
		"uloop.process('/bin/sh'" \
		"uloop.process('/bin/kill'" \
		'delivery_result_succeeded'
	do
		if ! grep -Fq -- "$declaration" \
			"$root/netwatch/files/usr/share/netwatch/netwatchd.uc"; then
			echo "missing daemon declaration: $declaration" >&2
			fail=1
		fi
	done

	if grep -ERn '(^|[^[:alnum:]_])(system|eval)[[:space:]]*\(' \
		"$root/netwatch/files/usr/share/netwatch"; then
		echo 'unsafe command execution primitive found' >&2
		fail=1
	fi

	if grep -En '(command|argv)[[:space:]]*:' \
		"$root/netwatch/files/usr/share/netwatch/netwatchd.uc"; then
		echo 'generic ubus command parameter found' >&2
		fail=1
	fi

	if grep -Fq 'alert_generation == generation' \
		"$root/netwatch/files/usr/share/netwatch/netwatchd.uc"; then
		echo 'successful mail result is incorrectly discarded across reload' >&2
		fail=1
	fi

	if awk '
		/^[[:space:]]*timeout_handle = null;/ {
			if (previous !~ /timeout_handle[.]cancel[(][)];/)
				bad = 1
		}
		!/^[[:space:]]*$/ { previous = $0 }
		END { exit bad ? 0 : 1 }
	' "$root/netwatch/files/usr/share/netwatch/netwatchd.uc"; then
		echo 'fired delivery timer is not explicitly released' >&2
		fail=1
	fi

	if grep -Fq 'fs.popen(MSMTP_COMMAND' \
		"$root/netwatch/files/usr/share/netwatch/netwatchd.uc"; then
		echo 'delivery watchdog does not own the msmtp process' >&2
		fail=1
	fi

	if grep -Fq 'finish(exit_code == 0)' \
		"$root/netwatch/files/usr/share/netwatch/netwatchd.uc"; then
		echo 'lossy uloop signal status is treated as successful mail' >&2
		fail=1
	fi

	if grep -Ein 'password|username|server|recipient|smtp' \
		"$root/netwatch/files/usr/share/netwatch/store.uc"; then
		echo 'private field found in public status construction' >&2
		fail=1
	fi
fi

exit "$fail"
