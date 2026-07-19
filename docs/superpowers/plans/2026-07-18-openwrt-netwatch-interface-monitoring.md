# OpenWrt Netwatch Interface Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add logical-network, Linux-device, Wi-Fi-radio, and individual AP/SSID monitoring with dropdown selection, specific failure reasons, fresh redacted diagnostics on every due failure email, and a signed `1.1.0-r1` public-feed upgrade.

**Architecture:** Keep the current ucode daemon as the only scheduler and incident owner. Add an inventory module that merges UCI, ubus, and sysfs; a pure health evaluator used by the existing probe task; and a bounded diagnostic collector invoked only when an interface failure email is due. LuCI consumes one new read-only inventory RPC and continues to join UCI monitor configuration with the bounded daemon status response.

**Tech Stack:** OpenWrt 25.12.5 x86/64 SDK, ucode, `ucode-mod-fs`, `ucode-mod-ubus`, `ucode-mod-uci`, `ucode-mod-uloop`, netifd ubus objects, sysfs, BusyBox networking/log tools, modern LuCI JavaScript, POSIX shell, apk-tools 3.0.5, Docker, Git, GitHub raw hosting.

## Global Constraints

- Target OpenWrt `25.12.5`, `x86/64`, `x86_64`; both package manifests remain `noarch`.
- Preserve ping, TCP, SMTP, notification scheduling, retry, cap, and recovery behavior.
- Interface selectors are exactly `network:<id>`, `device:<id>`, `wifi-radio:<id>`, or `wifi-iface:<id>` and are never generic command input.
- List live objects and configured objects that are absent or administratively disabled.
- Use configured SSIDs as AP labels and disambiguate them with radio, UCI section, and live device.
- Collect a new diagnostic report for every due interface failure email, including repeats.
- Diagnostic collection has a 15-second hard deadline, a 64 KiB report limit, and at most 200 relevant log lines.
- Diagnostic failure never suppresses the alert; the email must identify incomplete collection.
- Never expose Wi-Fi keys, passphrases, RADIUS secrets, SMTP credentials, private keys, or unrestricted UCI/log data.
- Do not persist diagnostic reports to status files or flash.
- Release `netwatch` and `luci-app-netwatch` as `1.1.0-r1` through the unchanged `feed/x86_64/packages.adb` URL and existing signing key.
- Use `git --git-dir=work/git-metadata --work-tree=.` for every repository command.
- Use a pristine APK copy for each signing attempt; invoke `adbsign` exactly once per copy, then run strict verification.
- Do not track or publish the private signing key or any `.DS_Store` file.
- Every production behavior starts with an observed failing test.

## File Structure

### New runtime modules

- `packages/netwatch/netwatch/files/usr/share/netwatch/interfaces.uc`: selector parsing, safe UCI/ubus/sysfs snapshot collection, normalized grouped inventory, friendly labels, and source-error normalization.
- `packages/netwatch/netwatch/files/usr/share/netwatch/interface_probe.uc`: pure per-kind health evaluation and the synchronous interface probe called inside the existing task worker.
- `packages/netwatch/netwatch/files/usr/share/netwatch/diagnostics.uc`: safe field selection, text redaction, log filtering, report bounds, and the asynchronous 15-second diagnostic task wrapper.

### New unit suites

- `tests/unit/interfaces_test.uc`: selector/inventory merging, disabled/absent candidates, custom and duplicate SSIDs, safe source failures.
- `tests/unit/interface_probe_test.uc`: all healthy states, all normalized failure reasons, precedence, and indeterminate-source behavior.
- `tests/unit/diagnostics_test.uc`: allowlists, redaction, log/report bounds, partial failure, total failure, timeout, and callback-once behavior.
- `tests/unit/store_test.uc`: last-transition publication and proof that diagnostics are not persisted.

### Modified runtime and UI files

- `packages/netwatch/netwatch/files/usr/share/netwatch/config.uc`: accept `interface` and validate `interface_selector` conditionally.
- `packages/netwatch/netwatch/files/usr/share/netwatch/probe.uc`: dispatch the interface evaluator through the existing worker and timeout path.
- `packages/netwatch/netwatch/files/usr/share/netwatch/state.uc`: record transition time and retain the successful recovery snapshot in `recovery_pending`.
- `packages/netwatch/netwatch/files/usr/share/netwatch/message.uc`: render interface identity, evidence, diagnostics, and concise recovery state.
- `packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc`: expose inventory RPC and collect diagnostics immediately before interface failure delivery.
- `packages/netwatch/netwatch/files/usr/share/netwatch/store.uc`: publish `last_transition` while continuing to omit full diagnostics.
- `packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/monitors.js`: interface test option and grouped selector.
- `packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/status.js`: interface identity, reason, compact state, transition, and email-cap display.
- `packages/netwatch/luci-app-netwatch/root/usr/share/rpcd/acl.d/luci-app-netwatch.json`: read-only `interfaces` method grant.
- `packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot`: exact translation literals from all views.
- `tests/static.sh`: module, ACL, RPC, LuCI behavior, redaction, and package safety assertions.

### Release files

- `packages/netwatch/netwatch/Makefile`
- `packages/netwatch/luci-app-netwatch/Makefile`
- `README.md`
- `scripts/package-output.sh`
- `scripts/verify-artifacts.sh`
- `tests/package-output_test.sh`
- `tests/feed_test.sh`
- `feed/x86_64/netwatch-1.1.0-r1.apk`
- `feed/x86_64/luci-app-netwatch-1.1.0-r1.apk`
- `feed/x86_64/packages.adb`

---

### Task 1: Interface Selector Configuration

**Files:**
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/config.uc:101-187`
- Modify: `tests/unit/config_test.uc:1-87`

**Interfaces:**
- Consumes: Existing `normalize_monitor(id, raw)` UCI normalization.
- Produces: `valid_interface_selector(value) -> bool`; normalized interface monitors with `type: 'interface'` and `interface_selector: string`.

- [ ] **Step 1: Write failing selector and conditional-validation tests**

Add `valid_interface_selector` to the import and append these cases:

```ucode
truthy(valid_interface_selector('network:wan'), 'logical network selector accepted');
truthy(valid_interface_selector('device:br-lan'), 'Linux device selector accepted');
truthy(valid_interface_selector('wifi-radio:radio0'), 'radio selector accepted');
truthy(valid_interface_selector('wifi-iface:guest_5g'), 'AP selector accepted');
equal(valid_interface_selector('device:-eth0'), false, 'option-like device rejected');
equal(valid_interface_selector('device:eth0/reboot'), false, 'path syntax rejected');
equal(valid_interface_selector('wifi-iface:guest\nkey'), false, 'control character rejected');
equal(valid_interface_selector('other:wan'), false, 'unknown selector kind rejected');

let interface_monitor = normalize_monitor('wifi_watch', {
	type: 'interface', interface_selector: 'wifi-iface:guest_5g'
});
truthy(interface_monitor.ok, 'interface monitor does not require host target');
equal(interface_monitor.value.target, '', 'interface monitor has no host target');
equal(interface_monitor.value.interface_selector, 'wifi-iface:guest_5g',
	'interface selector normalized');
equal(normalize_monitor('missing', { type: 'interface' }).ok, false,
	'interface selector required');
equal(normalize_monitor('ping', { type: 'ping', target: 'router.example' }).ok, true,
	'ping compatibility retained');
equal(normalize_monitor('tcp', { type: 'tcp', target: 'router.example', port: '443' }).ok, true,
	'TCP compatibility retained');
```

- [ ] **Step 2: Run the focused suite and observe the failure**

Run:

```sh
./tests/run-unit.sh tests/unit/config_test.uc
```

Expected: FAIL because `valid_interface_selector` is not exported and `interface` is not an allowed monitor type.

- [ ] **Step 3: Implement strict selector parsing and type-conditional fields**

Add this export beside `valid_target()`:

```ucode
export function valid_interface_selector(value) {
	return type(value) == 'string' && length(value) <= 96 &&
		!!match(value,
			/^(network|device|wifi-radio|wifi-iface):[A-Za-z0-9_][A-Za-z0-9_.-]*$/);
};
```

Replace the unconditional target/type checks in `normalize_monitor()` with:

```ucode
let interface_selector = plain_monitor_string(raw, 'interface_selector', '', errors);

if (!(monitor_type in ['ping', 'tcp', 'interface']))
	push(errors, 'type must be ping, tcp, or interface');

if (monitor_type in ['ping', 'tcp'] && !valid_target(target))
	push(errors, 'target is invalid');

if (monitor_type == 'interface' && !valid_interface_selector(interface_selector))
	push(errors, 'interface selector is invalid');
```

Add `interface_selector` to the normalized common value and retain the existing ping/TCP branches:

```ucode
target: monitor_type == 'interface' ? '' : target,
interface_selector: monitor_type == 'interface' ? interface_selector : '',
type: monitor_type,
```

- [ ] **Step 4: Run the focused and regression suites**

Run:

```sh
./tests/run-unit.sh tests/unit/config_test.uc tests/unit/probe_test.uc
```

Expected: both suites PASS; ping and TCP tests remain unchanged.

- [ ] **Step 5: Commit the configuration contract**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  packages/netwatch/netwatch/files/usr/share/netwatch/config.uc \
  tests/unit/config_test.uc
git --git-dir=work/git-metadata --work-tree=. commit \
  -m "feat: validate interface monitor selectors"
```

### Task 2: Safe Interface Inventory

**Files:**
- Create: `packages/netwatch/netwatch/files/usr/share/netwatch/interfaces.uc`
- Create: `tests/unit/interfaces_test.uc`

**Interfaces:**
- Consumes: UCI sections, `network.interface dump`, `network.device status`, `network.wireless status`, and `/sys/class/net` names.
- Produces: `parse_interface_selector(value) -> { kind, id } | null`; `inventory_from_snapshot(snapshot) -> { groups, errors }`; `collect_interface_snapshot_with(deps) -> snapshot`; `collect_interface_inventory() -> { groups, errors }`.

- [ ] **Step 1: Write failing inventory normalization tests**

Create fixtures covering configured-but-absent objects, live-only devices, disabled radios/APs, and duplicate custom SSIDs:

```ucode
import { deep_equal, equal, truthy } from 'test';
import {
	parse_interface_selector,
	inventory_from_snapshot,
	collect_interface_snapshot_with
} from 'interfaces';

deep_equal(parse_interface_selector('wifi-iface:guest_5g'),
	{ kind: 'wifi-iface', id: 'guest_5g' }, 'selector parsed');
equal(parse_interface_selector('wifi-iface:@wifi-iface[0]'), null,
	'list-position selector rejected');

let snapshot = {
	configured: {
		networks: [
			{ id: 'lan', disabled: false, auto: true, description: 'Local network' },
			{ id: 'wan', disabled: true, auto: false }
		],
		devices: [ { name: 'br-lan', type: 'bridge' } ],
		radios: [
			{ id: 'radio0', disabled: false, band: '5g' },
			{ id: 'radio1', disabled: true, band: '2g' }
		],
		wifi_ifaces: [
			{ id: 'office0', device: 'radio0', mode: 'ap', ssid: 'Office WiFi', disabled: false },
			{ id: 'office1', device: 'radio1', mode: 'ap', ssid: 'Office WiFi', disabled: true },
			{ id: 'client0', device: 'radio0', mode: 'sta', ssid: 'Upstream', disabled: false }
		]
	},
	runtime: {
		interfaces: [
			{ interface: 'lan', up: true, available: true, device: 'br-lan' },
			{ interface: 'dmz', up: false, available: true, device: 'eth9' }
		],
		devices: {
			'br-lan': { up: true, carrier: true, present: true },
			'eth9': { up: false, carrier: false, present: true },
			'phy0-ap0': { up: true, carrier: true, present: true, operstate: 'up' },
			"eth0';reboot": { up: true, carrier: true, present: true }
		},
		wireless: {
			radio0: {
				up: true, pending: false, disabled: false,
				interfaces: [ { section: 'office0', ifname: 'phy0-ap0', config: { mode: 'ap', ssid: 'Office WiFi' } } ]
			}
		},
		sys_devices: [ 'br-lan', 'eth9', 'phy0-ap0', "eth0';reboot" ]
	},
	errors: []
};

let inventory = inventory_from_snapshot(snapshot);
equal(length(inventory.groups), 4, 'four groups returned');
equal(inventory.groups[0].id, 'networks', 'networks first');
truthy(match(sprintf('%J', inventory.groups[0].items), /network:dmz/),
	'live-only logical network included');
equal(inventory.groups[1].items[1].selector, 'device:eth9', 'live-only device included');
equal(inventory.groups[2].items[1].selector, 'wifi-radio:radio1', 'absent disabled radio included');
equal(inventory.groups[3].items[0].label,
	'AP: Office WiFi — radio0 / office0 (phy0-ap0)', 'custom SSID and live device shown');
equal(inventory.groups[3].items[1].label,
	'AP: Office WiFi — radio1 / office1', 'duplicate SSID disambiguated');
equal(length(inventory.groups[3].items), 2, 'non-AP wireless section omitted');
equal(match(sprintf('%J', inventory), /reboot/), null,
	'live names outside the selector grammar are omitted');

let calls = [];
let collected = collect_interface_snapshot_with({
	foreach: (config, section_type, callback) => {
		push(calls, `${config}:${section_type}`);
		if (config == 'wireless' && section_type == 'wifi-iface')
			callback({ '.name': 'secret_ap', device: 'radio0', mode: 'ap', ssid: 'Safe', key: 'do-not-return' });
	},
	call: (object, method) => object == 'network.device' ? {} : null,
	lsdir: (path) => [],
	readfile: (path, limit) => null
});
truthy('wireless:wifi-iface' in calls, 'wireless sections queried');
equal(match(sprintf('%J', collected), /do-not-return/), null, 'secret UCI value excluded');
truthy(length(collected.errors) >= 1, 'source failures normalized');
```

- [ ] **Step 2: Run the new suite and observe the missing module**

Run:

```sh
./tests/run-unit.sh tests/unit/interfaces_test.uc
```

Expected: FAIL because `interfaces.uc` does not exist.

- [ ] **Step 3: Implement selector parsing, safe snapshots, and four grouped inventories**

Create `interfaces.uc` with these constants and public functions:

