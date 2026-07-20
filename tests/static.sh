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

require_file packages/netwatch/netwatch/Makefile
require_file packages/netwatch/netwatch/files/etc/config/netwatch
require_file packages/netwatch/netwatch/files/etc/init.d/netwatch
for module in \
	alerts config diagnostics interface_probe interfaces message netwatchd ping \
	probe result state store
do
	require_file "packages/netwatch/netwatch/files/usr/share/netwatch/$module.uc"
done
require_file packages/netwatch/luci-app-netwatch/Makefile
require_file packages/netwatch/luci-app-netwatch/root/usr/share/luci/menu.d/luci-app-netwatch.json
require_file packages/netwatch/luci-app-netwatch/root/usr/share/rpcd/acl.d/luci-app-netwatch.json
require_file packages/netwatch/luci-app-netwatch/root/usr/share/ucitrack/luci-app-netwatch.json
require_file packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/status.js
require_file packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/monitors.js
require_file packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js
require_file packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot
require_file README.md
require_file tools/sdk/Dockerfile
require_file scripts/fetch-sdk.sh
require_file scripts/in-sdk.sh
require_file scripts/build-packages.sh
require_file scripts/package-output.sh
require_file scripts/verify-artifacts.sh
require_file tests/package-output_test.sh

for selector in CONFIG_ALL CONFIG_ALL_KMODS CONFIG_ALL_NONSHARED; do
	if ! grep -Fq -- "# $selector is not set" \
		"$root/scripts/build-packages.sh"; then
		echo "build script does not disable SDK-wide selector: $selector" >&2
		fail=1
	fi
done

if grep -Fq -- 'if [ -f .config ]; then' \
	"$root/scripts/build-packages.sh"; then
	echo 'build script preserves stale SDK package selections' >&2
	fail=1
fi

if [ "$fail" -eq 0 ]; then
	"$root/tests/package-output_test.sh" || fail=1
fi

if ! grep -Fq '# call BuildPackage - OpenWrt buildroot signature' \
	"$root/packages/netwatch/luci-app-netwatch/Makefile"; then
	echo 'missing LuCI BuildPackage scanner signature' >&2
	fail=1
fi

if ! awk '
	/^define Package\/netwatch$/ { in_package = 1; next }
	/^endef$/ && in_package { exit found ? 0 : 1 }
	in_package && /^[[:space:]]*PKGARCH:=all[[:space:]]*$/ { found = 1 }
	END { if (in_package && !found) exit 1 }
' "$root/packages/netwatch/netwatch/Makefile"; then
	echo 'runtime package is not explicitly architecture-independent' >&2
	fail=1
fi

for makefile in \
	packages/netwatch/netwatch/Makefile \
	packages/netwatch/luci-app-netwatch/Makefile
do
	for declaration in 'PKG_VERSION:=1.1.0' 'PKG_RELEASE:=1'; do
		if ! grep -Fq -- "$declaration" "$root/$makefile"; then
			echo "missing package version declaration in $makefile: $declaration" >&2
			fail=1
		fi
	done
done

if grep -Eq '(^|[[:space:]])\+iwinfo([[:space:]]|$)' \
	"$root/packages/netwatch/netwatch/Makefile"; then
	echo 'runtime package has a hard iwinfo dependency' >&2
	fail=1
fi

for metadata in \
	'TITLE:=Lightweight host, TCP service, and network-interface monitor' \
	'Monitor hosts, TCP services, and network interfaces' \
	'LUCI_TITLE:=LuCI support for Netwatch host, TCP service, and interface monitoring'
do
	if ! grep -FRq -- "$metadata" \
		"$root/packages/netwatch/netwatch/Makefile" \
		"$root/packages/netwatch/luci-app-netwatch/Makefile"; then
		echo "missing release package metadata: $metadata" >&2
		fail=1
	fi
done

for expectation in \
	'runtime=outputs/netwatch_1.1.0-r1_all.apk' \
	'luci=outputs/luci-app-netwatch_1.1.0-r1_all.apk' \
	'source_archive=outputs/openwrt-netwatch-1.1.0-source.tar.gz' \
	'.info.version == "1.1.0-r1"' \
	'openwrt-netwatch-1.1.0/README.md'
do
	if ! grep -Fq -- "$expectation" "$root/scripts/verify-artifacts.sh"; then
		echo "missing artifact verification expectation: $expectation" >&2
		fail=1
	fi
done

for module in \
	alerts config diagnostics interface_probe interfaces message netwatchd ping \
	probe result state store
do
	if ! grep -Fq -- "usr/share/netwatch/$module.uc" \
		"$root/scripts/verify-artifacts.sh"; then
		echo "artifact verifier is missing runtime module: $module.uc" >&2
		fail=1
	fi
done

