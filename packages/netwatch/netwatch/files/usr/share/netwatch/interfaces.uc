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
	let groups = map(GROUPS, group => ({ id: group.id, label: group.label, items: [] }));
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
		if (ap.mode != 'ap') continue;
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
	if (!connection) return { groups: map(GROUPS, g => ({ id: g.id, label: g.label, items: [] })), errors: [ 'ubus unavailable' ] };
	let snapshot = collect_interface_snapshot_with({
		foreach: (config, section_type, callback) => cursor.foreach(config, section_type, callback),
		call: (object, method, args) => connection.call(object, method, args),
		lsdir: (path) => fs.lsdir(path),
		readfile: (path, limit) => fs.readfile(path, limit)
	});
	return inventory_from_snapshot(snapshot);
};