```ucode
import * as fs from 'fs';
import * as ubus from 'ubus';
import * as uci from 'uci';

const GROUPS = [
	{ id: 'networks', label: 'OpenWrt networks', kind: 'network' },
	{ id: 'devices', label: 'Linux devices', kind: 'device' },
	{ id: 'wifi-radios', label: 'Wi-Fi radios', kind: 'wifi-radio' },
	{ id: 'wifi-aps', label: 'Wi-Fi APs / SSIDs', kind: 'wifi-iface' }
];

const SAFE_NETWORK = [ 'proto', 'device', 'ifname', 'auto', 'disabled', 'metric', 'mtu', 'description' ];
const SAFE_DEVICE = [ 'name', 'type', 'ports', 'mtu', 'macaddr', 'disabled' ];
const SAFE_RADIO = [ 'type', 'path', 'band', 'channel', 'country', 'htmode', 'disabled' ];
const SAFE_WIFI_IFACE = [ 'device', 'mode', 'ssid', 'mesh_id', 'network', 'encryption', 'disabled' ];
const SAFE_RUNTIME_INTERFACE = [
	'interface', 'up', 'pending', 'available', 'autostart', 'dynamic',
	'proto', 'device', 'l3_device', 'uptime', 'metric', 'errors',
	'ipv4-address', 'ipv6-address'
];
const SAFE_RUNTIME_DEVICE = [
	'present', 'up', 'carrier', 'operstate', 'type', 'mtu', 'macaddr',
	'rx_bytes', 'rx_packets', 'rx_errors', 'tx_bytes', 'tx_packets', 'tx_errors'
];

export function parse_interface_selector(value) {
	let parsed = type(value) == 'string' && length(value) <= 96
		? match(value,
			/^(network|device|wifi-radio|wifi-iface):([A-Za-z0-9_][A-Za-z0-9_.-]*)$/)
		: null;
	return parsed ? { kind: parsed[1], id: parsed[2] } : null;
};

function bool_value(value, fallback) {
	if (value in [ true, 1, '1', 'true', 'yes', 'on' ]) return true;
	if (value in [ false, 0, '0', 'false', 'no', 'off' ]) return false;
	return fallback;
};

function safe_string(value) {
	return type(value) == 'string'
		? substr(replace(value, /[[:cntrl:]]/g, ' '), 0, 256)
		: null;
};

function safe_identifier(value) {
	value = safe_string(value);
	return value && length(value) <= 64 &&
		match(value, /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/) ? value : null;
};

function allowlist(raw, names) {
	let output = {};
	for (let name in names)
		if (raw?.[name] != null)
			output[name] = type(raw[name]) in [ 'string', 'int', 'double', 'bool', 'array' ]
				? raw[name] : null;
	return output;
};

function normalize_flags(value) {
	if (value.disabled != null) value.disabled = bool_value(value.disabled, false);
	if (value.auto != null) value.auto = bool_value(value.auto, true);
	return value;
};

function configured_entry(raw, list, identity, fields) {
	let value = normalize_flags(allowlist(raw, fields));
	value[identity] = safe_identifier(raw?.[identity] ?? raw?.['.name']);
	if (value[identity]) push(list, value);
};

function runtime_interfaces(raw) {
	let output = [];
	for (let value in raw ?? []) {
		let safe = allowlist(value, SAFE_RUNTIME_INTERFACE);
		safe.interface = safe_identifier(value?.interface);
		safe.device = safe_identifier(value?.device);
		safe.l3_device = safe_identifier(value?.l3_device);
		if (safe.interface) push(output, safe);
	}
	return output;
};

function runtime_devices(raw) {
	let output = {};
	for (let name, value in raw ?? {}) {
		name = safe_identifier(name);
		if (name) output[name] = allowlist(value, SAFE_RUNTIME_DEVICE);
	}
	return output;
};

function runtime_wireless(raw) {
	let output = {};
	for (let radio, data in raw ?? {}) {
		radio = safe_identifier(radio);
		if (!radio) continue;
		let interfaces = [];
		for (let iface in data?.interfaces ?? []) {
			let section = safe_identifier(iface?.section);
			if (!section) continue;
			push(interfaces, {
				section,
				ifname: safe_identifier(iface?.ifname),
				config: allowlist(iface?.config ?? {}, SAFE_WIFI_IFACE)
			});
		}
		output[radio] = {
			up: data?.up === true,
			pending: data?.pending === true,
			autostart: data?.autostart !== false,
			disabled: data?.disabled === true,
			retry_setup_failed: data?.retry_setup_failed === true,
			config: allowlist(data?.config ?? {}, SAFE_RADIO),
			interfaces
		};
	}
	return output;
};

export function collect_interface_snapshot_with(deps) {
	let snapshot = {
		configured: { networks: [], devices: [], radios: [], wifi_ifaces: [] },
		runtime: { interfaces: [], devices: {}, wireless: {}, sys_devices: [] },
		errors: []
	};

	for (let source in [
		[ 'network interfaces', () => deps.foreach('network', 'interface',
			raw => configured_entry(raw, snapshot.configured.networks, 'id', SAFE_NETWORK)) ],
		[ 'network devices', () => deps.foreach('network', 'device',
			raw => configured_entry(raw, snapshot.configured.devices, 'name', SAFE_DEVICE)) ],
		[ 'wireless radios', () => deps.foreach('wireless', 'wifi-device',
			raw => configured_entry(raw, snapshot.configured.radios, 'id', SAFE_RADIO)) ],
		[ 'wireless APs', () => deps.foreach('wireless', 'wifi-iface', (raw) => {
			let entry = normalize_flags(allowlist(raw, SAFE_WIFI_IFACE));
			entry.id = safe_identifier(raw?.['.name']);
			entry.device = safe_identifier(entry.device);
			if (entry.id && entry.mode == 'ap') push(snapshot.configured.wifi_ifaces, entry);
		}) ],
		[ 'logical runtime', () => {
			let value = deps.call('network.interface', 'dump', {})?.interface;
			if (type(value) != 'array') die('unavailable');
			snapshot.runtime.interfaces = runtime_interfaces(value);
		} ],
		[ 'device runtime', () => {
			let value = deps.call('network.device', 'status', {});
			if (type(value) != 'object') die('unavailable');
			snapshot.runtime.devices = runtime_devices(value);
		} ],
		[ 'wireless runtime', () => {
			let value = deps.call('network.wireless', 'status', {});
			if (type(value) != 'object') die('unavailable');
			snapshot.runtime.wireless = runtime_wireless(value);
		} ],
		[ 'sysfs devices', () => {
			let value = deps.lsdir('/sys/class/net');
			if (type(value) != 'array') die('unavailable');
			for (let raw_name in value) {
				let name = safe_identifier(raw_name);
				if (!name) continue;
				push(snapshot.runtime.sys_devices, name);
				let device = snapshot.runtime.devices[name] ?? { present: true };
				device.present = true;
				let operstate = deps.readfile(`/sys/class/net/${name}/operstate`, 64);
				if (operstate != null) device.operstate = trim(safe_string(operstate));
				let carrier = deps.readfile(`/sys/class/net/${name}/carrier`, 16);
				if (carrier != null && trim(carrier) in [ '0', '1' ])
					device.carrier = trim(carrier) == '1';
				let mtu = deps.readfile(`/sys/class/net/${name}/mtu`, 32);
				if (mtu != null && match(trim(mtu), /^[0-9]+$/)) device.mtu = +trim(mtu);
				snapshot.runtime.devices[name] = device;
			}
		} ]
	]) {
		try { source[1](); }
		catch (error) { push(snapshot.errors, `${source[0]} unavailable`); }
	}

	return snapshot;
};
```

Complete the same file with deterministic helpers that merge by selector and emit only the public candidate fields:

```ucode
function public_candidate(selector, kind, label, configured_name, live_device,
	configured, present, enabled, state, detail) {
	return { selector, kind, label, configured_name, live_device,
		configured, present, enabled, state, detail };
};

function ap_label(ap, live_device) {
	let ssid = safe_string(ap.ssid ?? ap.mesh_id) ?? 'unnamed';
	let suffix = `${ap.device ?? 'unknown-radio'} / ${ap.id}`;
	if (live_device) suffix += ` (${live_device})`;
	return `AP: ${ssid} — ${suffix}`;
};

export function inventory_from_snapshot(snapshot) {
	let groups = GROUPS.map(group => ({ id: group.id, label: group.label, items: [] }));
	let seen = {};
	let logical = {};
	let devices = snapshot?.runtime?.devices ?? {};
	let wireless = snapshot?.runtime?.wireless ?? {};

	for (let runtime in snapshot?.runtime?.interfaces ?? [])
		if (type(runtime?.interface) == 'string') logical[runtime.interface] = runtime;

	for (let configured in snapshot?.configured?.networks ?? []) {
		let runtime = logical[configured.id];
		let selector = `network:${configured.id}`;
		if (!parse_interface_selector(selector)) continue;
		push(groups[0].items, public_candidate(selector, 'network',
			configured.description ? `${configured.id} — ${configured.description}` : configured.id,
			configured.id, runtime?.device ?? null, true, !!runtime,
			!configured.disabled && configured.auto !== false,
			runtime?.up === true ? 'up' : configured.disabled || configured.auto === false ? 'disabled' : 'down',
			runtime?.proto ?? configured.proto ?? null));
		seen[selector] = true;
	}

	for (let id, runtime in logical) {
		let selector = `network:${id}`;
		if (!parse_interface_selector(selector)) continue;
		if (seen[selector]) continue;
		push(groups[0].items, public_candidate(selector, 'network', id, id,
			runtime?.device ?? null, false, true, runtime?.autostart !== false,
			runtime?.up === true ? 'up' : runtime?.available === false ? 'unavailable' : 'down',
			runtime?.proto ?? null));
		seen[selector] = true;
	}

	for (let configured in snapshot?.configured?.devices ?? []) {
		let selector = `device:${configured.name}`;
		if (!parse_interface_selector(selector)) continue;
		let present = configured.name in (snapshot?.runtime?.sys_devices ?? []);
		push(groups[1].items, public_candidate(selector, 'device', configured.name,
			configured.name, present ? configured.name : null, true, present,
			!configured.disabled,
			configured.disabled ? 'disabled' : devices[configured.name]?.up === true ? 'up' : present ? 'down' : 'absent',
			configured.type ?? devices[configured.name]?.type ?? null));
		seen[selector] = true;
	}

	for (let name in snapshot?.runtime?.sys_devices ?? []) {
		let selector = `device:${name}`;
		if (!parse_interface_selector(selector)) continue;
		if (seen[selector]) continue;
		push(groups[1].items, public_candidate(selector, 'device', name, name, name,
			false, true, true, devices[name]?.up === true ? 'up' : 'down', devices[name]?.type ?? null));
		seen[selector] = true;
	}

	for (let configured in snapshot?.configured?.radios ?? []) {
		let runtime = wireless[configured.id];
		let selector = `wifi-radio:${configured.id}`;
		if (!parse_interface_selector(selector)) continue;
		push(groups[2].items, public_candidate(selector, 'wifi-radio',
			configured.band ? `${configured.id} — ${configured.band}` : configured.id,
			configured.id, null, true, !!runtime, !configured.disabled,
			configured.disabled ? 'disabled' : runtime?.up === true ? 'up' : 'down',
			configured.htmode ?? null));
		seen[selector] = true;
	}

	for (let ap in snapshot?.configured?.wifi_ifaces ?? []) {
		let runtime_radio = wireless[ap.device];
		let runtime_iface = null;
		for (let iface in runtime_radio?.interfaces ?? [])
			if (iface.section == ap.id) runtime_iface = iface;
		let selector = `wifi-iface:${ap.id}`;
		if (!parse_interface_selector(selector)) continue;
		push(groups[3].items, public_candidate(selector, 'wifi-iface',
			ap_label(ap, runtime_iface?.ifname), ap.id, runtime_iface?.ifname ?? null,
			true, !!runtime_iface, !ap.disabled && !runtime_radio?.disabled,
			ap.disabled || runtime_radio?.disabled ? 'disabled' : runtime_iface ? 'up' : 'absent',
			ap.device ?? null));
		seen[selector] = true;
	}

	for (let group in groups)
		group.items = sort(group.items, (a, b) => a.label < b.label ? -1 : a.label > b.label ? 1 : 0);

	return { groups, errors: snapshot?.errors ?? [] };
};

export function collect_interface_inventory() {
	let cursor = uci.cursor();
	let connection = ubus.connect();
	if (!connection) return { groups: GROUPS.map(g => ({ id: g.id, label: g.label, items: [] })), errors: [ 'ubus unavailable' ] };
	let snapshot = collect_interface_snapshot_with({
		foreach: (config, section_type, callback) => cursor.foreach(config, section_type, callback),
		call: (object, method, args) => connection.call(object, method, args),
		lsdir: (path) => fs.lsdir(path),
		readfile: (path, limit) => fs.readfile(path, limit)
	});
	return inventory_from_snapshot(snapshot);
};
```

`runtime_interfaces()`, `runtime_devices()`, and `runtime_wireless()` are the only paths from ubus responses into the snapshot. They omit arbitrary nested `data` objects and secret-bearing wireless fields before inventory, probe, diagnostic, or status code can consume them.

- [ ] **Step 4: Run inventory tests and compile the new module**

Run:

```sh
./tests/run-unit.sh tests/unit/interfaces_test.uc
./tests/static.sh
```

Expected: inventory suite PASS; static ucode compilation PASS after `tests/static.sh` is taught to require the new module in Task 8. If static currently has no new-module assertion, its existing wildcard compilation still must PASS.

- [ ] **Step 5: Commit the safe inventory boundary**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  packages/netwatch/netwatch/files/usr/share/netwatch/interfaces.uc \
  tests/unit/interfaces_test.uc
git --git-dir=work/git-metadata --work-tree=. commit \
  -m "feat: inventory network and wireless interfaces"
```

### Task 3: Interface Health Evaluation and Probe Dispatch

**Files:**
- Create: `packages/netwatch/netwatch/files/usr/share/netwatch/interface_probe.uc`
- Create: `tests/unit/interface_probe_test.uc`
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/probe.uc:1-183`
- Modify: `tests/unit/probe_test.uc:1-135`

**Interfaces:**
- Consumes: `parse_interface_selector()` and the safe snapshot shape from Task 2.
- Produces: `evaluate_interface(selector, snapshot, observed_at) -> result`; `run_interface_with(monitor, deps) -> result`; probe dispatch for `type: 'interface'`.

- [ ] **Step 1: Write a reason-precedence matrix that initially fails**