runtime_manifest_count=$(awk '
	/^[[:space:]]*'\''etc\/config\/netwatch'\''/ { runtime = 1 }
	runtime && /^[[:space:]]*'\''[^'\'']+'\''/ { count++ }
	runtime && /runtime-files\.expected/ { print count; exit }
' "$root/scripts/verify-artifacts.sh")
luci_manifest_count=$(awk '
	/^[[:space:]]*'\''lib\/apk\/packages\/luci-app-netwatch\.list'\''/ { luci = 1 }
	luci && /^[[:space:]]*'\''[^'\'']+'\''/ { count++ }
	luci && /luci-files\.expected/ { print count; exit }
' "$root/scripts/verify-artifacts.sh")
if [ "$runtime_manifest_count" != 17 ] || [ "$luci_manifest_count" != 7 ]; then
	echo "artifact manifest counts are not exactly 17 runtime and 7 LuCI paths: $runtime_manifest_count/$luci_manifest_count" >&2
	fail=1
fi

if [ "$fail" -eq 0 ]; then
	readme="$root/README.md"
	pot="$root/packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot"
	menu_catalog="$root/packages/netwatch/luci-app-netwatch/root/usr/share/luci/menu.d/luci-app-netwatch.json"
	acl_catalog="$root/packages/netwatch/luci-app-netwatch/root/usr/share/rpcd/acl.d/luci-app-netwatch.json"

	for heading in Requirements Build Install Configure Troubleshooting Upgrade Uninstall; do
		if ! grep -Fxq -- "## $heading" "$readme"; then
			echo "missing README section: $heading" >&2
			fail=1
		fi
	done

	for text in \
		'OpenWrt 25.12.5' \
		'x86/64' \
		'outputs/netwatch_1.1.0-r1_all.apk' \
		'outputs/luci-app-netwatch_1.1.0-r1_all.apk' \
		'outputs/openwrt-netwatch-1.1.0-source.tar.gz' \
		'17 runtime manifest paths' \
		'exactly seven LuCI manifest paths' \
		'https://raw.githubusercontent.com/Delitants/openwrt-packages/main/keys/netwatch-local.pem' \
		'https://raw.githubusercontent.com/Delitants/openwrt-packages/main/feed/x86_64/packages.adb' \
		'/etc/apk/repositories.d/customfeeds.list' \
		'apk add netwatch luci-app-netwatch' \
		'./scripts/rebuild-feed.sh x86_64 work/signing/private-key.pem' \
		'Services > Netwatch' \
		"uci set netwatch.office_wifi.type='interface'" \
		"uci set netwatch.office_wifi.interface_selector='wifi-iface:office'" \
		'network:, device:, wifi-radio:, and wifi-iface:' \
		'disabled or absent' \
		'optional iwinfo' \
		'port 587 with STARTTLS' \
		'port 465 with implicit TLS' \
		'Active incidents and their email counters reset after a router reboot.' \
		'/etc/init.d/netwatch restart' \
		'ubus call netwatch status' \
		'ubus call netwatch interfaces' \
		'logread -e netwatch' \
		'apk upgrade netwatch luci-app-netwatch' \
		'apk del luci-app-netwatch netwatch'
	do
		if ! grep -Fq -- "$text" "$readme"; then
			echo "missing README content: $text" >&2
			fail=1
		fi
	done

	node - "$readme" <<'NODE' || fail=1
const fs = require('fs');
const source = fs.readFileSync(process.argv[2], 'utf8');

function section(name, next) {
	const begin = source.indexOf(`## ${name}\n`);
	const end = source.indexOf(`## ${next}\n`, begin + 1);
	if (begin < 0 || end < 0)
		throw new Error(`unable to isolate README ${name} section`);
	return source.slice(begin, end).replace(/\s+/g, ' ');
}

const build = section('Build', 'Build verification');
const verification = section('Build verification', 'Install');
const configure = section('Configure', 'Package feed maintenance');
const errors = [];

if (!build.includes('These are the planned 1.1.0 release outputs.') ||
	!build.includes('The currently published feed remains at `netwatch-1.0.0-r1` and `luci-app-netwatch-1.0.0-r1` until the 1.1.0 release is built, signed, and published.'))
	errors.push('README must distinguish planned 1.1.0 outputs from the current 1.0.0-r1 feed');

if (!verification.startsWith('## Build verification Release artifacts are built with the pinned OpenWrt 25.12.5 x86/64 SDK and can be inspected with its apk-tools 3.0.5.') ||
	/\brelease artifacts were built\b/i.test(verification) ||
	/\b1\.1\.0[^.]*\b(were|have been) (built|inspected)\b/i.test(verification))
	errors.push('README build verification must be prospective and must not claim unbuilt 1.1.0 artifacts were inspected');

if (!configure.includes('Every due interface failure email—initial, repeat, or retry when applicable—starts a fresh diagnostic collection. Diagnostic reports are not cached or persisted.') ||
	!configure.includes('These email-only diagnostics are fresh, bounded, and redacted.'))
	errors.push('README must promise fresh non-persisted diagnostics for every due interface failure email');

if (errors.length)
	throw new Error(errors.join('\n'));
NODE

	node - "$pot" \
		"$root/packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/status.js" \
		"$root/packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/monitors.js" \
		"$root/packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js" \
		"$menu_catalog" "$acl_catalog" <<'NODE' || fail=1
const fs = require("fs");

function readString(source, start) {
	const quote = source.charCodeAt(start);
	let escaped = false;
	let end = start + 1;

	for (; end < source.length; end++) {
		const code = source.charCodeAt(end);

		if (escaped) {
			escaped = false;
			continue;
		}

		if (code === 92) {
			escaped = true;
			continue;
		}

		if (code === quote) {
			const literal = source.slice(start, end + 1);
			return {
				end: end + 1,
				value: Function(`"use strict"; return (${literal});`)()
			};
		}
	}

	throw new Error(`unterminated string literal at byte ${start}`);
}

function skipQuoted(source, start) {
	return readString(source, start).end;
}

function skipTemplate(source, start) {
	let escaped = false;

	for (let i = start + 1; i < source.length; i++) {
		const code = source.charCodeAt(i);

		if (escaped) {
			escaped = false;
			continue;
		}

		if (code === 92) {
			escaped = true;
			continue;
		}

		if (code === 96)
			return i + 1;
	}

	throw new Error(`unterminated template literal at byte ${start}`);
}

function translationLiterals(source) {
	const values = new Set();
	const identifier = /[A-Za-z0-9_$]/;

	for (let i = 0; i < source.length;) {
		const code = source.charCodeAt(i);
		const next = source.charCodeAt(i + 1);

		if (code === 34 || code === 39) {
			i = skipQuoted(source, i);
			continue;
		}

		if (code === 96) {
			i = skipTemplate(source, i);
			continue;
		}

		if (code === 47 && next === 47) {
			const end = source.indexOf("\n", i + 2);
			i = end < 0 ? source.length : end + 1;
			continue;
		}

		if (code === 47 && next === 42) {
			const end = source.indexOf("*/", i + 2);
			if (end < 0)
				throw new Error(`unterminated block comment at byte ${i}`);
			i = end + 2;
			continue;
		}

		if (source[i] === "_" &&
			(i === 0 || !identifier.test(source[i - 1])) &&
			(i + 1 === source.length || !identifier.test(source[i + 1]))) {
			let cursor = i + 1;
			while (/\s/.test(source[cursor] || "")) cursor++;

			if (source[cursor] === "(") {
				cursor++;
				while (/\s/.test(source[cursor] || "")) cursor++;
				const literalCode = source.charCodeAt(cursor);

				if (literalCode === 34 || literalCode === 39) {
					const parsed = readString(source, cursor);
					values.add(parsed.value);
					i = parsed.end;
					continue;
				}
			}
		}

		i++;
	}

	return values;
}

function potMsgids(source) {
	const values = new Set();
	const lines = source.split(/\r?\n/);
	let current = null;

	function finish() {
		if (current !== null && current !== "")
			values.add(current);
		current = null;
	}

	for (const line of lines) {
		if (line.startsWith("msgid ")) {
			finish();
			current = JSON.parse(line.slice(6));
		}
		else if (current !== null && line.startsWith("\"")) {
			current += JSON.parse(line);
		}
		else if (current !== null) {
			finish();
		}
	}

	finish();
	return values;
}

const expected = new Set();
for (const file of process.argv.slice(3, 6)) {
	for (const value of translationLiterals(fs.readFileSync(file, "utf8")))
		expected.add(value);
}

const menu = JSON.parse(fs.readFileSync(process.argv[6], "utf8"));
for (const entry of Object.values(menu)) {
	if (typeof entry?.title === "string")
		expected.add(entry.title);
}

const acl = JSON.parse(fs.readFileSync(process.argv[7], "utf8"));
for (const grant of Object.values(acl)) {
	if (typeof grant?.description === "string")
		expected.add(grant.description);
}

const actual = potMsgids(fs.readFileSync(process.argv[2], "utf8"));
const missing = [...expected].filter(value => !actual.has(value)).sort();
const unexpected = [...actual].filter(value => !expected.has(value)).sort();

if (missing.length || unexpected.length) {
	if (missing.length)
		console.error(`POT missing msgids: ${JSON.stringify(missing)}`);
	if (unexpected.length)
		console.error(`POT unexpected msgids: ${JSON.stringify(unexpected)}`);
	process.exit(1);
}
NODE

	sh -n "$root/packages/netwatch/netwatch/files/etc/init.d/netwatch" || fail=1

	"$root/scripts/in-sdk.sh" sh -ec '
		mkdir -p /tmp/ucode-modules
		touch /tmp/ucode-modules/fs.so \
			/tmp/ucode-modules/log.so \
			/tmp/ucode-modules/socket.so \
			/tmp/ucode-modules/ubus.so \
			/tmp/ucode-modules/uci.so \
			/tmp/ucode-modules/uloop.so

		for file in packages/netwatch/netwatch/files/usr/share/netwatch/*.uc; do
			module=${file##*/}
			module=${module%.uc}
			printf "import * as checked from '\''%s'\'';\n" "$module" > /tmp/check.uc
			ucode -L /tmp/ucode-modules \
				-L /src/packages/netwatch/netwatch/files/usr/share/netwatch -c \
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
		'delivery_result_succeeded' \
		'const SHUTDOWN_TIMEOUT_MS = 5000;' \
		'let active_deliveries = [];' \
		'push(active_deliveries, context);' \
		"let terminate_signal = uloop.signal('TERM'" \
		"let interrupt_signal = uloop.signal('INT'" \
		'scheduler.cancel();' \
		'shutdown_timer.cancel();' \
		'stop_active_delivery' \
		'if (!shutting_down) callback(delivered === true);' \
		'if (shutting_down && !length(active_deliveries))' \
		'uloop.end()'
	do
		if ! grep -Fq -- "$declaration" \
			"$root/packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc"; then
			echo "missing daemon declaration: $declaration" >&2
			fail=1
		fi
	done

	for declaration in \
		"import { collect_interface_inventory } from 'interfaces';" \
		"import { start_diagnostics } from 'diagnostics';" \
		'interfaces:' \
		'call: request_interfaces' \
		'start_diagnostics(monitor, state.last_result' \
		'diagnostic start selector' \
		"Diagnostic collection incomplete"
	do
		if ! grep -Fq -- "$declaration" \
			"$root/packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc"; then
			echo "missing interface daemon declaration: $declaration" >&2
			fail=1
		fi
	done

	if grep -Fq 'diagnostic:' \
		"$root/packages/netwatch/netwatch/files/usr/share/netwatch/store.uc"; then
		echo 'full diagnostic report is exposed through status' >&2
		fail=1
	fi

	node -e '
		const source = require("fs").readFileSync(process.argv[1], "utf8");
		const begin = source.indexOf("function start_alert(monitor, state, kind, now)");
		const end = source.indexOf("\n\nfunction scheduler_tick", begin);
		const body = source.slice(begin, end);
		const claim = body.indexOf("state.mail_busy = true;");
		const guard = body.indexOf("monitor.type == ");
		const kindGuard = body.indexOf("kind == ", guard);
		const collect = body.indexOf("start_diagnostics(monitor, state.last_result", guard);
		const fallback = body.indexOf("Diagnostic collection incomplete", collect);
		const deliver = body.indexOf("start_alert_delivery(monitor, state, kind, now, recipients", guard);
		if (begin < 0 || end < 0 ||
			![claim, guard, kindGuard, collect, fallback, deliver].every(value => value >= 0) ||
			!(claim < guard && guard < kindGuard && kindGuard < collect && collect < fallback))
			throw new Error("interface diagnostics must be fresh, guarded, and fall back to delivery");
		if (source.indexOf("function start_alert_delivery") < 0 ||
			source.indexOf("start_delivery(message", source.indexOf("function start_alert_delivery")) < 0)
			throw new Error("diagnostic completion must reach the existing bounded mail delivery path");
	' "$root/packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc" || fail=1

	node -e '
		const source = require("fs").readFileSync(process.argv[1], "utf8");
		const begin = source.indexOf("function start_alert(monitor, state, kind, now)");
		const end = source.indexOf("\n\nfunction scheduler_tick", begin);
		const body = source.slice(begin, end);
		const callback = body.indexOf("let finished = (diagnostic) => {");
		const onceGuard = body.indexOf("if (diagnostics_finished) return;", callback);
		const onceClaim = body.indexOf("diagnostics_finished = true;", onceGuard);
		const monitorGuard = body.indexOf("monitor_by_id[monitor.id] !== monitor", onceClaim);
		const incidentGuard = body.indexOf("state.incident_started != incident_started", monitorGuard);
		const resultGuard = body.indexOf("state.last_result !== diagnostic_result", incidentGuard);
		const release = body.indexOf("state.mail_busy = false;", monitorGuard);
		const deliver = body.indexOf("start_alert_delivery(monitor, state, kind, now, recipients", resultGuard);
		if (![callback, onceGuard, onceClaim, monitorGuard, incidentGuard,
			resultGuard, release, deliver].every(value => value >= 0) ||
			!(callback < onceGuard && onceGuard < onceClaim && onceClaim < monitorGuard &&
				monitorGuard < incidentGuard && incidentGuard < resultGuard &&
				resultGuard < release && release < deliver))
			throw new Error("diagnostic callbacks must be once-only and reject stale monitor incidents before delivery");
	' "$root/packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc" || fail=1

	if grep -ERn '(^|[^[:alnum:]_])(system|eval)[[:space:]]*\(' \
		"$root/packages/netwatch/netwatch/files/usr/share/netwatch"; then
		echo 'unsafe command execution primitive found' >&2
		fail=1
	fi

	if grep -En '(command|argv)[[:space:]]*:' \
		"$root/packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc"; then
		echo 'generic ubus command parameter found' >&2
		fail=1
	fi

	if grep -Fq 'alert_generation == generation' \
		"$root/packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc"; then
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
	' "$root/packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc"; then
		echo 'fired delivery timer is not explicitly released' >&2
		fail=1
	fi

	if awk '
		/^[[:space:]]*shutdown_timer = null;/ {
			if (previous !~ /shutdown_timer[.]cancel[(][)];/)
				bad = 1
		}
		!/^[[:space:]]*$/ { previous = $0 }
		END { exit bad ? 0 : 1 }
	' "$root/packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc"; then
		echo 'shutdown timer is not explicitly released before loop end' >&2
		fail=1
	fi

	if grep -Fq 'fs.popen(MSMTP_COMMAND' \
		"$root/packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc"; then
		echo 'delivery watchdog does not own the msmtp process' >&2
		fail=1
	fi

	if grep -Fq 'finish(exit_code == 0)' \
		"$root/packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc"; then
		echo 'lossy uloop signal status is treated as successful mail' >&2
		fail=1
	fi

	if grep -Ein 'password|username|server|recipient|smtp' \
		"$root/packages/netwatch/netwatch/files/usr/share/netwatch/store.uc"; then
		echo 'private field found in public status construction' >&2
		fail=1
	fi

	menu="$root/packages/netwatch/luci-app-netwatch/root/usr/share/luci/menu.d/luci-app-netwatch.json"
	acl="$root/packages/netwatch/luci-app-netwatch/root/usr/share/rpcd/acl.d/luci-app-netwatch.json"
	ucitrack="$root/packages/netwatch/luci-app-netwatch/root/usr/share/ucitrack/luci-app-netwatch.json"
	status="$root/packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/status.js"
	monitors="$root/packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/monitors.js"
	email="$root/packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js"

	for json in "$menu" "$acl" "$ucitrack"; do
		node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' \
			"$json" || fail=1
	done

	node -e '
		const menu = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
		const expected = {
			"admin/services/netwatch": ["Netwatch", 85, "firstchild", null],
			"admin/services/netwatch/status": ["Status", 10, "view", "netwatch/status"],
			"admin/services/netwatch/monitors": ["Monitors", 20, "view", "netwatch/monitors"],
			"admin/services/netwatch/email": ["Email", 30, "view", "netwatch/email"]
		};
		if (JSON.stringify(Object.keys(menu).sort()) !== JSON.stringify(Object.keys(expected).sort()))
			throw new Error("menu must contain exactly the Netwatch parent and three children");
		for (const [path, values] of Object.entries(expected)) {
			const entry = menu[path];
			if (entry.title !== values[0] || entry.order !== values[1] || entry.action?.type !== values[2] ||
				(values[3] == null ? entry.action?.path != null : entry.action?.path !== values[3]))
				throw new Error(`invalid menu entry ${path}`);
		}
		if (JSON.stringify(menu["admin/services/netwatch"].depends) !== JSON.stringify({ acl: ["luci-app-netwatch"] }))
			throw new Error("Netwatch parent must require its ACL");
	' "$menu" || fail=1

	node -e '
		const acl = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
		const grant = acl["luci-app-netwatch"];
		if (!grant || Object.keys(acl).length !== 1)
			throw new Error("ACL must contain exactly one named grant");
		const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
		if (!same(grant.read?.uci, ["netwatch"]) ||
			!same(grant.read?.ubus, {
				"luci-rpc": ["getDHCPLeases"],
				netwatch: ["status", "interfaces"]
			}) ||
			!same(grant.write?.uci, ["netwatch"]) ||
			!same(grant.write?.ubus, { netwatch: ["check", "test_email"] }))
			throw new Error("ACL is not the exact least-privilege Netwatch grant");
	' "$acl" || fail=1

	node -e '
		const track = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
		if (JSON.stringify(track) !== JSON.stringify({ config: "netwatch", init: "netwatch" }))
			throw new Error("invalid Netwatch UCI reload tracking");
	' "$ucitrack" || fail=1

	for view in "$status" "$monitors" "$email"; do
		node --check "$view" || fail=1
	done

	node -e '
		const source = require("fs").readFileSync(process.argv[1], "utf8");
		const dhcpBegin = source.indexOf("const callDHCPLeases");
		const interfacesBegin = source.indexOf("const callInterfaces");
		const labelsBegin = source.indexOf("const INTERFACE_GROUP_LABELS");
		if (dhcpBegin < 0 || interfacesBegin < 0 || labelsBegin < 0 ||
			!(dhcpBegin < interfacesBegin && interfacesBegin < labelsBegin))
			throw new Error("unable to isolate monitor RPC declarations");
		const dhcpDeclaration = source.slice(dhcpBegin, interfacesBegin);
		const interfacesDeclaration = source.slice(interfacesBegin, labelsBegin);
		if (!/\breject\s*:\s*true\b/.test(interfacesDeclaration) ||
			/\breject\s*:\s*true\b/.test(dhcpDeclaration))
			throw new Error("interface inventory RPC failures must reject without changing DHCP lease fallback behavior");
		if (!source.includes("L.resolveDefault(callInterfaces(), { groups: [], errors: [ '"'"'unavailable'"'"' ] })") ||
			!source.includes("inventoryErrors.length") ||
			!source.includes("Interface inventory is temporarily incomplete. Saved selections are preserved."))
			throw new Error("interface RPC rejection must drive the incomplete-inventory fallback description");
	' "$monitors" || fail=1

	for declaration in \
		"object: 'netwatch', method: 'status', expect: { '': {} }" \
		"object: 'netwatch', method: 'interfaces', expect: { '': {} }" \
		"object: 'netwatch', method: 'check', params: [ 'id' ]" \
		"uci.load('netwatch')" \
		"uci.sections('netwatch', 'monitor')" \
		'poll.add(' \
		'cbi_update_table(' \
		"_('Monitor')" \
		"_('Target')" \
		"_('Test')" \
		"_('State')" \
		"_('Last check')" \
		"_('Last transition')" \
		"_('Result')" \
		"_('Incident')" \
		"_('Emails')" \
		"_('Unknown')" \
		"_('Healthy')" \
		"_('Pending')" \
		"_('Failed')" \
		"_('Disabled')" \
		"_('Invalid configuration')" \
		"_('Administratively disabled')" \
		"_('Interface absent')" \
		"_('Interface unavailable')" \
		"_('Link down')" \
		"_('Carrier lost')" \
		"_('Wi-Fi radio down')" \
		"_('Wi-Fi AP down')" \
		"_('Wi-Fi initialization failed')" \
		"_('Interface status unavailable')" \
		"_('Check now')" \
		'function inventoryBySelector' \
		'function interfaceIdentity' \
		'function formatInterfaceResult' \
		'function formatEmails(value, cap)' \
		'state.last_transition' \
		'monitor.max_alerts' \
		"classList.add('spinning')" \
		'button.disabled = true;' \
		'callCheck(id)' \
		'if (!force && hasChecksInFlight())' \
		'delete checksInFlight[id];' \
		'refreshStatus(table, notice, true)' \
		'handleSave: null' \
		'handleSaveApply: null' \
		'handleReset: null'
	do
		if ! grep -Fq -- "$declaration" "$status"; then
			echo "missing status view declaration: $declaration" >&2
			fail=1
		fi
	done

	node -e '
		const source = require("fs").readFileSync(process.argv[1], "utf8");
		const join = source.indexOf("function configuredMonitors");
		const rows = source.indexOf("function statusRows");
		const pollGuard = source.indexOf("if (!force && hasChecksInFlight())");
		const update = source.indexOf("cbi_update_table(", pollGuard);
		const check = source.indexOf("function handleCheckNow");
		const claim = source.indexOf("checksInFlight[id] = true;", check);
		const busy = source.indexOf("button.classList.add('"'"'spinning'"'"')", claim);
		const rpc = source.indexOf("callCheck(id)", busy);
		const release = source.indexOf("delete checksInFlight[id];", rpc);
		const refresh = source.indexOf("refreshStatus(table, notice, true)", release);
		if (![ join, rows, pollGuard, update, check, claim, busy, rpc, release, refresh ].every(pos => pos >= 0) ||
			!(join < rows && pollGuard < update && check < claim && claim < busy && busy < rpc && rpc < release && release < refresh))
			throw new Error("status polling must join UCI metadata and preserve a live check-now busy action");
		if (!source.includes("monitor['"'"'.name'"'"']") || !source.includes("stateById[id]"))
			throw new Error("public status entries must be joined to named UCI monitor sections");
		if (source.includes("innerHTML") || source.includes("last_result.detail"))
			throw new Error("status view must render DOM-safe normalized text only");
		if (/addNotification\([^;]*(err(or)?[.]|response[.]|result[.]error)/.test(source))
			throw new Error("status action notification exposes a remote error string");
	' "$status" || fail=1

	node -e '
		const source = require("fs").readFileSync(process.argv[1], "utf8");
		const begin = source.indexOf("function statusRows");
		const end = source.indexOf("\n\nfunction showAvailability", begin);
		if (begin < 0 || end < 0)
			throw new Error("unable to load status row renderer");

		const checksInFlight = { alpha: true, beta: true };
		const monitors = [
			{ ".name": "alpha", name: "Alpha", target: "192.0.2.1" },
			{ ".name": "beta", name: "Beta", target: "192.0.2.2" }
		];
		function E(tag, attrs, children) {
			const classes = new Set();
			return {
				tag,
				attrs: attrs || {},
				children,
				disabled: false,
				classList: {
					add: value => classes.add(value),
					remove: value => classes.delete(value),
					contains: value => classes.has(value)
				}
			};
		}

		const statusRows = Function(
			"checksInFlight", "configuredMonitors", "E", "configuredText",
			"formatTest", "stateBadge", "formatTimestamp", "formatResult",
			"formatEmails", "handleCheckNow", "_",
			`${source.slice(begin, end)}; return statusRows;`
		)(
			checksInFlight, () => monitors, E, (value, fallback) => value || fallback,
			() => "test", () => "state", () => "time", () => "result",
			() => "0", () => {}, value => value
		);
		const status = { monitors: [
			{ id: "alpha", status: "healthy" },
			{ id: "beta", status: "healthy" }
		] };

		let rows = statusRows(status, Object.create(null), {}, {});
		if (!rows[0][9].disabled || !rows[0][9].classList.contains("spinning") ||
			!rows[1][9].disabled || !rows[1][9].classList.contains("spinning"))
			throw new Error("rebuilt status rows must preserve every active check busy state");

		delete checksInFlight.alpha;
		rows = statusRows(status, Object.create(null), {}, {});
		if (rows[0][9].disabled || rows[0][9].classList.contains("spinning") ||
			!rows[1][9].disabled || !rows[1][9].classList.contains("spinning"))
			throw new Error("completing one check must leave other active rows visibly busy");
	' "$status" || fail=1

	node -e '
		const source = require("fs").readFileSync(process.argv[1], "utf8");
		const begin = source.indexOf("function configuredText");
		const end = source.indexOf("\n\nfunction stateBadge", begin);
		if (begin < 0 || end < 0)
			throw new Error("unable to load interface status helpers");
		String.prototype.format = function(...values) {
			let index = 0;
			return this.replace(/%[sd]/g, () => String(values[index++]));
		};
		const helpers = Function("_", `${source.slice(begin, end)};
			return { inventoryBySelector, interfaceIdentity, formatInterfaceResult,
				formatEmails, formatTimestamp };`)(value => value);
		const inventory = { groups: [
			{ items: [
				{ selector: "device:eth0", label: `Office\u0000${"x".repeat(400)}`,
					live_device: `eth0\u0007${"y".repeat(400)}` },
				{ selector: "constructor", label: "prototype pollution" },
				{ selector: "__proto__", label: "prototype pollution" },
				{ selector: "device:bad/name", label: "invalid selector" }
			] },
			{ items: null }, null
		] };
		const candidates = helpers.inventoryBySelector(inventory);
		if (Object.getPrototypeOf(candidates) !== null || candidates.constructor != null ||
			candidates.__proto__ != null || candidates["device:bad/name"] != null ||
			!candidates["device:eth0"])
			throw new Error("interface candidate map must be prototype-safe and selector-bounded");
		const identity = helpers.interfaceIdentity(
			{ interface_selector: "device:eth0" },
			{ label: `Fallback\u0001${"z".repeat(400)}`, live_device: { secret: true } },
			candidates);
		if (/[\x00-\x1f\x7f]/.test(identity) || identity.length > 790 ||
			identity.includes("[object Object]") || !identity.includes("device:eth0"))
			throw new Error("interface identity must use bounded normalized scalar text");
		const result = helpers.formatInterfaceResult({
			ok: false, reason: "carrier_lost",
			summary: `carrier unavailable\u0000${"s".repeat(400)}`,
			evidence: {
				operstate: `down\u0007${"o".repeat(400)}`, carrier: false,
				radio_up: { secret: "must not render" }, present: true,
				secret: "must not render"
			}
		});
		if (!result.startsWith("Carrier lost; ") || /[\x00-\x1f\x7f]/.test(result) ||
			result.length > 600 || result.includes("secret") ||
			result.includes("radio_up") || !result.includes("carrier=false") ||
			!result.includes("present=true"))
			throw new Error("interface result must render only bounded fixed evidence fields");
		if (helpers.formatEmails(4.9, 5) !== "4 / 5" ||
			helpers.formatEmails(-1, 1001) !== "0 / 1" ||
			helpers.formatEmails(Infinity, "5") !== "0 / 5")
			throw new Error("email sent/cap values must enforce numeric bounds");
		if (helpers.formatTimestamp(NaN, "-") !== "-" ||
			helpers.formatTimestamp(253402300800, "-") !== "-")
			throw new Error("status timestamps must enforce numeric bounds");
		if (source.includes("innerHTML"))
			throw new Error("interface status must not render raw HTML");
	' "$status" || fail=1

	node -e '
		const source = require("fs").readFileSync(process.argv[1], "utf8");
		const refresh = source.slice(source.indexOf("function refreshStatus"),
			source.indexOf("\n\nfunction handleCheckNow"));
		const load = source.slice(source.indexOf("\tload()"), source.indexOf("\n\n\trender(data)"));
		if (!refresh.includes("Promise.all([") || !refresh.includes("callStatus()") ||
			!refresh.includes("callInterfaces()") || !refresh.includes("const status = data[0]") ||
			!refresh.includes("inventoryBySelector(data[1])") ||
			!source.includes("L.resolveDefault(callInterfaces(), { groups: [], errors: [ '"'"'unavailable'"'"' ] })"))
			throw new Error("status refresh must safely load status and interface inventory together");
		if (!load.includes("uci.load('"'"'netwatch'"'"')") || !load.includes("callStatus()") ||
			!load.includes("callInterfaces()") || !source.includes("inventoryBySelector(data[2])"))
			throw new Error("initial status load must include the sanitized interface inventory");
		const declaration = source.slice(source.indexOf("const callInterfaces"),
			source.indexOf("const callCheck"));
		if (!/\breject\s*:\s*true\b/.test(declaration))
			throw new Error("interface inventory RPC failures must reject into the safe fallback");
	' "$status" || fail=1

	diagnostics="$root/packages/netwatch/netwatch/files/usr/share/netwatch/diagnostics.uc"
	for declaration in \
		"link: '/sbin/ip'" \
		"iwinfo: '/usr/bin/iwinfo'" \
		"logread: '/sbin/logread'"
	do
		if ! grep -Fq -- "$declaration" "$diagnostics"; then
			echo "missing fixed diagnostic command gate: $declaration" >&2
			fail=1
		fi
	done

	node -e '
		const source = require("fs").readFileSync(process.argv[1], "utf8");
		const validator = source.indexOf("function valid_command(name, command)");
		const adapter = source.indexOf("export function command_output_with(name, command, deps)");
		const end = source.indexOf("\n\nfunction command_output", adapter);
		if (validator < 0 || adapter < 0 || end < 0 || validator > adapter)
			throw new Error("unable to isolate fixed diagnostic command boundary");
		const validation = source.slice(validator, adapter);
		const body = source.slice(adapter, end);
		if (!validation.includes("command == ") ||
			!validation.includes("/sbin/logread 2>&1") ||
			!validation.includes("/^\\/sbin\\/ip -details address show dev ") ||
			!validation.includes("/^\\/usr\\/bin\\/iwinfo ") ||
			!validation.includes("return safe_device_name(parsed[1])"))
			throw new Error("diagnostic commands must use exact fixed templates and safe device names");
		const gate = body.indexOf("if (!path || !valid_command(name, command)) return null;");
		const stat = body.indexOf("deps.stat(path)", gate);
		const popen = body.indexOf("deps.popen(command,", stat);
		if (gate < 0 || stat < 0 || popen < 0 || !(gate < stat && stat < popen))
			throw new Error("diagnostic command validation and path existence must precede process start");
	' "$diagnostics" || fail=1

	if grep -ERin --exclude='diagnostics.uc' \
		'Diagnostic collection incomplete|Recent relevant logs' \
		"$root/packages/netwatch/netwatch/files/usr/share/netwatch/store.uc" \
		"$root/packages/netwatch/luci-app-netwatch/htdocs"; then
		echo 'full diagnostics escaped the email-only boundary' >&2
		fail=1
	fi

	if grep -Ein 'key|password|passphrase|radius_secret|smtp' \
		"$root/packages/netwatch/netwatch/files/usr/share/netwatch/interfaces.uc" | \
		grep -Ev 'SAFE_|secret|allowlist|redact'; then
		echo 'inventory module contains an unreviewed secret-bearing field' >&2
		fail=1
	fi

	node -e '
		const source = require("fs").readFileSync(process.argv[1], "utf8");
		const begin = source.indexOf("function addLeaseChoice");
		const end = source.indexOf("\n\nfunction cleanChoiceText", begin);
		if (begin < 0 || end < 0)
			throw new Error("unable to load DHCP lease choice helpers");
		const helpers = Function(`${source.slice(begin, end)}; return { addLeaseChoices };`)();
		const choices = [];
		helpers.addLeaseChoices({ value: address => choices.push(address) }, {
			dhcp_leases: [ { ipaddr: "192.0.2.10" } ],
			dhcp6_leases: [ {
				ip6addr: "2001:db8::10/128",
				ip6addrs: [ "2001:db8::20/128", "2001:db8::10/128" ]
			} ]
		});
		const expected = [ "192.0.2.10", "2001:db8::10", "2001:db8::20" ];
		if (JSON.stringify(choices) !== JSON.stringify(expected))
			throw new Error(`DHCP choices must be unique host addresses without CIDR prefixes: ${JSON.stringify(choices)}`);
		if (!source.includes(`target.datatype = '"'"'or(hostname,ipaddr("nomask"))'"'"';`))
			throw new Error("manual targets must reject IP prefix notation");
		const target = source.slice(source.indexOf("const target ="),
			source.indexOf("\n\n\to = s.option(GroupedInterfaceValue"));
		if (!target.includes("addLeaseChoices(target, leaseInfo)") ||
			!target.includes("target.depends('"'"'type'"'"', '"'"'ping'"'"')") ||
			!target.includes("target.depends('"'"'type'"'"', '"'"'tcp'"'"')"))
			throw new Error("manual and DHCP host targets must remain available only for ping and TCP");
	' "$monitors" || fail=1

	node -e '
		const source = require("fs").readFileSync(process.argv[1], "utf8");
		const clean = source.indexOf("function cleanChoiceText");
		const begin = source.indexOf("function normalizeInterfaceGroups");
		const end = source.indexOf("\n\nconst GroupedInterfaceValue", begin);
		if (clean < 0 || begin < 0 || end < 0 || clean > begin)
			throw new Error("unable to load interface choice helper");
		String.prototype.format = function(...values) {
			let index = 0;
			return this.replace(/%s/g, () => String(values[index++]));
		};
		const normalizeInterfaceGroups = Function("_",
			`const INTERFACE_GROUP_LABELS = {
				"networks": "OpenWrt networks", "devices": "Linux devices",
				"wifi-radios": "Wi-Fi radios", "wifi-aps": "Wi-Fi APs / SSIDs"
			}; ${source.slice(clean, end)}; return normalizeInterfaceGroups;`
		)(value => value);
		const groups = normalizeInterfaceGroups({ groups: [ {
			id: "wifi-aps", label: "RPC supplied group label", items: [
				{ selector: "wifi-iface:office0", label: "AP: Office — radio0 / office0", state: "up" },
				{ selector: "wifi-iface:office1", label: "AP: Office — radio1 / office1", state: "disabled" },
				{ selector: "wifi-iface:office0", label: "duplicate selector", state: "down" },
				{ selector: "wifi-iface:bad/name", label: "invalid selector", state: "up" }
			]
		}, {
			id: "unknown", label: "Untrusted group", items: [
				{ selector: "device:eth9", label: "must not appear", state: "up" }
			]
		}, {
			id: "constructor", label: "Inherited object key", items: [
				{ selector: "network:prototype", label: "must not inherit", state: "up" }
			]
		}, {
			id: "devices", label: "Ignored remote title", items: [
				{ selector: "device:eth9", label: `eth9\u0000${"x".repeat(600)}`, state: "absent\u0007" }
			]
		} ], errors: [] }, [ "wifi-iface:removed" ]);
		if (groups.length !== 3 || groups[0].items.length !== 2 ||
			groups[0].label !== "Wi-Fi APs / SSIDs" ||
			groups[1].label !== "Linux devices" ||
			groups[1].items.length !== 1 || groups[1].items[0].label.length > 523 ||
			/[\x00-\x1f\x7f]/.test(groups[1].items[0].label) ||
			groups[2].items[0].selector !== "wifi-iface:removed" ||
			!groups[2].items[0].label.includes("Missing:"))
			throw new Error("custom, duplicate, disabled, missing, or sanitized choices were not preserved");
		if (groups.some(group => group.items.some(item => item.selector === "wifi-iface:bad/name" ||
			item.label.includes("must not appear") || item.label.includes("must not inherit") ||
			item.label.includes("duplicate selector"))))
			throw new Error("invalid, unknown-group, or duplicate RPC choices were accepted");
		if (source.includes("innerHTML") || /interface_selector[^;\n]*editable/.test(source))
			throw new Error("interface choices must use safe DOM construction without custom entry");
	' "$monitors" || fail=1

	for declaration in \
		"form.GridSection, 'monitor'" \
		's.anonymous = false;' \
		's.addremove = true;' \
		"object: 'luci-rpc', method: 'getDHCPLeases', expect: { '': {} }" \
		'dhcp_leases' \
		'dhcp6_leases' \
		'ipaddr' \
		'ip6addr' \
		'ip6addrs' \
		"object: 'netwatch', method: 'interfaces', expect: { '': {} }" \
		"o.value('interface', _('Interface state'))" \
		"form.ListValue.extend" \
		"GroupedInterfaceValue, 'interface_selector'" \
		"o.depends('type', 'interface')" \
		"Missing: %s" \
		"E('optgroup'" \
		"form.Value, 'target'" \
		"range(5,86400)" \
		"range(1,60)" \
		"range(1,100)" \
		"range(1,20)" \
		"range(0,100)" \
		"range(1,60000)" \
		"range(1,65535)" \
		"range(1,1000)" \
		"form.Value, 'recipients'" \
		"form.Flag, 'recovery_email'"
	do
		if ! grep -Fq -- "$declaration" "$monitors"; then
			echo "missing monitor view declaration: $declaration" >&2
			fail=1
		fi
	done

	for option in \
		"o.value('0', _('Immediately'))" \
		"o.value('300', _('After 5 minutes'))" \
		"o.value('600', _('After 10 minutes'))" \
		"o.value('900', _('After 15 minutes'))" \
		"o.value('1800', _('After 30 minutes'))" \
		"o.value('3600', _('After 1 hour'))" \
		"o.value('0', _('One time'))" \
		"o.value('600', _('Every 10 minutes'))" \
		"o.value('1800', _('Every 30 minutes'))" \
		"o.value('3600', _('Every hour'))"
	do
		if ! grep -Fq -- "$option" "$monitors"; then
			echo "missing monitor schedule option: $option" >&2
			fail=1
		fi
	done

	for declaration in \
		"form.NamedSection, 'main', 'netwatch'" \
		"form.NamedSection, 'smtp', 'smtp'" \
		"form.Value, 'server'" \
		"form.Value, 'port'" \
		"form.ListValue, 'tls'" \
		"form.Value, 'from'" \
		"form.Value, 'recipients'" \
		"form.Value, 'mail_retry_backoff'" \
		"form.Value, 'password'" \
		'o.password = true;' \
		"form.Flag, '_clear_password'" \
		"object: 'netwatch', method: 'test_email', params: [ 'recipient' ]" \
		'm.save(null, true)' \
		'uci.apply()' \
		'callTestEmail(recipient)' \
		"classList.add('spinning')" \
		'button.disabled = true;'
	do
		if ! grep -Fq -- "$declaration" "$email"; then
			echo "missing email view declaration: $declaration" >&2
			fail=1
		fi
	done

	node -e '
		const source = require("fs").readFileSync(process.argv[1], "utf8");
		const handler = source.indexOf("o.onclick = function(ev, sectionId)");
		const guard = source.indexOf("if (testEmailInFlight)", handler);
		const claim = source.indexOf("testEmailInFlight = true;", guard);
		const firstBusy = source.indexOf("setTestEmailBusy(m, true);", claim);
		const save = source.indexOf("m.save(null, true)", firstBusy);
		const secondBusy = source.indexOf("setTestEmailBusy(m, true);", save);
		const apply = source.indexOf("uci.apply()", secondBusy);
		const send = source.indexOf("callTestEmail(recipient)", apply);
		const release = source.indexOf("testEmailInFlight = false;", send);
		const clearBusy = source.indexOf("setTestEmailBusy(m, false);", release);
		if (!source.includes("let testEmailInFlight = false;") ||
			!source.includes("map.findElement('"'"'data-name'"'"', '"'"'_test_email'"'"')") ||
			![ handler, guard, claim, firstBusy, save, secondBusy, apply, send, release, clearBusy ].every(pos => pos >= 0) ||
			!(handler < guard && guard < claim && claim < firstBusy && firstBusy < save &&
				save < secondBusy && secondBusy < apply && apply < send && send < release && release < clearBusy))
			throw new Error("test email action must stay guarded and visibly busy across the save rerender and apply/send chain");
		if (source.includes("const button = ev.currentTarget") || source.includes("m.save()"))
			throw new Error("test email action must not rely on a detached event target or non-silent Map.save");
	' "$email" || fail=1

	if grep -Eq 'callTestEmail\([^)]*(password|smtp|config)' "$email"; then
		echo 'test email RPC receives SMTP configuration or password' >&2
		fail=1
	fi

	if grep -Eq 'addNotification\([^;]*(err(or)?[.]|response[.]|result[.]error)' "$email"; then
		echo 'test email notification exposes a remote error string' >&2
		fail=1
	fi
fi

exit "$fail"
