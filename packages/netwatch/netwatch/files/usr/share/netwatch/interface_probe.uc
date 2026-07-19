import { parse_interface_selector, collect_interface_snapshot_with } from 'interfaces';
import * as fs from 'fs';
import * as ubus from 'ubus';
import * as uci from 'uci';

function answer(ok, reason, summary, parsed, candidate, observed_at, evidence) {
	return {
		ok,
		reason,
		summary,
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

function source_available(snapshot, source) {
	return snapshot?.sources?.[source] === true;
};

function operstate_down(value) {
	return value in [ 'down', 'lowerlayerdown', 'notpresent' ];
};

function device_facts(snapshot, name) {
	let runtime = snapshot?.runtime?.devices?.[name];
	let sys_devices = snapshot?.runtime?.sys_devices ?? [];
	let device_available = source_available(snapshot, 'device_runtime');
	let sysfs_available = source_available(snapshot, 'sysfs_devices');
	let runtime_present = device_available
		? runtime == null ? false : runtime.present === true ? true :
			runtime.present === false ? false : null
		: null;
	let sysfs_present = sysfs_available ? name in sys_devices : null;
	let present = runtime_present != null && sysfs_present != null &&
		runtime_present != sysfs_present ? null :
		runtime_present === true || sysfs_present === true ? true :
		runtime_present === false || sysfs_present === false ? false : null;
	let sysfs_state = sysfs_available && sysfs_present === true;

	return {
		present,
		up: device_available ? runtime?.up ?? null : null,
		carrier: sysfs_state || device_available ? runtime?.carrier ?? null : null,
		operstate: sysfs_state || device_available ? runtime?.operstate ?? null : null,
		mtu: sysfs_state || device_available ? runtime?.mtu ?? null : null
	};
};

function invalid_answer(selector, observed_at) {
	return {
		ok: false,
		reason: 'status_unavailable',
		summary: 'interface selector is invalid',
		selector,
		kind: null,
		configured_name: null,
		label: selector,
		live_device: null,
		observed_at,
		evidence: {}
	};
};

export function evaluate_interface(selector, snapshot, observed_at) {
	let parsed = parse_interface_selector(selector);
	if (!parsed) return invalid_answer(selector, observed_at);

	if (parsed.kind == 'network') {
		let config = configured(snapshot, 'networks', 'id', parsed.id);
		let runtime = logical_runtime(snapshot, parsed.id);
		let candidate = {
			configured_name: parsed.id,
			label: config?.description ?? parsed.id,
			live_device: runtime?.device ?? null
		};
		let evidence = {
			up: runtime?.up ?? null,
			available: runtime?.available ?? null,
			auto: config?.auto ?? runtime?.autostart ?? null,
			device: runtime?.device ?? null,
			proto: runtime?.proto ?? config?.proto ?? null
		};

		if (config?.disabled === true || config?.auto === false || runtime?.autostart === false)
			return answer(false, 'administratively_disabled',
				'logical network is disabled', parsed, candidate, observed_at, evidence);
		if (!source_available(snapshot, 'logical_runtime') ||
			(!source_available(snapshot, 'network_interfaces') && runtime?.autostart !== true))
			return answer(false, 'status_unavailable',
				'logical network state is unavailable', parsed, candidate, observed_at, evidence);
		if (!runtime)
			return answer(false, 'interface_absent',
				'logical network has no runtime state', parsed, candidate, observed_at, evidence);
		if (runtime.available === false)
			return answer(false, 'unavailable',
				'netifd reports the logical network unavailable', parsed, candidate, observed_at, evidence);
		if (runtime.available !== true)
			return answer(false, 'status_unavailable',
				'logical network state is indeterminate', parsed, candidate, observed_at, evidence);
		if (runtime.up === false)
			return answer(false, 'link_down',
				'logical network is not up', parsed, candidate, observed_at, evidence);
		if (runtime.up !== true)
			return answer(false, 'status_unavailable',
				'logical network state is indeterminate', parsed, candidate, observed_at, evidence);
		return answer(true, null, 'logical network is up',
			parsed, candidate, observed_at, evidence);
	}

	if (parsed.kind == 'device') {
		let config = configured(snapshot, 'devices', 'name', parsed.id);
		let facts = device_facts(snapshot, parsed.id);
		let candidate = {
			configured_name: parsed.id,
			label: parsed.id,
			live_device: facts.present === true ? parsed.id : null
		};
		let evidence = {
			present: facts.present,
			up: facts.up,
			carrier: facts.carrier,
			operstate: facts.operstate,
			mtu: facts.mtu
		};

		if (config?.disabled === true)
			return answer(false, 'administratively_disabled',
				'device is disabled in configuration', parsed, candidate, observed_at, evidence);
		if (!source_available(snapshot, 'network_devices'))
			return answer(false, 'status_unavailable',
				'device configuration state is unavailable', parsed, candidate, observed_at, evidence);
		if (facts.present == null)
			return answer(false, 'status_unavailable',
				'device presence is indeterminate', parsed, candidate, observed_at, evidence);
		if (facts.present === false)
			return answer(false, 'interface_absent',
				'device is not present', parsed, candidate, observed_at, evidence);
		if ((facts.up === false && facts.operstate == 'up') ||
			(facts.up === true && operstate_down(facts.operstate)))
			return answer(false, 'status_unavailable',
				'device operational state is contradictory', parsed, candidate, observed_at, evidence);
		if (operstate_down(facts.operstate) || facts.up === false)
			return answer(false, 'link_down',
				'device is not operationally up', parsed, candidate, observed_at, evidence);
		if (facts.carrier === false)
			return answer(false, 'carrier_lost',
				'device reports no carrier', parsed, candidate, observed_at, evidence);
		if (facts.up !== true && facts.operstate != 'up')
			return answer(false, 'status_unavailable',
				'device operational state is indeterminate', parsed, candidate, observed_at, evidence);
		return answer(true, null, 'device is operationally up',
			parsed, candidate, observed_at, evidence);
	}

	if (parsed.kind == 'wifi-radio') {
		let config = configured(snapshot, 'radios', 'id', parsed.id);
		let runtime = snapshot?.runtime?.wireless?.[parsed.id];
		let candidate = { configured_name: parsed.id, label: parsed.id, live_device: null };
		let evidence = {
			up: runtime?.up ?? null,
			pending: runtime?.pending ?? null,
			disabled: runtime?.disabled ?? config?.disabled ?? null,
			retry_setup_failed: runtime?.retry_setup_failed ?? null
		};

		if (config?.disabled === true || runtime?.disabled === true || runtime?.autostart === false)
			return answer(false, 'administratively_disabled',
				'wireless radio is disabled', parsed, candidate, observed_at, evidence);
		if (!source_available(snapshot, 'wireless_radios') ||
			!source_available(snapshot, 'wireless_runtime'))
			return answer(false, 'status_unavailable',
				'wireless radio state is unavailable', parsed, candidate, observed_at, evidence);
		if (runtime?.retry_setup_failed === true)
			return answer(false, 'wireless_initialization_failed',
				'wireless radio initialization failed', parsed, candidate, observed_at, evidence);
		if (!config || !runtime)
			return answer(false, 'wireless_radio_down',
				'wireless radio is not running', parsed, candidate, observed_at, evidence);
		if (runtime.up === false)
			return answer(false, 'wireless_radio_down',
				'wireless radio is not running', parsed, candidate, observed_at, evidence);
		if (runtime.up !== true)
			return answer(false, 'status_unavailable',
				'wireless radio state is indeterminate', parsed, candidate, observed_at, evidence);
		return answer(true, null, 'wireless radio is running',
			parsed, candidate, observed_at, evidence);
	}

	let config = configured(snapshot, 'wifi_ifaces', 'id', parsed.id);
	let parent = configured(snapshot, 'radios', 'id', config?.device);
	let runtime_radio = snapshot?.runtime?.wireless?.[config?.device];
	let runtime_iface = wireless_iface(snapshot, config?.device, parsed.id);
	let live = runtime_iface?.ifname
		? device_facts(snapshot, runtime_iface.ifname)
		: { present: false, up: null, operstate: null };
	let ap_name = config?.ssid ?? config?.mesh_id ?? 'unnamed';
	let ap_suffix = `${config?.device ?? 'unknown-radio'} / ${parsed.id}`;
	if (runtime_iface?.ifname) ap_suffix += ` (${runtime_iface.ifname})`;
	let candidate = {
		configured_name: parsed.id,
		label: `AP: ${ap_name} — ${ap_suffix}`,
		live_device: runtime_iface?.ifname ?? null
	};
	let evidence = {
		radio: config?.device ?? null,
		ssid: config?.ssid ?? null,
		radio_up: runtime_radio?.up ?? null,
		present: !!runtime_iface,
		ifname: runtime_iface?.ifname ?? null,
		live_present: live.present,
		device_up: live.up,
		device_operstate: live.operstate
	};

	if (config?.disabled === true || parent?.disabled === true ||
		runtime_radio?.disabled === true || runtime_radio?.autostart === false)
		return answer(false, 'administratively_disabled',
			'wireless AP or parent radio is disabled', parsed, candidate, observed_at, evidence);
	if (!source_available(snapshot, 'wireless_aps') ||
		!source_available(snapshot, 'wireless_radios') ||
		!source_available(snapshot, 'wireless_runtime'))
		return answer(false, 'status_unavailable',
			'wireless AP state is unavailable', parsed, candidate, observed_at, evidence);
	if (runtime_radio?.retry_setup_failed === true)
		return answer(false, 'wireless_initialization_failed',
			'wireless AP initialization failed', parsed, candidate, observed_at, evidence);
	if (!config || !parent || !runtime_radio)
		return answer(false, 'wireless_ap_down',
			'wireless AP is not running', parsed, candidate, observed_at, evidence);
	if (!runtime_iface || !runtime_iface.ifname)
		return answer(false, 'wireless_ap_down',
			'wireless AP is not running', parsed, candidate, observed_at, evidence);
	if (runtime_radio.up === false)
		return answer(false, 'wireless_ap_down',
			'wireless AP is not running', parsed, candidate, observed_at, evidence);
	if (runtime_radio.up !== true || live.present == null)
		return answer(false, 'status_unavailable',
			'wireless AP state is indeterminate', parsed, candidate, observed_at, evidence);
	if ((live.up === false && live.operstate == 'up') ||
		(live.up === true && operstate_down(live.operstate)))
		return answer(false, 'status_unavailable',
			'wireless AP device state is contradictory', parsed, candidate, observed_at, evidence);
	if (live.present === false || live.up === false || operstate_down(live.operstate))
		return answer(false, 'wireless_ap_down',
			'wireless AP is not running', parsed, candidate, observed_at, evidence);
	if (live.up !== true && live.operstate != 'up')
		return answer(false, 'status_unavailable',
			'wireless AP device state is indeterminate', parsed, candidate, observed_at, evidence);
	return answer(true, null, 'wireless AP is running',
		parsed, candidate, observed_at, evidence);
};

export function run_interface_with(monitor, deps) {
	return evaluate_interface(monitor.interface_selector, deps.snapshot(), deps.clock());
};

export function run_interface(monitor) {
	return run_interface_with(monitor, {
		clock: () => time(),
		snapshot: () => {
			let cursor = null;
			let connection = null;
			let adapter_errors = [];

			try { cursor = uci.cursor(); }
			catch (error) { push(adapter_errors, 'uci unavailable'); }
			try {
				connection = ubus.connect();
				if (!connection) push(adapter_errors, 'ubus unavailable');
			}
			catch (error) { push(adapter_errors, 'ubus unavailable'); }

			let snapshot = collect_interface_snapshot_with({
				foreach: (config, section_type, callback) => {
					if (!cursor) die('unavailable');
					return cursor.foreach(config, section_type, callback);
				},
				call: (object, method, args) => {
					if (!connection) die('unavailable');
					return connection.call(object, method, args);
				},
				lsdir: (path) => fs.lsdir(path),
				readfile: (path, limit) => fs.readfile(path, limit)
			});
			for (let error in adapter_errors) push(snapshot.errors, error);
			return snapshot;
		}
	});
};