Create table-driven tests with one assertion per public reason:

```ucode
import { equal, truthy } from 'test';
import { evaluate_interface, run_interface_with } from 'interface_probe';

function result(selector, snapshot) {
	return evaluate_interface(selector, snapshot, 1700000000);
};

let base = {
	configured: {
		networks: [ { id: 'wan', disabled: false, auto: true } ],
		devices: [ { name: 'eth0', disabled: false } ],
		radios: [ { id: 'radio0', disabled: false } ],
		wifi_ifaces: [ { id: 'office', device: 'radio0', mode: 'ap', ssid: 'Office', disabled: false } ]
	},
	runtime: {
		interfaces: [ { interface: 'wan', up: true, available: true, device: 'eth0' } ],
		devices: {
			eth0: { present: true, up: true, carrier: true, operstate: 'up' },
			'phy0-ap0': { present: true, up: true, carrier: true, operstate: 'up' }
		},
		wireless: { radio0: { up: true, pending: false, disabled: false,
			retry_setup_failed: false,
			interfaces: [ { section: 'office', ifname: 'phy0-ap0', config: { mode: 'ap', ssid: 'Office' } } ] } },
		sys_devices: [ 'eth0', 'phy0-ap0' ]
	},
	errors: []
};

truthy(result('network:wan', base).ok, 'logical network healthy');
truthy(result('device:eth0', base).ok, 'Linux device healthy');
truthy(result('wifi-radio:radio0', base).ok, 'radio healthy');
truthy(result('wifi-iface:office', base).ok, 'AP healthy');

equal(result('network:wan', { ...base, configured: { ...base.configured,
	networks: [ { id: 'wan', disabled: true, auto: false } ] } }).reason,
	'administratively_disabled', 'administrative state has precedence');
equal(result('network:missing', base).reason, 'interface_absent', 'missing logical interface');
equal(result('network:wan', { ...base, runtime: { ...base.runtime,
	interfaces: [ { interface: 'wan', up: false, available: false } ] } }).reason,
	'unavailable', 'logical network unavailable');
equal(result('device:eth0', { ...base, runtime: { ...base.runtime,
	devices: { eth0: { present: true, up: false, carrier: true } } } }).reason,
	'link_down', 'device link down');
equal(result('device:eth0', { ...base, runtime: { ...base.runtime,
	devices: { eth0: { present: true, up: true, carrier: false } } } }).reason,
	'carrier_lost', 'carrier loss detected');
equal(result('wifi-radio:radio0', { ...base, runtime: { ...base.runtime,
	wireless: { radio0: { up: false, pending: false, disabled: false, retry_setup_failed: false, interfaces: [] } } } }).reason,
	'wireless_radio_down', 'radio down detected');
equal(result('wifi-iface:office', { ...base, runtime: { ...base.runtime,
	wireless: { radio0: { up: true, pending: false, disabled: false, retry_setup_failed: false, interfaces: [] } } } }).reason,
	'wireless_ap_down', 'AP down detected');
equal(result('wifi-iface:office', { ...base, runtime: { ...base.runtime,
	devices: { eth0: base.runtime.devices.eth0 }, sys_devices: [ 'eth0' ] } }).reason,
	'wireless_ap_down', 'AP live device disappearance detected');
equal(result('wifi-radio:radio0', { ...base, runtime: { ...base.runtime,
	wireless: { radio0: { up: false, pending: false, disabled: false, retry_setup_failed: true, interfaces: [] } } } }).reason,
	'wireless_initialization_failed', 'wireless initialization failure detected');
equal(result('device:eth0', { ...base, runtime: { ...base.runtime, devices: {}, sys_devices: [] },
	errors: [ 'device runtime unavailable', 'sysfs devices unavailable' ] }).reason,
	'status_unavailable', 'indeterminate source failure is not absence');

let called = 0;
let run = run_interface_with({ interface_selector: 'device:eth0' }, {
	snapshot: () => { called++; return base; },
	clock: () => 1700000000
});
equal(called, 1, 'fresh snapshot collected once per probe');
truthy(run.ok, 'synchronous worker probe returns health result');
```

- [ ] **Step 2: Run the suite and observe the missing evaluator**

```sh
./tests/run-unit.sh tests/unit/interface_probe_test.uc
```

Expected: FAIL because `interface_probe.uc` does not exist.

- [ ] **Step 3: Implement per-kind evaluation with compact evidence**

Create `interface_probe.uc` with these result and lookup rules:

```ucode
import { parse_interface_selector, collect_interface_snapshot_with } from 'interfaces';
import * as fs from 'fs';
import * as ubus from 'ubus';
import * as uci from 'uci';

function answer(ok, reason, summary, parsed, candidate, observed_at, evidence) {
	return {
		ok, reason, summary,
		selector: `${parsed.kind}:${parsed.id}`,
		kind: parsed.kind,
		configured_name: candidate?.configured_name ?? parsed.id,
		label: candidate?.label ?? parsed.id,
		live_device: candidate?.live_device ?? null,
		observed_at,
		evidence: evidence ?? {}
	};
};

function configured(snapshot, collection, field, id) {
	for (let value in snapshot?.configured?.[collection] ?? [])
		if (value?.[field] == id) return value;
	return null;
};

function logical_runtime(snapshot, id) {
	for (let value in snapshot?.runtime?.interfaces ?? [])
		if (value?.interface == id) return value;
	return null;
};

function wireless_iface(snapshot, radio_id, section_id) {
	for (let value in snapshot?.runtime?.wireless?.[radio_id]?.interfaces ?? [])
		if (value?.section == section_id) return value;
	return null;
};

function source_failed(snapshot, label) {
	for (let error in snapshot?.errors ?? [])
		if (index(error, label) == 0) return true;
	return false;
};

function operstate_down(value) {
	return value in [ 'down', 'lowerlayerdown', 'notpresent' ];
};

export function evaluate_interface(selector, snapshot, observed_at) {
	let parsed = parse_interface_selector(selector);
	if (!parsed) return { ok: false, reason: 'status_unavailable', summary: 'interface selector is invalid',
		selector, kind: null, configured_name: null, label: selector, live_device: null,
		observed_at, evidence: {} };

	if (parsed.kind == 'network') {
		let config = configured(snapshot, 'networks', 'id', parsed.id);
		let runtime = logical_runtime(snapshot, parsed.id);
		let candidate = { configured_name: parsed.id, label: config?.description ?? parsed.id,
			live_device: runtime?.device ?? null };
		let evidence = { up: runtime?.up ?? null, available: runtime?.available ?? null,
			auto: config?.auto ?? null, device: runtime?.device ?? null, proto: runtime?.proto ?? config?.proto ?? null };
		if (config?.disabled === true || config?.auto === false)
			return answer(false, 'administratively_disabled', 'logical network is disabled', parsed, candidate, observed_at, evidence);
		if (!runtime)
			return answer(false, source_failed(snapshot, 'logical runtime') ? 'status_unavailable' : 'interface_absent',
				'logical network has no runtime state', parsed, candidate, observed_at, evidence);
		if (runtime.available === false)
			return answer(false, 'unavailable', 'netifd reports the logical network unavailable', parsed, candidate, observed_at, evidence);
		if (runtime.up !== true)
			return answer(false, 'link_down', 'logical network is not up', parsed, candidate, observed_at, evidence);
		return answer(true, null, 'logical network is up', parsed, candidate, observed_at, evidence);
	}

	if (parsed.kind == 'device') {
		let config = configured(snapshot, 'devices', 'name', parsed.id);
		let runtime = snapshot?.runtime?.devices?.[parsed.id];
		let present = parsed.id in (snapshot?.runtime?.sys_devices ?? []) || runtime?.present === true;
		let candidate = { configured_name: parsed.id, label: parsed.id, live_device: present ? parsed.id : null };
		let evidence = { present, up: runtime?.up ?? null, carrier: runtime?.carrier ?? null,
			operstate: runtime?.operstate ?? null, mtu: runtime?.mtu ?? null };
		if (config?.disabled === true)
			return answer(false, 'administratively_disabled', 'device is disabled in configuration', parsed, candidate, observed_at, evidence);
		if (!present)
			return answer(false,
				source_failed(snapshot, 'device runtime') && source_failed(snapshot, 'sysfs devices')
					? 'status_unavailable' : 'interface_absent',
				'device is not present', parsed, candidate, observed_at, evidence);
		if (operstate_down(runtime?.operstate) ||
			(runtime?.up === false && runtime?.operstate != 'up'))
			return answer(false, 'link_down', 'device is not operationally up', parsed, candidate, observed_at, evidence);
		if (runtime?.carrier === false)
			return answer(false, 'carrier_lost', 'device reports no carrier', parsed, candidate, observed_at, evidence);
		if (runtime?.up !== true && runtime?.operstate != 'up' && runtime?.carrier !== true)
			return answer(false, 'status_unavailable', 'device operational state is indeterminate', parsed, candidate, observed_at, evidence);
		return answer(true, null, 'device is operationally up', parsed, candidate, observed_at, evidence);
	}

	if (parsed.kind == 'wifi-radio') {
		let config = configured(snapshot, 'radios', 'id', parsed.id);
		let runtime = snapshot?.runtime?.wireless?.[parsed.id];
		let candidate = { configured_name: parsed.id, label: parsed.id, live_device: null };
		let evidence = { up: runtime?.up ?? null, pending: runtime?.pending ?? null,
			disabled: runtime?.disabled ?? config?.disabled ?? null,
			retry_setup_failed: runtime?.retry_setup_failed ?? null };
		if (config?.disabled === true || runtime?.disabled === true || runtime?.autostart === false)
			return answer(false, 'administratively_disabled', 'wireless radio is disabled', parsed, candidate, observed_at, evidence);
		if (!runtime && source_failed(snapshot, 'wireless runtime'))
			return answer(false, 'status_unavailable', 'wireless runtime state is unavailable', parsed, candidate, observed_at, evidence);
		if (runtime?.retry_setup_failed === true)
			return answer(false, 'wireless_initialization_failed', 'wireless radio initialization failed', parsed, candidate, observed_at, evidence);
		if (runtime?.up !== true)
			return answer(false, 'wireless_radio_down', 'wireless radio is not running', parsed, candidate, observed_at, evidence);
		return answer(true, null, 'wireless radio is running', parsed, candidate, observed_at, evidence);
	}

	let config = configured(snapshot, 'wifi_ifaces', 'id', parsed.id);
	let runtime_radio = snapshot?.runtime?.wireless?.[config?.device];
	let runtime_iface = wireless_iface(snapshot, config?.device, parsed.id);
	let live = snapshot?.runtime?.devices?.[runtime_iface?.ifname];
	let live_present = !!runtime_iface?.ifname &&
		(runtime_iface.ifname in (snapshot?.runtime?.sys_devices ?? []) || live?.present === true);
	let ap_name = config?.ssid ?? config?.mesh_id ?? 'unnamed';
	let ap_suffix = `${config?.device ?? 'unknown-radio'} / ${parsed.id}`;
	if (runtime_iface?.ifname) ap_suffix += ` (${runtime_iface.ifname})`;
	let candidate = { configured_name: parsed.id,
		label: `AP: ${ap_name} — ${ap_suffix}`,
		live_device: runtime_iface?.ifname ?? null };
	let evidence = { radio: config?.device ?? null, ssid: config?.ssid ?? null,
		radio_up: runtime_radio?.up ?? null, present: !!runtime_iface,
		ifname: runtime_iface?.ifname ?? null, live_present,
		device_up: live?.up ?? null, device_operstate: live?.operstate ?? null };
	if (config?.disabled === true || runtime_radio?.disabled === true ||
		configured(snapshot, 'radios', 'id', config?.device)?.disabled === true)
		return answer(false, 'administratively_disabled', 'wireless AP or parent radio is disabled', parsed, candidate, observed_at, evidence);
	if (!config)
		return answer(false, 'wireless_ap_down', 'wireless AP configuration is absent', parsed, candidate, observed_at, evidence);
	if (!runtime_radio && source_failed(snapshot, 'wireless runtime'))
		return answer(false, 'status_unavailable', 'wireless runtime state is unavailable', parsed, candidate, observed_at, evidence);
	if (runtime_radio?.retry_setup_failed === true)
		return answer(false, 'wireless_initialization_failed', 'wireless AP initialization failed', parsed, candidate, observed_at, evidence);
	if (runtime_radio?.up !== true || !runtime_iface || !runtime_iface.ifname ||
		(!source_failed(snapshot, 'sysfs devices') && !live_present) ||
		live?.up === false || operstate_down(live?.operstate))
		return answer(false, 'wireless_ap_down', 'wireless AP is not running', parsed, candidate, observed_at, evidence);
	return answer(true, null, 'wireless AP is running', parsed, candidate, observed_at, evidence);
};

export function run_interface_with(monitor, deps) {
	return evaluate_interface(monitor.interface_selector, deps.snapshot(), deps.clock());
};

export function run_interface(monitor) {
	return run_interface_with(monitor, {
		clock: () => time(),
		snapshot: () => {
			let cursor = uci.cursor();
			let connection = ubus.connect();
			if (!connection) return { configured: {}, runtime: {}, errors: [ 'ubus unavailable' ] };
			return collect_interface_snapshot_with({
				foreach: (config, type, callback) => cursor.foreach(config, type, callback),
				call: (object, method, args) => connection.call(object, method, args),
				lsdir: (path) => fs.lsdir(path),
				readfile: (path, limit) => fs.readfile(path, limit)
			});
		}
	});
};
```

- [ ] **Step 4: Add interface dispatch to the existing probe task**

Import `run_interface`, make validation type-specific, inject an `interface` callback in tests, and dispatch it in the worker:

```ucode
import { run_interface } from 'interface_probe';

function valid_probe(monitor, callback) {
	if (type(monitor) != 'object' || type(callback) != 'function' ||
		!(monitor.type in ['ping', 'tcp', 'interface'])) return false;
	if (monitor.type in ['ping', 'tcp'] && !safe_target(monitor.target)) return false;
	if (monitor.type == 'interface' &&
		(type(monitor.interface_selector) != 'string' ||
		 length(monitor.interface_selector) > 96 ||
		 !match(monitor.interface_selector,
			/^(network|device|wifi-radio|wifi-iface):[A-Za-z0-9_][A-Za-z0-9_.-]*$/))) return false;
	if (monitor.type == 'tcp' &&
		(type(monitor.port) != 'int' || monitor.port < 1 || monitor.port > 65535)) return false;
	return true;
};
```

Use `timeout_ms` for the parent timeout of both TCP and interface probes, and replace the worker dispatch with:

```ucode
if (monitor.type == 'ping')
	return run_ping_with(monitor, dependencies.fs);
if (monitor.type == 'tcp')
	return run_tcp_with(monitor, timeout_ms, dependencies.socket);
return dependencies.interface(monitor);
```

Require `type(dependencies.interface) == 'function'` in `start_probe_with()` and pass `interface: run_interface` from `start_probe()`.

Append a `probe_test.uc` case using `interface: () => ({ ok: false, reason: 'carrier_lost' })`; execute its captured task function and assert the callback receives `carrier_lost` exactly once with a `5000` ms parent timeout.

- [ ] **Step 5: Run interface and probe suites**

```sh
./tests/run-unit.sh \
  tests/unit/interface_probe_test.uc \
  tests/unit/probe_test.uc
```

Expected: both suites PASS, including callback-once and timeout regression assertions.

- [ ] **Step 6: Commit health evaluation and dispatch**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  packages/netwatch/netwatch/files/usr/share/netwatch/interface_probe.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/probe.uc \
  tests/unit/interface_probe_test.uc tests/unit/probe_test.uc
git --git-dir=work/git-metadata --work-tree=. commit \
  -m "feat: probe interface health states"
```

### Task 4: Bounded and Redacted Failure Diagnostics

**Files:**
- Create: `packages/netwatch/netwatch/files/usr/share/netwatch/diagnostics.uc`
- Create: `tests/unit/diagnostics_test.uc`

**Interfaces:**
- Consumes: Interface monitor, latest compact probe result, and a fresh safe snapshot.
- Produces: `redact_diagnostic_text(text) -> string`; `render_diagnostic_report(sections, errors) -> { text, incomplete, errors, truncated }`; `collect_diagnostics_with(monitor, result, deps) -> report`; `start_diagnostics_with(monitor, result, callback, deps) -> bool`; `start_diagnostics(monitor, result, callback) -> bool`.

- [ ] **Step 1: Write failing redaction, limit, degraded-collection, and timeout tests**

Create `diagnostics_test.uc` with deterministic fake commands and timers:

```ucode
import { equal, truthy } from 'test';
import {
	redact_diagnostic_text,
	render_diagnostic_report,
	collect_diagnostics_with,
	start_diagnostics_with
} from 'diagnostics';

let secret_text = 'ssid=Office\nkey=wifi-secret\npassword: smtp secret phrase\n' +
	'psk=wireless-secret\nsae=sae secret phrase\nradius_key=radius-secret\n' +
	'smtp_password=mail-secret\nAuthorization: Bearer token-value';
let redacted = redact_diagnostic_text(secret_text);
for (let secret in [ 'wifi-secret', 'smtp secret phrase', 'wireless-secret',
	'sae secret phrase', 'radius-secret', 'mail-secret', 'token-value' ])
	equal(match(redacted, regexp(secret)), null, `${secret} redacted`);
truthy(match(redacted, /\[REDACTED\]/), 'redaction marker present');

let lines = [];
for (let i = 0; i < 260; i++) push(lines, `netifd line ${i}`);
let large_output = '';
for (let i = 0; i < 7000; i++) large_output += '0123456789';
let bounded = render_diagnostic_report([
	{ title: 'Recent relevant logs', text: join('\n', lines), log: true },
	{ title: 'Large output', text: large_output, log: false }
], [ 'iwinfo unavailable' ]);
truthy(length(bounded.text) <= 65536, 'report bounded to 64 KiB');
truthy(bounded.truncated, 'truncation reported');
truthy(bounded.incomplete, 'source error marks report incomplete');
equal(match(bounded.text, /netifd line 0\n/), null, 'old log lines discarded');
truthy(match(bounded.text, /netifd line 259/), 'newest log line retained');

let report = collect_diagnostics_with(
	{ type: 'interface', interface_selector: 'wifi-iface:office' },
	{ reason: 'wireless_ap_down', label: 'AP: Office', live_device: 'phy0-ap0',
		evidence: { radio: 'radio0', ssid: 'Office' } },
	{
		clock: () => 1700000100,
		snapshot: () => ({
			configured: { wifi_ifaces: [ { id: 'office', device: 'radio0', mode: 'ap',
				ssid: 'Office', encryption: 'sae', key: 'must-not-exist' } ] },
			runtime: { wireless: { radio0: { up: false, interfaces: [] } }, sys_devices: [] },
			errors: []
		}),
		readfile: (path, limit) => path == '/sys/class/net/phy0-ap0/operstate' ? 'down\n' : null,
		readlink: (path) => null,
		command: (name, command) => name == 'logread'
			? 'unrelated service\nnetifd: office failed key=log-secret\nhostapd: phy0-ap0 disabled\n'
			: name == 'iwinfo' ? null : 'link details'
	});
truthy(match(report.text, /AP: Office/), 'friendly identity included');
truthy(match(report.text, /wireless_ap_down/), 'failure reason included');
truthy(match(report.text, /hostapd: phy0-ap0 disabled/), 'relevant hostapd log included');
equal(match(report.text, /unrelated service/), null, 'unrelated log excluded');
equal(match(report.text, /must-not-exist|log-secret/), null, 'structured and log secrets absent');
truthy(report.incomplete, 'missing optional iwinfo recorded without suppressing report');

let unsafe_commands = [];
collect_diagnostics_with(
	{ type: 'interface', interface_selector: 'device:eth0' },
	{ reason: 'link_down', label: 'eth0', live_device: "eth0';reboot", evidence: {} },
	{
		clock: () => 1700000100,
		snapshot: () => ({ configured: {}, runtime: {}, errors: [] }),
		readfile: (path, limit) => null,
		readlink: (path) => null,
		command: (name, command) => { push(unsafe_commands, name); return ''; }
	});
equal('link' in unsafe_commands, false, 'unsafe runtime device never reaches link command');
equal('iwinfo' in unsafe_commands, false, 'unsafe runtime device never reaches wireless command');

let worker = null;
let output = null;
let timer = null;
let killed = 0;
let callbacks = 0;
let timed_out = null;
let fake_uloop = {
	task: (fn, cb) => {
		worker = fn; output = cb;
		return { finished: () => false, kill: () => { killed++; return true; } };
	},
	timer: (milliseconds, cb) => {
		equal(milliseconds, 15000, 'diagnostic deadline is 15 seconds');
		timer = cb;
		return { cancel: () => true };
	}
};
truthy(start_diagnostics_with(
	{ interface_selector: 'device:eth0' }, { reason: 'carrier_lost' },
	(value) => { callbacks++; timed_out = value; },
	{ uloop: fake_uloop, collect: () => ({ text: 'late', incomplete: false, errors: [], truncated: false }) }
), 'diagnostic task starts');
timer();
equal(killed, 1, 'timed-out worker killed');
equal(callbacks, 1, 'timeout callback called once');
truthy(timed_out.incomplete, 'timeout produces incomplete report');
truthy(match(timed_out.text, /Diagnostic collection incomplete/), 'timeout notice rendered');
output(worker());
equal(callbacks, 1, 'late worker output ignored');
```

- [ ] **Step 2: Run the suite and observe the missing module**

```sh
./tests/run-unit.sh tests/unit/diagnostics_test.uc
```

Expected: FAIL because `diagnostics.uc` does not exist.

- [ ] **Step 3: Implement normalization, redaction, newest-log selection, and hard report bounds**

Create the module foundation:

```ucode
import * as fs from 'fs';
import * as uloop from 'uloop';
import { parse_interface_selector, collect_interface_snapshot_with } from 'interfaces';
import * as ubus from 'ubus';
import * as uci from 'uci';

const REPORT_LIMIT = 65536;
const SECTION_LIMIT = 16384;
const LOG_LINE_LIMIT = 200;
const TASK_TIMEOUT_MS = 15000;

function clean_text(value) {
	if (value == null) return '';
	value = type(value) == 'string' ? value : sprintf('%J', value);
	value = replace(value, /\r\n?/g, '\n');
	return replace(value, /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, ' ');
};

export function redact_diagnostic_text(value) {
	value = clean_text(value);
	for (let pattern in [
		/(\b(?:key|password|passphrase|(?:wpa_)?psk|sae(?:_password)?|radius(?:_secret|_key|_password)?|smtp(?:_password|_pass)?|secret|credential)\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\r\n,;]+)/gi,
		/((authorization|proxy-authorization)\s*:\s*)[^\n]+/gi,
		/(-----BEGIN [^-]*PRIVATE KEY-----)[\s\S]*?(-----END [^-]*PRIVATE KEY-----)/gi
	])
		value = replace(value, pattern, '$1[REDACTED]');
	return value;
};

function newest_lines(value, maximum) {
	let values = split(clean_text(value), '\n');
	if (length(values) > maximum)
		values = slice(values, length(values) - maximum);
	return join('\n', values);
};

function truncate_text(value, maximum) {
	value = clean_text(value);
	if (length(value) <= maximum) return { text: value, truncated: false };
	let marker = '\n[section truncated]\n';
	let cut = maximum - length(marker);
	while (cut > 0) {
		let byte = ord(substr(value, cut, 1));
		if (byte < 128 || byte >= 192) break;
		cut--;
	}
	return { text: substr(value, 0, cut) + marker, truncated: true };
};

export function render_diagnostic_report(sections, errors) {
	let chunks = [];
	let truncated = false;
	for (let section in sections ?? []) {
		let text = section?.log ? newest_lines(section.text, LOG_LINE_LIMIT) : clean_text(section?.text);
		let limited = truncate_text(redact_diagnostic_text(text), SECTION_LIMIT);
		truncated = truncated || limited.truncated;
		push(chunks, `## ${clean_text(section?.title ?? 'Diagnostic')}\n${limited.text}`);
	}
	if (length(errors ?? []))
		push(chunks, '## Diagnostic collection incomplete\n' +
			join('\n', errors.map(error => `- ${clean_text(error)}`)));
	let total = truncate_text(join('\n\n', chunks) + '\n', REPORT_LIMIT);
	return {
		text: total.text,
		incomplete: length(errors ?? []) > 0,
		errors: errors ?? [],
		truncated: truncated || total.truncated
	};
};
```

- [ ] **Step 4: Implement selected-object collection with fixed commands**

Add selected-state extraction and the collector. The actual command adapter receives only command strings built here after selector validation:

```ucode
function relevant_logs(value, names) {
	let output = [];
	for (let line in split(clean_text(value), '\n')) {
		let lower = lc(line);
		let relevant = match(lower, /netifd|hostapd|wpa_supplicant|mac80211|cfg80211|ath[0-9a-z]*|iwlwifi|mt76/);
		for (let name in names)
			if (name && index(lower, lc(name)) >= 0) relevant = true;
		if (relevant) push(output, line);
	}
	return newest_lines(join('\n', output), LOG_LINE_LIMIT);
};

function safe_device_name(value) {
	return type(value) == 'string' && length(value) <= 64 &&
		!!match(value, /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/);
};

function selected_state(snapshot, parsed, result) {
	let output = { selector: `${parsed.kind}:${parsed.id}`, result: {
		reason: result?.reason ?? null, summary: result?.summary ?? null,
		label: result?.label ?? parsed.id, live_device: result?.live_device ?? null,
		evidence: result?.evidence ?? {}
	} };
	let collections = parsed.kind == 'network' ? [ 'networks', 'id' ]
		: parsed.kind == 'device' ? [ 'devices', 'name' ]
		: parsed.kind == 'wifi-radio' ? [ 'radios', 'id' ]
		: [ 'wifi_ifaces', 'id' ];
	for (let value in snapshot?.configured?.[collections[0]] ?? [])
		if (value?.[collections[1]] == parsed.id) output.configured = value;
	if (parsed.kind == 'network')
		for (let value in snapshot?.runtime?.interfaces ?? [])
			if (value?.interface == parsed.id) output.runtime = value;
	if (parsed.kind == 'device') output.runtime = snapshot?.runtime?.devices?.[parsed.id] ?? null;
	if (parsed.kind == 'wifi-radio') output.runtime = snapshot?.runtime?.wireless?.[parsed.id] ?? null;
	if (parsed.kind == 'wifi-iface') {
		let radio = output.configured?.device;
		output.radio = snapshot?.runtime?.wireless?.[radio] ?? null;
		for (let value in output.radio?.interfaces ?? [])
			if (value?.section == parsed.id) output.runtime = value;
	}
	return output;
};

export function collect_diagnostics_with(monitor, result, deps) {
	let parsed = parse_interface_selector(monitor?.interface_selector);
	if (!parsed)
		return render_diagnostic_report([], [ 'interface selector is invalid' ]);

	let errors = [];
	let sections = [];
	let snapshot;
	try { snapshot = deps.snapshot(); }
	catch (error) { snapshot = { configured: {}, runtime: {}, errors: [] }; push(errors, 'state snapshot unavailable'); }
	for (let error in snapshot?.errors ?? []) push(errors, error);
	let selected = selected_state(snapshot, parsed, result);
	selected.collected_at = deps.clock();
	push(sections, { title: 'Interface identity and observed state', text: sprintf('%J', selected) });

	let device = result?.live_device ?? (parsed.kind == 'device' ? parsed.id : null);
	if (device && !safe_device_name(device)) {
		push(errors, 'live device name is invalid');
		device = null;
	}
	if (device) {
		let sysfs = {};
		for (let name in [ 'operstate', 'carrier', 'mtu', 'address',
			'statistics/rx_bytes', 'statistics/rx_packets', 'statistics/rx_errors',
			'statistics/tx_bytes', 'statistics/tx_packets', 'statistics/tx_errors' ]) {
			let value = deps.readfile(`/sys/class/net/${device}/${name}`, 4096);
			if (value != null) sysfs[name] = trim(clean_text(value));
		}
		let driver = deps.readlink(`/sys/class/net/${device}/device/driver`);
		if (driver) sysfs.driver = driver;
		push(sections, { title: 'Kernel interface facts', text: sprintf('%J', sysfs) });

		let link = deps.command('link', `/sbin/ip -details address show dev '${device}' 2>&1`);
		if (link != null) push(sections, { title: 'Address and link details', text: link });
		else push(errors, 'link details unavailable');
	}

	if (parsed.kind in [ 'wifi-radio', 'wifi-iface' ]) {
		let iw_target = device ?? parsed.id;
		let iwinfo = deps.command('iwinfo', `/usr/bin/iwinfo '${iw_target}' info 2>&1`);
		if (iwinfo != null) push(sections, { title: 'Wireless status', text: iwinfo });
		else push(errors, 'iwinfo unavailable');
	}

	let log_text = deps.command('logread', '/sbin/logread 2>&1');
	if (log_text != null) {
		let filtered = relevant_logs(log_text,
			[ parsed.id, selected?.configured?.device, device, result?.label ]);
		push(sections, { title: 'Recent relevant logs', text: filtered, log: true });
	}
	else push(errors, 'system log unavailable');

	return render_diagnostic_report(sections, errors);
};
```

The production adapter must collect a new snapshot for each call and cap every command read at 262144 bytes:

```ucode
const COMMAND_PATHS = {
	link: '/sbin/ip',
	iwinfo: '/usr/bin/iwinfo',
	logread: '/sbin/logread'
};

function command_output(name, command) {
	let path = COMMAND_PATHS[name];
	if (!path || !fs.stat(path) || index(command, path) != 0) return null;
	let process = fs.popen(command, 'r');
	if (!process) return null;
	let output = process.read(262144) ?? '';
	process.close();
	return output;
};

export function collect_diagnostics(monitor, result) {
	let cursor = uci.cursor();
	let connection = ubus.connect();
	if (!connection) return render_diagnostic_report([], [ 'ubus unavailable' ]);
	return collect_diagnostics_with(monitor, result, {
		clock: () => time(),
		snapshot: () => collect_interface_snapshot_with({
			foreach: (config, type, callback) => cursor.foreach(config, type, callback),
			call: (object, method, args) => connection.call(object, method, args),
			lsdir: (path) => fs.lsdir(path),
			readfile: (path, limit) => fs.readfile(path, limit)
		}),
		readfile: (path, limit) => fs.readfile(path, limit),
		readlink: (path) => fs.readlink(path),
		command: command_output
	});
};
```

- [ ] **Step 5: Implement the callback-once 15-second task wrapper**

Use the same timer ownership pattern as `probe.uc`:

```ucode
function incomplete_report(reason) {
	return render_diagnostic_report([], [ reason ]);
};

export function start_diagnostics_with(monitor, result, callback, deps) {
	if (type(callback) != 'function' || type(deps?.uloop) != 'object' ||
		type(deps?.collect) != 'function') return false;
	let task_handle = null;
	let timeout_handle = null;
	let completed = false;

	function finish(report) {
		if (completed) return;
		completed = true;
		if (timeout_handle) timeout_handle.cancel();
		callback(type(report) == 'object' && type(report.text) == 'string'
			? report : incomplete_report('diagnostic collector failed'));
	};

	task_handle = deps.uloop.task(
		() => {
			try { return deps.collect(monitor, result); }
			catch (error) { return incomplete_report('diagnostic collector failed'); }
		},
		(report) => finish(report)
	);
	if (!task_handle) return false;

	timeout_handle = deps.uloop.timer(TASK_TIMEOUT_MS, () => {
		let fired = timeout_handle;
		timeout_handle = null;
		if (fired) fired.cancel();
		if (!task_handle.finished()) task_handle.kill();
		finish(incomplete_report('diagnostic collector timed out'));
	});
	if (!timeout_handle) {
		completed = true;
		task_handle.kill();
		return false;
	}
	return true;
};

export function start_diagnostics(monitor, result, callback) {
	return start_diagnostics_with(monitor, result, callback, {
		uloop,
		collect: collect_diagnostics
	});
};
```

- [ ] **Step 6: Run diagnostic and regression suites**

```sh
./tests/run-unit.sh \
  tests/unit/diagnostics_test.uc \
  tests/unit/interface_probe_test.uc \
  tests/unit/message_test.uc
```

Expected: all three suites PASS; no secret fixture value appears in diagnostic output.

- [ ] **Step 7: Commit the diagnostic boundary**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  packages/netwatch/netwatch/files/usr/share/netwatch/diagnostics.uc \
  tests/unit/diagnostics_test.uc
git --git-dir=work/git-metadata --work-tree=. commit \
  -m "feat: collect bounded interface diagnostics"
```

### Task 5: Transition State, Public Status, and Interface Messages

**Files:**
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/state.uc:1-78`
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/store.uc:6-22`
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/message.uc:262-349`
- Modify: `tests/unit/state_test.uc:1-77`
- Create: `tests/unit/store_test.uc`
- Modify: `tests/unit/message_test.uc:105-201`

**Interfaces:**
- Consumes: Compact interface probe result and optional diagnostic report.
- Produces: `state.last_transition`; `recovery_pending.recovered_result`; public transition timestamp; interface-specific failure and recovery mail without persisted diagnostics.

- [ ] **Step 1: Write failing state and store tests**

Append state assertions around existing transitions:

```ucode
// Add this field to the existing exact new_state() expectation.
last_transition: null,

// Add this field to the existing alerted recovery_pending expectation.
recovered_result: good,

let interface_state = new_state('wifi');
let interface_monitor = { enabled: true, failures: 1, recovery_email: true };
let failed_interface = { ok: false, reason: 'wireless_ap_down', selector: 'wifi-iface:office' };
let recovered_interface = { ok: true, reason: null, selector: 'wifi-iface:office',
	label: 'AP: Office', live_device: 'phy0-ap0', evidence: { present: true } };
equal(apply_result(interface_state, interface_monitor, failed_interface, 100), 'opened',
	'interface incident opens');
equal(interface_state.last_transition, 100, 'failed transition time recorded');
interface_state.recovery_eligible = true;
equal(apply_result(interface_state, interface_monitor, recovered_interface, 160), 'recovered',
	'interface incident recovers');
equal(interface_state.last_transition, 160, 'recovery transition time recorded');
deep_equal(interface_state.recovery_pending.recovered_result, recovered_interface,
	'fresh recovery result retained for concise recovery email');
```

Create `store_test.uc`:

```ucode
import { equal, truthy } from 'test';
import { public_status } from 'store';

let status = public_status(10, 20, null, [ {
	id: 'wifi', status: 'failed', last_check: 30, last_transition: 25,
	last_result: { ok: false, reason: 'wireless_ap_down', evidence: { present: false } },
	consecutive_failures: 3, incident_started: 25, failure_emails: 1,
	config_error: null, diagnostic: { text: 'must not persist' }
} ]);
equal(status.monitors[0].last_transition, 25, 'last transition published');
equal(match(sprintf('%J', status), /must not persist/), null, 'diagnostic report omitted');
truthy(type(status.monitors[0].last_result.evidence) == 'object', 'compact evidence retained');
```

- [ ] **Step 2: Write failing interface message tests**

Append a failure context with multiline diagnostics and a recovery context with `recovered_result`:

```ucode
let interface_context = {
	...context,
	monitor: {
		id: 'office_wifi', name: 'Office Wi-Fi', type: 'interface', target: '',
		interface_selector: 'wifi-iface:office', max_alerts: 4
	},
	state: {
		incident_started: 1700000000, failure_emails: 1, last_check: 1700000060,
		last_result: {
			ok: false, reason: 'wireless_ap_down', summary: 'wireless AP is not running',
			selector: 'wifi-iface:office', kind: 'wifi-iface',
			configured_name: 'office', label: 'AP: Office WiFi — radio0 / office',
			live_device: 'phy0-ap0', observed_at: 1700000060,
			evidence: { radio: 'radio0', present: false }
		}
	},
	diagnostic: {
		text: '## Recent relevant logs\nnetifd: radio0 setup failed\n',
		incomplete: false, errors: [], truncated: false
	}
};
let interface_failure = render_message('failure', interface_context);
truthy(match(interface_failure,
	/Subject: \[Netwatch DOWN\]\[router\.example\.test\] Office Wi-Fi/),
	'router identity included in interface failure subject');
truthy(match(interface_failure, /Interface: AP: Office WiFi/), 'friendly interface rendered');
truthy(match(interface_failure, /Selector: wifi-iface:office/), 'stable selector rendered');
truthy(match(interface_failure, /Live device: phy0-ap0/), 'live device rendered');
truthy(match(interface_failure, /Summary: wireless AP is not running/), 'summary rendered');
truthy(match(interface_failure, /Last check: Tue, 14 Nov 2023 22:14:20 \+0000/),
	'last check time rendered');
truthy(match(interface_failure, /netifd: radio0 setup failed/), 'diagnostic report rendered');

let interface_recovery = render_message('recovery', {
	...interface_context,
	diagnostic: null,
	state: { recovery_pending: {
		incident_started: 1700000000, recovered_at: 1700000120, failure_emails: 2,
		last_result: interface_context.state.last_result,
		recovered_result: {
			ok: true, selector: 'wifi-iface:office', kind: 'wifi-iface',
			label: 'AP: Office WiFi — radio0 / office', live_device: 'phy0-ap0',
			summary: 'wireless AP is running', evidence: { present: true }
		}
	} }
});
truthy(match(interface_recovery,
	/Subject: \[Netwatch RECOVERED\]\[router\.example\.test\] Office Wi-Fi/),
	'router identity included in interface recovery subject');
truthy(match(interface_recovery, /Recovered state: wireless AP is running/),
	'fresh recovery snapshot rendered');
equal(match(interface_recovery, /Recent relevant logs/), null,
	'failure diagnostics omitted from recovery');
```

- [ ] **Step 3: Run the focused tests and observe missing fields/rendering**

```sh
./tests/run-unit.sh \
  tests/unit/state_test.uc \
  tests/unit/store_test.uc \
  tests/unit/message_test.uc
```

Expected: FAIL on `last_transition`, `recovered_result`, and interface body assertions.

- [ ] **Step 4: Record transition time and recovery result**

Add `last_transition: null` to `new_state()`. In `apply_result()`, use this helper whenever status changes:

```ucode
function set_status(state, status, now) {
	if (state.status != status)
		state.last_transition = now;
	state.status = status;
};
```

Replace direct assignments to `disabled`, `healthy`, `pending`, and `failed` with `set_status(state, value, now)`. Add the successful result to recovery data before clearing the incident:

```ucode
state.recovery_pending = {
	incident_started: state.incident_started,
	recovered_at: now,
	failure_emails: state.failure_emails,
	last_result: state.last_result,
	recovered_result: result
};
```

Add `last_transition: s.last_transition` to `public_status()`; do not add any diagnostic field.

- [ ] **Step 5: Render type-specific mail while preserving host messages**

In `render_message()`, do not validate `monitor.target` until the monitor type is known:

```ucode
let is_interface = monitor.type == 'interface';
let target = is_interface ? '' : safe_text(monitor.target, 'monitor target', false);
```

Add safe interface body helpers before `render_message()`:

```ucode
function safe_body_block(value, field) {
	if (type(value) != 'string' || length(value) > 65536 ||
		match(value, /[\r\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/))
		die(`${field} contains invalid characters`);
	return value;
};

function interface_identity_lines(result) {
	if (type(result) != 'object') die('interface result is required');
	let lines = [
		`Interface: ${safe_text(result.label ?? result.configured_name, 'interface label', false)}`,
		`Selector: ${safe_text(result.selector, 'interface selector', false)}`,
		`Interface kind: ${safe_text(result.kind, 'interface kind', false)}`
	];
	if (type(result.live_device) == 'string' && result.live_device != '')
		push(lines, `Live device: ${safe_text(result.live_device, 'live device', false)}`);
	if (type(result.summary) == 'string' && result.summary != '')
		push(lines, `Summary: ${safe_text(result.summary, 'interface summary', false)}`);
	if (type(result.evidence) == 'object')
		push(lines, `Evidence: ${sprintf('%J', result.evidence)}`);
	return lines;
};
```

Use this exact interface failure branch; retain the current host branch unchanged:

```ucode
if (is_interface) {
	let label = safe_text(result.label ?? result.configured_name,
		'interface label', false);
	subject = `[Netwatch DOWN][${hostname}] ${name} — ${label}`;
	body = [
		`Monitor: ${name}`,
		...interface_identity_lines(result),
		`Reason: ${safe_text(result.reason, 'failure reason', false)}`,
		`Last check: ${rfc5322_date(integer(state.last_check, 'last check'))}`,
		`Incident time: ${rfc5322_date(incident)}`,
		`Duration: ${duration_text(duration)}`,
		`Alert ${alert_number} of ${max_alerts}`
	];
	if (type(context.diagnostic) == 'object' &&
		type(context.diagnostic.text) == 'string') {
		push(body, '');
		push(body, safe_body_block(context.diagnostic.text, 'diagnostic report'));
	}
}
```

Use this exact recovery branch for interface monitors; retain the current host recovery branch and subjects unchanged:

```ucode
if (is_interface) {
	let recovered = pending.recovered_result;
	let label = safe_text(recovered?.label ?? recovered?.configured_name,
		'interface label', false);
	subject = `[Netwatch RECOVERED][${hostname}] ${name} — ${label}`;
	body = [
		`Monitor: ${name}`,
		...interface_identity_lines(recovered),
		`Recovered state: ${safe_text(recovered.summary, 'recovery summary', false)}`,
		`Incident time: ${rfc5322_date(incident)}`,
		`Recovered at: ${rfc5322_date(recovered_at)}`,
		`Duration: ${duration_text(duration)}`
	];
}
```

The recovery branch never reads `context.diagnostic`.

- [ ] **Step 6: Run all state, store, message, and scheduler tests**

```sh
./tests/run-unit.sh \
  tests/unit/state_test.uc \
  tests/unit/store_test.uc \
  tests/unit/message_test.uc \
  tests/unit/alerts_test.uc
```

Expected: all four suites PASS; existing ping/TCP message assertions remain byte-compatible except where the tests explicitly accept the new common transition state.

- [ ] **Step 7: Commit state and message support**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  packages/netwatch/netwatch/files/usr/share/netwatch/state.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/store.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/message.uc \
  tests/unit/state_test.uc tests/unit/store_test.uc tests/unit/message_test.uc
git --git-dir=work/git-metadata --work-tree=. commit \
  -m "feat: render interface incident details"
```

### Task 6: Daemon Inventory RPC and Alert-Time Diagnostics

**Files:**
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc:1-778`
- Modify: `tests/static.sh:302-391`

**Interfaces:**
- Consumes: `collect_interface_inventory()`, `start_diagnostics()`, and the existing due-alert state machine.
- Produces: read-only `netwatch.interfaces`; a fresh diagnostic collection for each due interface failure email; base-email fallback on collector startup failure or timeout.

- [ ] **Step 1: Add failing static integration assertions**

Extend the daemon declaration loop and add ordering/security checks:

```sh
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
```

Add this Node/source-order assertion:

```sh
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
```

- [ ] **Step 2: Run static tests and observe the failure**

```sh
./tests/static.sh
```

Expected: FAIL on the missing imports, RPC method, and diagnostic call.

- [ ] **Step 3: Publish the normalized read-only inventory RPC**

Add imports:

```ucode
import { collect_interface_inventory } from 'interfaces';
import { start_diagnostics, render_diagnostic_report } from 'diagnostics';
```

Add a sanitized request handler:

```ucode
function request_interfaces(request) {
	try {
		return collect_interface_inventory();
	}
	catch (error) {
		return { groups: [], errors: [ 'interface inventory unavailable' ] };
	}
};
```

Publish it next to `status`:

```ucode
interfaces: {
	args: {},
	call: request_interfaces
},
```

- [ ] **Step 4: Split rendering/delivery from alert preparation**

Change `render_alert()` to accept and forward a diagnostic report:

```ucode
function render_alert(kind, monitor, state, timestamp, recipients, diagnostic) {
	return render_message(kind, {
		smtp: smtp_config,
		recipients,
		monitor,
		state,
		router_hostname: safe_router_hostname(),
		timestamp,
		diagnostic
	});
};
```

Extract the existing message rendering and `start_delivery()` body into:

```ucode
function start_alert_delivery(monitor, state, kind, now, recipients, diagnostic) {
	let message;
	try {
		message = render_alert(kind, monitor, state, now, recipients, diagnostic);
	}
	catch (error) {
		state.mail_busy = false;
		alert_render_failed(state, now, 'recipient is invalid');
		return false;
	}

	let incident_started = kind == 'failure'
		? state.incident_started
		: state.recovery_pending?.incident_started;
	let delivery_started = start_delivery(message, (delivered) => {
		state.mail_busy = false;
		if (!monitor_state_is_current(monitor.id, state)) return;
		let same_incident = kind == 'failure'
			? state.status == 'failed' && state.incident_started == incident_started
			: state.recovery_pending?.incident_started == incident_started;
		if (same_incident && delivered === true) {
			mail_succeeded(state, kind, time());
			mail_error = null;
			log.syslog('info', 'monitor %s %s mail delivered', monitor.id, kind);
		}
		else if (same_incident) {
			mail_failed(state, time(), global_config.mail_retry_backoff);
			mail_error = 'mail delivery failed';
			log.syslog('err', 'monitor %s %s mail delivery failed', monitor.id, kind);
		}
		persist_status();
		if (scheduler) scheduler.set(0);
	});

	if (!delivery_started) {
		state.mail_busy = false;
		mail_failed(state, now, global_config.mail_retry_backoff);
		mail_error = 'mail delivery failed';
		persist_status();
		return false;
	}
	return true;
};
```

- [ ] **Step 5: Collect fresh diagnostics at every due interface failure**

Replace `start_alert()` with a preparation path that keeps the monitor busy across diagnostic collection and delivery:

```ucode
function start_alert(monitor, state, kind, now) {
	if (shutting_down) return false;
	if (!mail_config_ready) {
		alert_render_failed(state, now, 'mail configuration invalid');
		return false;
	}

	let recipients = monitor.recipients != ''
		? monitor.recipients : global_config.recipients;
	state.mail_busy = true;

	if (monitor.type == 'interface' && kind == 'failure') {
		log.syslog('info', 'monitor %s diagnostic start selector %s reason %s',
			monitor.id, monitor.interface_selector, state.last_result?.reason ?? 'unknown');
		let finished = (diagnostic) => {
			if (shutting_down || !monitor_state_is_current(monitor.id, state)) {
				state.mail_busy = false;
				return;
			}
			log.syslog(diagnostic.incomplete ? 'warning' : 'info',
				'monitor %s diagnostic collection %s truncated %s', monitor.id,
				diagnostic.incomplete ? 'incomplete' : 'complete',
				diagnostic.truncated ? 'yes' : 'no');
			start_alert_delivery(monitor, state, kind, now, recipients, diagnostic);
		};
		if (!start_diagnostics(monitor, state.last_result, finished))
			finished(render_diagnostic_report([], [ 'Diagnostic collection incomplete: unable to start collector' ]));
		return true;
	}

	return start_alert_delivery(monitor, state, kind, now, recipients, null);
};
```

This call is executed every time `due_alert()` returns `failure`; no report is cached on `state`, so repeat emails automatically recollect it. Recovery calls `start_alert_delivery()` directly and uses the concise `recovered_result` stored in Task 5.

- [ ] **Step 6: Run daemon static and all unit tests**

```sh
./tests/static.sh
./tests/run-unit.sh \
  tests/unit/config_test.uc \
  tests/unit/interfaces_test.uc \
  tests/unit/interface_probe_test.uc \
  tests/unit/diagnostics_test.uc \
  tests/unit/ping_test.uc \
  tests/unit/probe_test.uc \
  tests/unit/state_test.uc \
  tests/unit/store_test.uc \
  tests/unit/alerts_test.uc \
  tests/unit/message_test.uc
```

Expected: static checks and all ten unit suites PASS. Existing scheduler tests prove delayed, repeat, capped, retry, and recovery semantics remain unchanged.

- [ ] **Step 7: Commit daemon integration**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc \
  tests/static.sh
git --git-dir=work/git-metadata --work-tree=. commit \
  -m "feat: attach diagnostics to interface alerts"
```

### Task 7: LuCI Interface Monitor Dropdown

**Files:**
- Modify: `packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/monitors.js:1-173`
- Modify: `tests/static.sh:563-629`

**Interfaces:**
- Consumes: `netwatch.interfaces -> { groups: [{ id, label, items }], errors }` and saved UCI `interface_selector` values.
- Produces: `Interface state` test type; native grouped dropdown; disabled/absent hints; saved missing-selector preservation; unchanged common timing controls.

- [ ] **Step 1: Add failing LuCI source/behavior tests**

Extend the monitor-view declarations with:

```sh
"object: 'netwatch', method: 'interfaces', expect: { '': {} }" \
"o.value('interface', _('Interface state'))" \
"form.ListValue, 'interface_selector'" \
"o.depends('type', 'interface')" \
"Missing: %s" \
"E('optgroup'"
```

Add a Node extraction test for a pure `normalizeInterfaceGroups()` helper:

```js
const source = require('fs').readFileSync(process.argv[1], 'utf8');
const begin = source.indexOf('function normalizeInterfaceGroups');
const end = source.indexOf('\n\nconst GroupedInterfaceValue', begin);
if (begin < 0 || end < 0)
	throw new Error('unable to load interface choice helper');
String.prototype.format = function(...values) {
	let index = 0;
	return this.replace(/%s/g, () => String(values[index++]));
};
const normalizeInterfaceGroups = Function('_',
	`const INTERFACE_GROUP_LABELS = {
		'networks': 'OpenWrt networks', 'devices': 'Linux devices',
		'wifi-radios': 'Wi-Fi radios', 'wifi-aps': 'Wi-Fi APs / SSIDs'
	}; ${source.slice(begin, end)}; return normalizeInterfaceGroups;`
)(value => value);
const groups = normalizeInterfaceGroups({ groups: [ {
	id: 'wifi-aps', label: 'Wi-Fi APs / SSIDs', items: [
		{ selector: 'wifi-iface:office0', label: 'AP: Office — radio0 / office0', state: 'up' },
		{ selector: 'wifi-iface:office1', label: 'AP: Office — radio1 / office1', state: 'disabled' }
	]
} ], errors: [] }, [ 'wifi-iface:removed' ]);
if (groups.length !== 2 || groups[0].items.length !== 2 ||
	groups[1].items[0].selector !== 'wifi-iface:removed' ||
	!groups[1].items[0].label.includes('Missing:'))
	throw new Error('custom, duplicate, disabled, and missing AP choices were not preserved');
```

- [ ] **Step 2: Run static tests and observe missing RPC/dropdown behavior**

```sh
./tests/static.sh
```

Expected: FAIL on the new interface view declarations/helper.

- [ ] **Step 3: Load and normalize inventory without trusting remote labels blindly**

Add the RPC declaration and known group titles:

```js
const callInterfaces = rpc.declare({
	object: 'netwatch', method: 'interfaces', expect: { '': {} }
});

const INTERFACE_GROUP_LABELS = {
	'networks': _('OpenWrt networks'),
	'devices': _('Linux devices'),
	'wifi-radios': _('Wi-Fi radios'),
	'wifi-aps': _('Wi-Fi APs / SSIDs')
};
```

Add the pure normalizer before the view:

```js
function cleanChoiceText(value, fallback) {
	return typeof(value) === 'string' && value !== ''
		? value.replace(/[\x00-\x1f\x7f]/g, ' ').slice(0, 512)
		: fallback;
}

function normalizeInterfaceGroups(inventory, savedSelectors) {
	const groups = [];
	const seen = Object.create(null);
	const input = inventory && Array.isArray(inventory.groups) ? inventory.groups : [];

	for (const group of input) {
		if (!group || !INTERFACE_GROUP_LABELS[group.id] || !Array.isArray(group.items))
			continue;
		const items = [];
		for (const item of group.items) {
			if (!item || typeof(item.selector) !== 'string' ||
				!/^(network|device|wifi-radio|wifi-iface):[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(item.selector) ||
				seen[item.selector])
				continue;
			seen[item.selector] = true;
			const state = cleanChoiceText(item.state, 'unknown');
			items.push({
				selector: item.selector,
				label: '%s (%s)'.format(cleanChoiceText(item.label, item.selector), state)
			});
		}
		groups.push({ id: group.id, label: INTERFACE_GROUP_LABELS[group.id], items });
	}

	const missing = [];
	for (const selector of savedSelectors) {
		if (typeof(selector) === 'string' && selector !== '' && !seen[selector]) {
			seen[selector] = true;
			missing.push({ selector, label: _('Missing: %s').format(selector) });
		}
	}
	if (missing.length)
		groups.push({ id: 'missing', label: _('Missing selections'), items: missing });
	return groups;
}
```

Change `load()` to request UCI, leases, and inventory in parallel:

```js
return Promise.all([
	uci.load('netwatch'),
	L.resolveDefault(callDHCPLeases(), {}),
	L.resolveDefault(callInterfaces(), { groups: [], errors: [ 'unavailable' ] })
]);
```

- [ ] **Step 4: Render real HTML option groups while preserving LuCI form binding**

Define a `form.ListValue` subclass that rearranges the already bound native select options:

```js
const GroupedInterfaceValue = form.ListValue.extend({
	renderWidget(sectionId, optionIndex, cfgvalue) {
		const root = this.super('renderWidget', arguments);
		const select = root.querySelector('select');
		const options = Object.create(null);
		for (const option of Array.from(select.options))
			if (option.value !== '') options[option.value] = option;
		for (const group of this.interfaceGroups || []) {
			const optgroup = E('optgroup', { 'label': group.label });
			for (const item of group.items)
				if (options[item.selector]) optgroup.appendChild(options[item.selector]);
			if (optgroup.children.length) select.appendChild(optgroup);
		}
		return root;
	}
});
```

In `render(data)`, collect saved selectors and create the groups:

```js
const savedSelectors = uci.sections('netwatch', 'monitor')
	.map(monitor => monitor.interface_selector)
	.filter(value => typeof(value) === 'string' && value !== '');
const interfaceGroups = normalizeInterfaceGroups(data[2], savedSelectors);
const inventoryErrors = data[2] && Array.isArray(data[2].errors) ? data[2].errors : [];
```

Add the test type, replace the target option declaration with a named variable so both host types can depend on it, and create the required selector:

```js
o.value('interface', _('Interface state'));

const target = s.option(form.Value, 'target', _('Host or IP address'),
	_('Select an active DHCP lease or enter a target manually.'));
target.datatype = 'or(hostname,ipaddr("nomask"))';
target.rmempty = false;
addLeaseChoices(target, leaseInfo);
target.depends('type', 'ping');
target.depends('type', 'tcp');

o = s.option(GroupedInterfaceValue, 'interface_selector', _('Interface or Wi-Fi AP'),
	inventoryErrors.length
		? _('Interface inventory is temporarily incomplete. Saved selections are preserved.')
		: _('Select an OpenWrt network, Linux device, Wi-Fi radio, or AP/SSID.'));
o.interfaceGroups = interfaceGroups;
for (const group of interfaceGroups)
	for (const item of group.items)
		o.value(item.selector, item.label);
o.rmempty = false;
o.modalonly = true;
o.depends('type', 'interface');
o.validate = function(sectionId, value) {
	return /^(network|device|wifi-radio|wifi-iface):[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(value)
		? true : _('Select an interface.');
};
```

Use this map description and do not add a custom-entry control for `interface_selector`:

```js
const m = new form.Map('netwatch', _('Netwatch monitors'),
	_('Monitor hosts, TCP services, OpenWrt networks, Linux devices, Wi-Fi radios, and APs.'));
```

- [ ] **Step 5: Run static and configuration tests**

```sh
./tests/static.sh
./tests/run-unit.sh tests/unit/config_test.uc tests/unit/interfaces_test.uc
```

Expected: all checks PASS; the Node helper test proves duplicate custom SSIDs and removed saved selectors are retained.

- [ ] **Step 6: Commit the interface monitor form**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/monitors.js \
  tests/static.sh
git --git-dir=work/git-metadata --work-tree=. commit \
  -m "feat: add LuCI interface selector"
```

### Task 8: LuCI Interface Status, ACL, Catalog, and Static Safety Gates

**Files:**
- Modify: `packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/status.js:1-295`
- Modify: `packages/netwatch/luci-app-netwatch/root/usr/share/rpcd/acl.d/luci-app-netwatch.json:1-18`
- Modify: `packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot`
- Modify: `tests/static.sh:14-689`

**Interfaces:**
- Consumes: UCI monitor metadata, `netwatch.status`, and `netwatch.interfaces`.
- Produces: friendly interface target, stable selector/live device, normalized reason, last transition, compact evidence, `sent/cap` count, exact read-only inventory ACL, and translation coverage.

- [ ] **Step 1: Add failing status/ACL/module/package assertions**

Require the three new runtime modules near the top of `tests/static.sh`:

```sh
require_file packages/netwatch/netwatch/files/usr/share/netwatch/interfaces.uc
require_file packages/netwatch/netwatch/files/usr/share/netwatch/interface_probe.uc
require_file packages/netwatch/netwatch/files/usr/share/netwatch/diagnostics.uc
```

Change the exact ACL expectation to:

```js
!same(grant.read?.ubus, {
	'luci-rpc': [ 'getDHCPLeases' ],
	netwatch: [ 'status', 'interfaces' ]
})
```

Require the exact status declarations and update the row harness from action index `8` to `9` after the transition column is added:

```sh
for declaration in \
  "object: 'netwatch', method: 'interfaces', expect: { '': {} }" \
  "_('Last transition')" \
  "_('Administratively disabled')" \
  "_('Interface absent')" \
  "_('Interface unavailable')" \
  "_('Link down')" \
  "_('Carrier lost')" \
  "_('Wi-Fi radio down')" \
  "_('Wi-Fi AP down')" \
  "_('Wi-Fi initialization failed')" \
  "_('Interface status unavailable')" \
  'function inventoryBySelector' \
  'function interfaceIdentity' \
  'function formatInterfaceResult' \
  'function formatEmails(value, cap)' \
  'state.last_transition' \
  'monitor.max_alerts'
do
  if ! grep -Fq -- "$declaration" "$status"; then
    echo "missing interface status declaration: $declaration" >&2
    fail=1
  fi
done
```

In the existing Node row-state test, change each `rows[n][8]` reference to `rows[n][9]` and pass an empty candidate map as the new second `statusRows()` argument.

Add safety checks:

```sh
diagnostics="$root/packages/netwatch/netwatch/files/usr/share/netwatch/diagnostics.uc"
for declaration in \
  "link: '/sbin/ip'" \
  "iwinfo: '/usr/bin/iwinfo'" \
  "logread: '/sbin/logread'" \
  'if (!path || !fs.stat(path) || index(command, path) != 0) return null;'
do
  if ! grep -Fq -- "$declaration" "$diagnostics"; then
    echo "missing fixed diagnostic command gate: $declaration" >&2
    fail=1
  fi
done

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
```

- [ ] **Step 2: Run static tests and observe status/ACL/catalog failures**

```sh
./tests/static.sh
```

Expected: FAIL until status, ACL, and catalog changes are implemented.

- [ ] **Step 3: Add interface reason labels and compact result formatting**

Extend `reasonLabel()` with:

```js
case 'administratively_disabled': return _('Administratively disabled');
case 'interface_absent': return _('Interface absent');
case 'unavailable': return _('Interface unavailable');
case 'link_down': return _('Link down');
case 'carrier_lost': return _('Carrier lost');
case 'wireless_radio_down': return _('Wi-Fi radio down');
case 'wireless_ap_down': return _('Wi-Fi AP down');
case 'wireless_initialization_failed': return _('Wi-Fi initialization failed');
case 'status_unavailable': return _('Interface status unavailable');
```

Add safe candidate and interface renderers:

```js
function inventoryBySelector(inventory) {
	const output = Object.create(null);
	for (const group of inventory && Array.isArray(inventory.groups) ? inventory.groups : [])
		for (const item of group && Array.isArray(group.items) ? group.items : [])
			if (item && typeof(item.selector) === 'string') output[item.selector] = item;
	return output;
}

function interfaceIdentity(monitor, result, candidates) {
	const selector = configuredText(monitor.interface_selector, _('Not configured'));
	const candidate = candidates[monitor.interface_selector];
	const label = configuredText(candidate && candidate.label,
		configuredText(result && result.label, selector));
	const live = configuredText(result && result.live_device,
		configuredText(candidate && candidate.live_device, ''));
	return live ? '%s — %s (%s)'.format(label, selector, live) : '%s — %s'.format(label, selector);
}

function formatInterfaceResult(result) {
	if (!result || typeof(result) !== 'object') return _('No result');
	const parts = [ reasonLabel(result.reason, result.ok === true) ];
	if (typeof(result.summary) === 'string' && result.summary !== '')
		parts.push(configuredText(result.summary, ''));
	if (result.evidence && typeof(result.evidence) === 'object') {
		for (const key of [ 'operstate', 'carrier', 'radio_up', 'present' ])
			if (result.evidence[key] != null)
				parts.push('%s=%s'.format(key, String(result.evidence[key])));
	}
	return parts.join('; ');
}
```

Update result/test dispatch exactly as follows and render the target column through `interfaceIdentity()` when the type is `interface`:

```js
function formatResult(monitor, state) {
	const result = state && typeof(state.last_result) === 'object'
		? state.last_result : null;
	if (monitor.type === 'interface') return formatInterfaceResult(result);
	if (monitor.type === 'tcp') return formatTcpResult(monitor, result);
	return formatPingResult(result);
}

function formatTest(monitor) {
	if (monitor.type === 'interface') return _('Interface state');
	if (monitor.type !== 'tcp') return _('Ping');
	const port = monitorPort(monitor);
	return port == null ? _('TCP') : _('TCP port %d').format(port);
}

const target = monitor.type === 'interface'
	? interfaceIdentity(monitor, state && state.last_result, candidates)
	: configuredText(monitor.target, _('Not configured'));
```

Change `statusRows(status, table, notice)` to `statusRows(status, candidates, table, notice)` and use this email count renderer:

```js
function formatEmails(value, cap) {
	const sent = finiteNumber(value, 0, 1000000) ? Math.floor(value) : 0;
	const maximum = Number(cap);
	return '%d / %d'.format(sent,
		Number.isInteger(maximum) && maximum >= 1 && maximum <= 1000 ? maximum : 1);
}
```

Add a `Last transition` column using `state.last_transition` and pass `monitor.max_alerts` to `formatEmails()`.

- [ ] **Step 4: Refresh status and inventory together**

Declare `callInterfaces` in `status.js`, load it with UCI/status, and make `refreshStatus()` request both live objects:

```js
const callInterfaces = rpc.declare({
	object: 'netwatch', method: 'interfaces', expect: { '': {} }
});

return Promise.all([
	L.resolveDefault(callStatus(), null),
	L.resolveDefault(callInterfaces(), { groups: [], errors: [ 'unavailable' ] })
]).then(function(data) {
	const status = data[0];
	const candidates = inventoryBySelector(data[1]);
	const available = !!status && Array.isArray(status.monitors);
	showAvailability(notice, available);
	cbi_update_table(table, statusRows(status, candidates, table, notice),
		E('em', {}, _('No monitors configured.')));
});
```

Initial `load()` returns UCI, status, and inventory; initial `statusRows()` receives `inventoryBySelector(data[2])`. Keep the existing per-row check-in-flight guard and refresh-after-check chain intact.

- [ ] **Step 5: Grant only read access to inventory**

Set the ACL read methods exactly to:

```json
"netwatch": [ "status", "interfaces" ]
```

Keep write methods exactly `check` and `test_email`. Do not grant LuCI direct read access to `network`, `wireless`, `network.interface`, `network.device`, or `network.wireless`; the daemon returns the sanitized inventory.

- [ ] **Step 6: Regenerate and verify the translation template mechanically**

With Docker running, execute the LuCI scanner from the pinned SDK tree:

```sh
./scripts/in-sdk.sh sh -ec '
  cd /sdk/feeds/luci
  ./build/i18n-scan.pl \
    /src/packages/netwatch/luci-app-netwatch \
    > /src/packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot
'
```

Set the catalog header to `Project-Id-Version: luci-app-netwatch 1.1.0` and a `2026-07-18` creation date if the scanner emits generic header values. The existing translation-literal test must report neither missing nor unexpected `msgid` values.

- [ ] **Step 7: Run complete static and UI-adjacent unit verification**

```sh
./tests/static.sh
./tests/run-unit.sh \
  tests/unit/interfaces_test.uc \
  tests/unit/interface_probe_test.uc \
  tests/unit/store_test.uc \
  tests/unit/message_test.uc
```

Expected: all checks PASS; ACL is least privilege, all view literals are cataloged, and interface result text is DOM-safe normalized text.

- [ ] **Step 8: Commit status, ACL, catalog, and safety gates**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/status.js \
  packages/netwatch/luci-app-netwatch/root/usr/share/rpcd/acl.d/luci-app-netwatch.json \
  packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot \
  tests/static.sh
git --git-dir=work/git-metadata --work-tree=. commit \
  -m "feat: show interface health in LuCI"
```

### Task 9: Version 1.1.0 Release Metadata and Documentation

**Files:**
- Modify: `packages/netwatch/netwatch/Makefile:3-20`
- Modify: `packages/netwatch/luci-app-netwatch/Makefile:1-8`
- Modify: `README.md:1-294`
- Modify: `scripts/package-output.sh:42-66`
- Modify: `scripts/verify-artifacts.sh:5-150`
- Modify: `tests/package-output_test.sh:8-54`
- Modify: `tests/static.sh:14-113`

**Interfaces:**
- Consumes: Completed feature source and package manifest layout.
- Produces: exact `1.1.0-r1` build/output/feed expectations, updated file manifest, upgrade instructions, and interface configuration documentation.

- [ ] **Step 1: Change tests to require the new release before changing production metadata**

Update package-output and static test expectations from `1.0.0-r1` to `1.1.0-r1`, source archive `openwrt-netwatch-1.1.0-source.tar.gz`, and package version `1.1.0`. Add the three new runtime module paths to `scripts/verify-artifacts.sh`'s expected manifest and require them in `tests/static.sh`. Leave `tests/feed_test.sh` on the currently published revision until Task 11 begins its artifact-specific red/green cycle.

- [ ] **Step 2: Run release tests and observe old-version failures**

```sh
./tests/package-output_test.sh
./tests/static.sh
```

Expected: FAIL because package Makefiles, scripts, README, and output expectations still identify `1.0.0-r1`.

- [ ] **Step 3: Bump both package Makefiles and descriptions**

Set:

```make
PKG_VERSION:=1.1.0
PKG_RELEASE:=1
```

Update the runtime title/description to include host, TCP service, and network-interface monitoring. Keep dependencies unchanged: diagnostics rely only on already-present ubus/UCI/fs/uloop modules and optional fixed system utilities. Do not add a hard `iwinfo` dependency; absence is reported as incomplete diagnostics.

- [ ] **Step 4: Update output, verification, and fixture filenames**

Mechanically replace the old version in `scripts/package-output.sh`, `scripts/verify-artifacts.sh`, and `tests/package-output_test.sh`. The runtime manifest list becomes:

```text
usr/share/netwatch/alerts.uc
usr/share/netwatch/config.uc
usr/share/netwatch/diagnostics.uc
usr/share/netwatch/interface_probe.uc
usr/share/netwatch/interfaces.uc
usr/share/netwatch/message.uc
usr/share/netwatch/netwatchd.uc
usr/share/netwatch/ping.uc
usr/share/netwatch/probe.uc
usr/share/netwatch/state.uc
usr/share/netwatch/store.uc
```

Keep the exact dependency assertions and protected conffile/mode/credential checks.

- [ ] **Step 5: Document interface monitoring and trusted upgrade**

Update README summary, build outputs, verification suite list, and configuration section. Record exactly 16 runtime manifest paths and seven LuCI manifest paths after the three new ucode modules are added. Add this representative UCI example:

```sh
uci set netwatch.office_wifi=monitor
uci set netwatch.office_wifi.enabled='1'
uci set netwatch.office_wifi.name='Office Wi-Fi'
uci set netwatch.office_wifi.type='interface'
uci set netwatch.office_wifi.interface_selector='wifi-iface:office'
uci set netwatch.office_wifi.interval='60'
uci set netwatch.office_wifi.timeout='5'
uci set netwatch.office_wifi.failures='3'
uci set netwatch.office_wifi.initial_delay='300'
uci set netwatch.office_wifi.repeat_interval='1800'
uci set netwatch.office_wifi.max_alerts='5'
uci set netwatch.office_wifi.recovery_email='1'
uci commit netwatch
/etc/init.d/netwatch restart
```

Explain selector kinds, custom SSID labels, disabled/absent selection, fresh diagnostics, redaction, and bounds. Change the trusted upgrade command to:

```sh
apk update
apk upgrade netwatch luci-app-netwatch
/etc/init.d/netwatch restart
```

Document `ubus call netwatch interfaces` next to status/log troubleshooting.

- [ ] **Step 6: Run release metadata, documentation, and unit checks**

```sh
./tests/package-output_test.sh
./tests/static.sh
./tests/run-unit.sh \
  tests/unit/config_test.uc \
  tests/unit/interfaces_test.uc \
  tests/unit/interface_probe_test.uc \
  tests/unit/diagnostics_test.uc \
  tests/unit/ping_test.uc \
  tests/unit/probe_test.uc \
  tests/unit/state_test.uc \
  tests/unit/store_test.uc \
  tests/unit/alerts_test.uc \
  tests/unit/message_test.uc
```

Expected: package-output, static, and all ten unit suites PASS. The published-feed expectation remains unchanged here and receives its own red/green cycle in Task 11.

- [ ] **Step 7: Commit source release metadata**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  packages/netwatch/netwatch/Makefile \
  packages/netwatch/luci-app-netwatch/Makefile \
  README.md scripts/package-output.sh scripts/verify-artifacts.sh \
  tests/package-output_test.sh tests/static.sh
git --git-dir=work/git-metadata --work-tree=. commit \
  -m "chore: prepare netwatch 1.1.0"
```

### Task 10: Full Source Verification and Clean SDK Build

**Files:**
- Generate ignored: `outputs/netwatch_1.1.0-r1_all.apk`
- Generate ignored: `outputs/luci-app-netwatch_1.1.0-r1_all.apk`
- Generate ignored: `outputs/openwrt-netwatch-1.1.0-source.tar.gz`
- Generate ignored: `outputs/SHA256SUMS`

**Interfaces:**
- Consumes: Clean committed `1.1.0-r1` source tree and existing OpenWrt SDK container/image/volume.
- Produces: pristine package artifacts and fresh evidence for unit, static, metadata, manifest, mode, secret, checksum, and source-snapshot correctness.

- [ ] **Step 1: Verify the source tree and build environment before the long build**

```sh
git --git-dir=work/git-metadata --work-tree=. status --short
find . -name .DS_Store -print
docker info >/dev/null
test -f work/signing/private-key.pem
test -f keys/netwatch-local.pem
```

Expected: tracked tree clean, no `.DS_Store` output, Docker available, and both key files present. If Docker Desktop is stopped, start it and rerun `docker info`; do not modify source to work around an unavailable daemon.

- [ ] **Step 2: Run every fast test from the clean commit**

```sh
./tests/repository-layout_test.sh
./tests/package-output_test.sh
./tests/static.sh
./tests/run-unit.sh \
  tests/unit/config_test.uc \
  tests/unit/interfaces_test.uc \
  tests/unit/interface_probe_test.uc \
  tests/unit/diagnostics_test.uc \
  tests/unit/ping_test.uc \
  tests/unit/probe_test.uc \
  tests/unit/state_test.uc \
  tests/unit/store_test.uc \
  tests/unit/alerts_test.uc \
  tests/unit/message_test.uc
git --git-dir=work/git-metadata --work-tree=. diff --check
```

Expected: every command exits 0.

- [ ] **Step 3: Build both packages in the pinned SDK**

```sh
./scripts/in-sdk.sh ./scripts/build-packages.sh
```

Expected final lines identify exactly one `netwatch-1.1.0-r1.apk` and exactly one `luci-app-netwatch-1.1.0-r1.apk`. If duplicate matching outputs are reported, remove only stale matching artifacts under `work/sdk/bin/packages` and rerun the clean build script.

- [ ] **Step 4: Package stable outputs from the clean Git commit**

```sh
./scripts/package-output.sh
shasum -a 256 -c outputs/SHA256SUMS
```

Expected: all three artifact checksums report `OK`; the source archive comes from committed `HEAD`, not untracked workspace files.

- [ ] **Step 5: Inspect manifests and package contents**

```sh
./scripts/verify-artifacts.sh
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk adbdump --format json \
  /src/outputs/netwatch_1.1.0-r1_all.apk | jq .info
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk adbdump --format json \
  /src/outputs/luci-app-netwatch_1.1.0-r1_all.apk | jq .info
```

Expected: artifact verification PASS; both manifests show `1.1.0-r1` and `noarch`; runtime contents include the three new modules; no credential fixture or writable packaged file is found.

- [ ] **Step 6: Preserve pristine outputs for the signing task**

```sh
cp outputs/netwatch_1.1.0-r1_all.apk \
  work/netwatch-1.1.0-r1.pristine.apk
cp outputs/luci-app-netwatch_1.1.0-r1_all.apk \
  work/luci-app-netwatch-1.1.0-r1.pristine.apk
shasum -a 256 \
  work/netwatch-1.1.0-r1.pristine.apk \
  work/luci-app-netwatch-1.1.0-r1.pristine.apk
```

Expected: ignored pristine copies exist. A failed signing attempt must be retried only after recopying from these untouched files.

### Task 11: Sign, Publish, and Remotely Verify the Upgrade

**Files:**
- Delete: `feed/x86_64/netwatch-1.0.0-r1.apk`
- Delete: `feed/x86_64/luci-app-netwatch-1.0.0-r1.apk`
- Create: `feed/x86_64/netwatch-1.1.0-r1.apk`
- Create: `feed/x86_64/luci-app-netwatch-1.1.0-r1.apk`
- Modify: `feed/x86_64/packages.adb`
- Modify: `tests/feed_test.sh:19-28`
- External publish: `https://github.com/Delitants/openwrt-packages` branch `main`

**Interfaces:**
- Consumes: Pristine verified build outputs, ignored private key, committed public key, and existing nested feed.
- Produces: strictly verified signed APKs/index, pushed release commit, byte-matched raw GitHub files, and a disposable trusted-root resolution of both `1.1.0-r1` upgrades.

- [ ] **Step 1: Change the feed test to require only the new revision**

Change the two required package paths to:

```sh
feed/x86_64/netwatch-1.1.0-r1.apk
feed/x86_64/luci-app-netwatch-1.1.0-r1.apk
```

After the required-file loop, reject any obsolete Netwatch package revision while leaving unrelated future packages alone:

```sh
if find "$root/feed/x86_64" -maxdepth 1 -type f \
  \( -name 'netwatch-*.apk' -o -name 'luci-app-netwatch-*.apk' \) \
  ! -name 'netwatch-1.1.0-r1.apk' \
  ! -name 'luci-app-netwatch-1.1.0-r1.apk' -print | grep -q .; then
	echo 'obsolete Netwatch APK remains in feed' >&2
	exit 1
fi
```

Run:

```sh
./tests/feed_test.sh
```

Expected: FAIL because the new APKs do not exist yet and the old revision is still present.

- [ ] **Step 2: Replace old feed inputs with fresh pristine copies**

```sh
rm -f \
  feed/x86_64/netwatch-1.0.0-r1.apk \
  feed/x86_64/luci-app-netwatch-1.0.0-r1.apk
cp work/netwatch-1.1.0-r1.pristine.apk \
  feed/x86_64/netwatch-1.1.0-r1.apk
cp work/luci-app-netwatch-1.1.0-r1.pristine.apk \
  feed/x86_64/luci-app-netwatch-1.1.0-r1.apk
```

Expected: the feed contains the two new unsigned/SDK-signed inputs and no obsolete Netwatch revision. Unrelated future package APKs, if present, remain untouched.

- [ ] **Step 3: Sign each copied APK exactly once and strictly verify immediately**

```sh
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk \
  --allow-untrusted adbsign --reset-signatures \
  --sign-key /src/work/signing/private-key.pem \
  /src/feed/x86_64/netwatch-1.1.0-r1.apk
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk verify \
  --keys-dir /src/keys \
  /src/feed/x86_64/netwatch-1.1.0-r1.apk

./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk \
  --allow-untrusted adbsign --reset-signatures \
  --sign-key /src/work/signing/private-key.pem \
  /src/feed/x86_64/luci-app-netwatch-1.1.0-r1.apk
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk verify \
  --keys-dir /src/keys \
  /src/feed/x86_64/luci-app-netwatch-1.1.0-r1.apk
```

Expected: both strict verifies report success. If either signing call fails or reports an ADB block error, recopy that one pristine file and repeat one signing call; never run `adbsign` again on the failed modified copy.

- [ ] **Step 4: Rebuild and strictly verify the complete signed feed**

```sh
./scripts/rebuild-feed.sh x86_64 work/signing/private-key.pem
./scripts/in-sdk.sh sh -ec '
  apk=/sdk/staging_dir/host/bin/apk
  for file in \
    /src/feed/x86_64/netwatch-1.1.0-r1.apk \
    /src/feed/x86_64/luci-app-netwatch-1.1.0-r1.apk \
    /src/feed/x86_64/packages.adb
  do
    "$apk" verify --keys-dir /src/keys "$file"
  done
  "$apk" adbdump --format json /src/feed/x86_64/packages.adb
'
./tests/feed_test.sh
```

Expected: both APKs and `packages.adb` pass strict verification; the index JSON contains `netwatch` and `luci-app-netwatch` at `1.1.0-r1`; feed tests PASS.

- [ ] **Step 5: Audit release scope and forbidden files**

```sh
find . -name .DS_Store -print
git --git-dir=work/git-metadata --work-tree=. status --short
git --git-dir=work/git-metadata --work-tree=. ls-files | \
  grep -E '(^|/)(private-key|.*\.key)(\.pem)?$' && exit 1 || true
git --git-dir=work/git-metadata --work-tree=. diff --check
```

Expected: no `.DS_Store`, no tracked private key, and changes are limited to `tests/feed_test.sh`, deletion of the old APKs, the two new APKs, and the rebuilt index.

- [ ] **Step 6: Commit the signed release artifacts and their release gate**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  feed/x86_64/netwatch-1.0.0-r1.apk \
  feed/x86_64/luci-app-netwatch-1.0.0-r1.apk \
  feed/x86_64/netwatch-1.1.0-r1.apk \
  feed/x86_64/luci-app-netwatch-1.1.0-r1.apk \
  feed/x86_64/packages.adb tests/feed_test.sh
git --git-dir=work/git-metadata --work-tree=. commit \
  -m "build: publish netwatch 1.1.0"
```

- [ ] **Step 7: Run the final local verification from committed state**

```sh
./tests/repository-layout_test.sh
./tests/feed_test.sh
./tests/package-output_test.sh
./tests/static.sh
./tests/run-unit.sh \
  tests/unit/config_test.uc \
  tests/unit/interfaces_test.uc \
  tests/unit/interface_probe_test.uc \
  tests/unit/diagnostics_test.uc \
  tests/unit/ping_test.uc \
  tests/unit/probe_test.uc \
  tests/unit/state_test.uc \
  tests/unit/store_test.uc \
  tests/unit/alerts_test.uc \
  tests/unit/message_test.uc
./scripts/verify-artifacts.sh
git --git-dir=work/git-metadata --work-tree=. status --short
find . -name .DS_Store -print
```

Expected: every test and artifact check exits 0, Git status is empty, and the `.DS_Store` search is empty.

- [ ] **Step 8: Push the verified `main` branch**

```sh
git --git-dir=work/git-metadata --work-tree=. push origin main
git --git-dir=work/git-metadata --work-tree=. ls-remote origin refs/heads/main
git --git-dir=work/git-metadata --work-tree=. rev-parse HEAD
```

Expected: the remote and local commit hashes match.

- [ ] **Step 9: Download and byte-compare the public release**

```sh
rm -rf work/public-feed-check
mkdir -p work/public-feed-check
curl -fL --retry 12 --retry-delay 5 --retry-all-errors \
  https://raw.githubusercontent.com/Delitants/openwrt-packages/main/keys/netwatch-local.pem \
  -o work/public-feed-check/netwatch-local.pem
curl -fL --retry 12 --retry-delay 5 --retry-all-errors \
  https://raw.githubusercontent.com/Delitants/openwrt-packages/main/feed/x86_64/netwatch-1.1.0-r1.apk \
  -o work/public-feed-check/netwatch-1.1.0-r1.apk
curl -fL --retry 12 --retry-delay 5 --retry-all-errors \
  https://raw.githubusercontent.com/Delitants/openwrt-packages/main/feed/x86_64/luci-app-netwatch-1.1.0-r1.apk \
  -o work/public-feed-check/luci-app-netwatch-1.1.0-r1.apk
curl -fL --retry 12 --retry-delay 5 --retry-all-errors \
  https://raw.githubusercontent.com/Delitants/openwrt-packages/main/feed/x86_64/packages.adb \
  -o work/public-feed-check/packages.adb
cmp keys/netwatch-local.pem work/public-feed-check/netwatch-local.pem
cmp feed/x86_64/netwatch-1.1.0-r1.apk work/public-feed-check/netwatch-1.1.0-r1.apk
cmp feed/x86_64/luci-app-netwatch-1.1.0-r1.apk \
  work/public-feed-check/luci-app-netwatch-1.1.0-r1.apk
cmp feed/x86_64/packages.adb work/public-feed-check/packages.adb
```

Expected: every `curl` succeeds and every `cmp` is silent with exit code 0.

- [ ] **Step 10: Strictly verify downloaded artifacts with the downloaded public key**

```sh
mkdir -p work/public-feed-check/keys
cp work/public-feed-check/netwatch-local.pem \
  work/public-feed-check/keys/netwatch-local.pem
./scripts/in-sdk.sh sh -ec '
  apk=/sdk/staging_dir/host/bin/apk
  for file in \
    /src/work/public-feed-check/netwatch-1.1.0-r1.apk \
    /src/work/public-feed-check/luci-app-netwatch-1.1.0-r1.apk \
    /src/work/public-feed-check/packages.adb
  do
    "$apk" verify --keys-dir /src/work/public-feed-check/keys "$file"
  done
'
```

Expected: all three downloaded artifacts pass strict verification without `--allow-untrusted`.

- [ ] **Step 11: Resolve both upgrades from the public URL in a disposable APK root**

```sh
rm -rf work/public-apk-root
mkdir -p \
  work/public-apk-root/etc/apk/keys \
  work/public-apk-root/etc/apk
cp work/public-feed-check/netwatch-local.pem \
  work/public-apk-root/etc/apk/keys/netwatch-local.pem
printf '%s\n' \
  'https://raw.githubusercontent.com/Delitants/openwrt-packages/main/feed/x86_64/packages.adb' \
  > work/public-apk-root/etc/apk/repositories
./scripts/in-sdk.sh sh -ec '
  apk=/sdk/staging_dir/host/bin/apk
  root=/src/work/public-apk-root
  keys=$root/etc/apk/keys
  repos=$root/etc/apk/repositories
  "$apk" --root "$root" --keys-dir "$keys" \
    --repositories-file "$repos" add --initdb
  "$apk" --root "$root" --keys-dir "$keys" \
    --repositories-file "$repos" update
  "$apk" --root "$root" --keys-dir "$keys" \
    --repositories-file "$repos" add --simulate \
    netwatch=1.1.0-r1 luci-app-netwatch=1.1.0-r1
'
```

Expected: database initialization precedes update; the public index is trusted; simulated installation resolves exactly both `1.1.0-r1` packages and their official dependencies.

- [ ] **Step 12: Record final release evidence**

```sh
git --git-dir=work/git-metadata --work-tree=. log -3 --oneline
shasum -a 256 \
  feed/x86_64/netwatch-1.1.0-r1.apk \
  feed/x86_64/luci-app-netwatch-1.1.0-r1.apk \
  feed/x86_64/packages.adb \
  keys/netwatch-local.pem
git --git-dir=work/git-metadata --work-tree=. status --short
find . -name .DS_Store -print
```

Expected: release hashes are captured for handoff, Git is clean, and no `.DS_Store` exists.

## Specification Coverage Map

- Stable selectors, configured/live merging, disabled/absent candidates, custom SSIDs, and duplicate disambiguation: Tasks 1-2 and 7.
- Logical network, Linux device, radio, and AP health plus all nine failure reasons: Task 3.
- Existing timing, repeat, cap, retry, and recovery behavior: Tasks 3, 5, and 6 using the unchanged incident scheduler.
- Fresh diagnostics on every due failure email, 15-second deadline, 64 KiB/200-line limits, redaction, partial failure, and email fallback: Tasks 4 and 6.
- Concise recovery snapshot and non-persistence of full reports: Task 5.
- LuCI dropdown/status, missing selection preservation, transition time, evidence, and least-privilege ACL: Tasks 7-8.
- Package version, documentation, clean SDK build, signing, nested feed, GitHub publication, and trusted remote upgrade resolution: Tasks 9-11.
