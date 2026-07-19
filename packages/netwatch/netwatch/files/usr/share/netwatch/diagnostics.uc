import * as fs from 'fs';
import * as ubus from 'ubus';
import * as uci from 'uci';
import { parse_interface_selector, collect_interface_snapshot_with } from 'interfaces';

const REPORT_LIMIT = 65536;
const SECTION_LIMIT = 16384;
const ERROR_LIMIT = 64;
const ERROR_TEXT_LIMIT = 512;
const LOG_LINE_LIMIT = 200;
const COMMAND_OUTPUT_LIMIT = 262144;
const TASK_TIMEOUT_MS = 15000;

const SAFE_NETWORK = [
	'id', 'proto', 'device', 'ifname', 'auto', 'disabled', 'metric', 'mtu', 'description'
];
const SAFE_DEVICE = [ 'name', 'type', 'ports', 'mtu', 'macaddr', 'disabled' ];
const SAFE_RADIO = [ 'id', 'type', 'path', 'band', 'channel', 'country', 'htmode', 'disabled' ];
const SAFE_WIFI_IFACE = [
	'id', 'device', 'mode', 'ssid', 'mesh_id', 'network', 'encryption', 'disabled'
];
const SAFE_RUNTIME_INTERFACE = [
	'interface', 'up', 'pending', 'available', 'autostart', 'dynamic',
	'proto', 'device', 'l3_device', 'uptime', 'metric', 'errors',
	'ipv4-address', 'ipv6-address'
];
const SAFE_RUNTIME_DEVICE = [
	'present', 'up', 'carrier', 'operstate', 'type', 'mtu', 'macaddr',
	'rx_bytes', 'rx_packets', 'rx_errors', 'tx_bytes', 'tx_packets', 'tx_errors'
];
const SAFE_RUNTIME_RADIO = [
	'up', 'pending', 'autostart', 'disabled', 'retry_setup_failed'
];
const SAFE_RUNTIME_WIFI_IFACE = [ 'section', 'ifname' ];
const SAFE_SOURCES = [
	'network_interfaces', 'network_devices', 'wireless_radios', 'wireless_aps',
	'logical_runtime', 'device_runtime', 'wireless_runtime', 'sysfs_devices'
];
const SAFE_RESULT = [
	'ok', 'reason', 'summary', 'selector', 'kind', 'configured_name', 'label',
	'live_device', 'observed_at'
];
const SAFE_EVIDENCE = [
	'up', 'available', 'auto', 'device', 'proto', 'present', 'carrier',
	'operstate', 'mtu', 'pending', 'disabled', 'retry_setup_failed',
	'radio', 'ssid', 'radio_up', 'ifname', 'live_present', 'device_up',
	'device_operstate'
];

const COMMAND_PATHS = {
	link: '/sbin/ip',
	iwinfo: '/usr/bin/iwinfo',
	logread: '/sbin/logread'
};

function clean_text(value) {
	if (value == null) return '';
	value = type(value) == 'string' ? value : sprintf('%J', value);
	value = replace(value, /\r\n?/g, '\n');
	return join('\n', map(split(value, '\n'),
		line => replace(line, /[[:cntrl:]]/g, ' ')));
};

export function redact_diagnostic_text(value) {
	value = clean_text(value);
	for (let pattern in [
		/(\b(key|password|passphrase|(wpa_)?psk|sae(_password)?|radius(_secret|_key|_password)?|smtp(_password|_pass)?|secret|credential|token|api_key)\s*[:=]\s*)("[^"]*"|'[^']*'|[^\n,;]+)/gi,
		/("(key|password|passphrase|(wpa_)?psk|sae(_password)?|radius(_secret|_key|_password)?|smtp(_password|_pass)?|secret|credential|token|api_key)"\s*:\s*)("[^"]*"|'[^']*'|[^\n,;]+)/gi,
		/((authorization|proxy-authorization)\s*:\s*)[^\n]+/gi,
		/(-----BEGIN [^-]*PRIVATE KEY-----)[\s\S]*?(-----END [^-]*PRIVATE KEY-----)/gi
	])
		value = replace(value, pattern, '$1[REDACTED]');
	return value;
};

function truncate_text(value, maximum, marker) {
	value = clean_text(value);
	if (length(value) <= maximum) return { text: value, truncated: false };
	marker = marker ?? '\n[truncated]\n';
	let cut = maximum - length(marker);
	while (cut > 0) {
		let byte = ord(substr(value, cut, 1));
		if (byte < 128 || byte >= 192) break;
		cut--;
	}
	return { text: substr(value, 0, cut) + marker, truncated: true };
};

function newest_lines(value, maximum) {
	let values = split(clean_text(value), '\n');
	let truncated = length(values) > maximum;
	if (truncated) values = slice(values, length(values) - maximum);
	return { text: join('\n', values), truncated };
};

function scalar_fields(value, names) {
	let output = {};
	for (let name in names) {
		let field = value?.[name];
		if (field != null && type(field) in [ 'string', 'int', 'double', 'bool' ])
			output[name] = field;
	}
	return output;
};

function normalized_errors(errors) {
	let output = [];
	for (let error in slice(errors ?? [], 0, ERROR_LIMIT)) {
		let limited = truncate_text(redact_diagnostic_text(error), ERROR_TEXT_LIMIT,
			' [truncated]');
		push(output, limited.text);
	}
	if (length(errors ?? []) > ERROR_LIMIT)
		push(output, 'additional collection errors omitted');
	return output;
};

export function render_diagnostic_report(sections, errors) {
	let chunks = [];
	let truncated = false;
	for (let section in sections ?? []) {
		let value = section?.log
			? newest_lines(section?.text, LOG_LINE_LIMIT)
			: { text: clean_text(section?.text), truncated: false };
		let limited = truncate_text(redact_diagnostic_text(value.text), SECTION_LIMIT,
			'\n[section truncated]\n');
		truncated = truncated || value.truncated || limited.truncated;
		let title = truncate_text(redact_diagnostic_text(section?.title ?? 'Diagnostic'),
			256, ' [truncated]').text;
		push(chunks, `## ${title}\n${limited.text}`);
	}

	let safe_errors = normalized_errors(errors);
	if (length(safe_errors))
		push(chunks, '## Diagnostic collection incomplete\n' +
			join('\n', map(safe_errors, error => `- ${error}`)));

	let total = truncate_text(join('\n\n', chunks) + '\n', REPORT_LIMIT,
		'\n[report truncated]\n');
	return {
		text: total.text,
		incomplete: length(safe_errors) > 0,
		errors: safe_errors,
		truncated: truncated || total.truncated
	};
};

function relevant_logs(value, names) {
	let output = [];
	for (let line in split(clean_text(value), '\n')) {
		let lower = lc(line);
		let relevant = match(lower,
			/netifd|hostapd|wpa_supplicant|mac80211|cfg80211|ath[0-9a-z]*|iwlwifi|mt76/);
		for (let name in names)
			if (type(name) == 'string' && length(name) && index(lower, lc(name)) >= 0)
				relevant = true;
		if (relevant) push(output, line);
	}
	return newest_lines(join('\n', output), LOG_LINE_LIMIT).text;
};

function safe_device_name(value) {
	return type(value) == 'string' && length(value) <= 64 &&
		!!match(value, /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/);
};

function selected_state(snapshot, parsed, result) {
	let output = {
		selector: `${parsed.kind}:${parsed.id}`,
		result: scalar_fields(result, SAFE_RESULT),
		sources: scalar_fields(snapshot?.sources, SAFE_SOURCES)
	};
	output.result.live_device = safe_device_name(result?.live_device)
		? result.live_device : null;
	output.result.evidence = scalar_fields(result?.evidence, SAFE_EVIDENCE);

	let collection = parsed.kind == 'network' ? [ 'networks', 'id', SAFE_NETWORK ]
		: parsed.kind == 'device' ? [ 'devices', 'name', SAFE_DEVICE ]
		: parsed.kind == 'wifi-radio' ? [ 'radios', 'id', SAFE_RADIO ]
		: [ 'wifi_ifaces', 'id', SAFE_WIFI_IFACE ];
	for (let value in snapshot?.configured?.[collection[0]] ?? [])
		if (value?.[collection[1]] == parsed.id)
			output.configured = scalar_fields(value, collection[2]);

	if (parsed.kind == 'network') {
		for (let value in snapshot?.runtime?.interfaces ?? [])
			if (value?.interface == parsed.id)
				output.runtime = scalar_fields(value, SAFE_RUNTIME_INTERFACE);
	}
	else if (parsed.kind == 'device') {
		output.runtime = scalar_fields(snapshot?.runtime?.devices?.[parsed.id],
			SAFE_RUNTIME_DEVICE);
	}
	else if (parsed.kind == 'wifi-radio') {
		output.runtime = scalar_fields(snapshot?.runtime?.wireless?.[parsed.id],
			SAFE_RUNTIME_RADIO);
	}
	else {
		let radio_id = output.configured?.device;
		let radio = snapshot?.runtime?.wireless?.[radio_id];
		output.radio = scalar_fields(radio, SAFE_RUNTIME_RADIO);
		for (let value in radio?.interfaces ?? []) {
			if (value?.section != parsed.id) continue;
			output.runtime = scalar_fields(value, SAFE_RUNTIME_WIFI_IFACE);
			output.runtime.config = scalar_fields(value?.config, SAFE_WIFI_IFACE);
		}
	}

	return output;
};

function dependency_value(fn, fallback, errors, reason) {
	try { return type(fn) == 'function' ? fn() : fallback; }
	catch (error) { push(errors, reason); return fallback; }
};

function command_value(deps, name, command, errors, reason) {
	let value;
	try { value = deps.command(name, command); }
	catch (error) { push(errors, reason); return null; }
	if (value == null) {
		push(errors, reason);
		return null;
	}
	if (type(value) == 'object') {
		if (value.ok === false) push(errors, reason);
		return value.text ?? '';
	}
	return value;
};

export function collect_diagnostics_with(monitor, result, deps) {
	let parsed = parse_interface_selector(monitor?.interface_selector);
	if (!parsed)
		return render_diagnostic_report([], [ 'interface selector is invalid' ]);

	let errors = [];
	let sections = [];
	let snapshot = dependency_value(deps?.snapshot,
		{ configured: {}, runtime: {}, sources: {}, errors: [] }, errors,
		'state snapshot unavailable');
	if (type(snapshot) != 'object') {
		snapshot = { configured: {}, runtime: {}, sources: {}, errors: [] };
		push(errors, 'state snapshot unavailable');
	}
	for (let error in snapshot?.errors ?? []) push(errors, error);

	let selected = selected_state(snapshot, parsed, result);
	selected.collected_at = dependency_value(deps?.clock, null, errors,
		'collection time unavailable');
	push(sections, {
		title: 'Interface identity and observed state',
		text: sprintf('%J', selected)
	});

	let device = result?.live_device ?? (parsed.kind == 'device' ? parsed.id : null);
	if (device && !safe_device_name(device)) {
		push(errors, 'live device name is invalid');
		device = null;
	}
	if (device) {
		let sysfs = {};
		let sysfs_failed = false;
		for (let name in [ 'operstate', 'carrier', 'mtu', 'address',
			'statistics/rx_bytes', 'statistics/rx_packets', 'statistics/rx_errors',
			'statistics/tx_bytes', 'statistics/tx_packets', 'statistics/tx_errors' ]) {
			let value = null;
			try { value = deps.readfile(`/sys/class/net/${device}/${name}`, 4096); }
			catch (error) { sysfs_failed = true; }
			if (value != null) sysfs[name] = trim(clean_text(value));
		}
		let driver = null;
		try { driver = deps.readlink(`/sys/class/net/${device}/device/driver`); }
		catch (error) { sysfs_failed = true; }
		if (driver) sysfs.driver = driver;
		if (sysfs_failed) push(errors, 'kernel interface facts incomplete');
		push(sections, { title: 'Kernel interface facts', text: sprintf('%J', sysfs) });

		let link = command_value(deps, 'link',
			`/sbin/ip -details address show dev '${device}' 2>&1`, errors,
			'link details unavailable');
		if (link != null)
			push(sections, { title: 'Address and link details', text: link });
	}

	if (parsed.kind in [ 'wifi-radio', 'wifi-iface' ]) {
		let iw_target = device ?? parsed.id;
		let iwinfo = command_value(deps, 'iwinfo',
			`/usr/bin/iwinfo '${iw_target}' info 2>&1`, errors,
			'iwinfo unavailable');
		if (iwinfo != null)
			push(sections, { title: 'Wireless status', text: iwinfo });
	}

	let log_text = command_value(deps, 'logread', '/sbin/logread 2>&1', errors,
		'system log unavailable');
	if (log_text != null) {
		let filtered = relevant_logs(log_text,
			[ parsed.id, selected?.configured?.device, device, result?.label ]);
		push(sections, { title: 'Recent relevant logs', text: filtered, log: true });
	}

	return render_diagnostic_report(sections, errors);
};

function valid_command(name, command) {
	if (name == 'logread') return command == '/sbin/logread 2>&1';
	if (name == 'link')
		return !!match(command,
			/^\/sbin\/ip -details address show dev '[A-Za-z0-9_][A-Za-z0-9_.-]*' 2>&1$/);
	if (name == 'iwinfo')
		return !!match(command,
			/^\/usr\/bin\/iwinfo '[A-Za-z0-9_][A-Za-z0-9_.-]*' info 2>&1$/);
	return false;
};

function command_output(name, command) {
	let path = COMMAND_PATHS[name];
	if (!path || !valid_command(name, command)) return null;
	try { if (!fs.stat(path)) return null; }
	catch (error) { return null; }

	let process;
	try { process = fs.popen(command, 'r'); }
	catch (error) { return null; }
	if (!process) return null;

	let output = '';
	let read_ok = true;
	try { output = process.read(COMMAND_OUTPUT_LIMIT) ?? ''; }
	catch (error) { read_ok = false; }
	let status = null;
	try { status = process.close(); }
	catch (error) { read_ok = false; }
	if (!read_ok) return null;
	return { text: output, ok: status === 0 };
};

export function collect_diagnostics(monitor, result) {
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

	return collect_diagnostics_with(monitor, result, {
		clock: () => time(),
		snapshot: () => {
			let snapshot = collect_interface_snapshot_with({
				foreach: (config, type, callback) => {
					if (!cursor) die('unavailable');
					return cursor.foreach(config, type, callback);
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
		},
		readfile: (path, limit) => fs.readfile(path, limit),
		readlink: (path) => fs.readlink(path),
		command: command_output
	});
};

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
		if (timeout_handle) {
			try { timeout_handle.cancel(); }
			catch (error) { }
		}
		callback(type(report) == 'object' && type(report.text) == 'string'
			? report : incomplete_report('diagnostic collector failed'));
	};

	try {
		task_handle = deps.uloop.task(
			() => {
				try { return deps.collect(monitor, result); }
				catch (error) { return incomplete_report('diagnostic collector failed'); }
			},
			(report) => finish(report)
		);
	}
	catch (error) { return false; }
	if (!task_handle) return false;

	try {
		timeout_handle = deps.uloop.timer(TASK_TIMEOUT_MS, () => {
			let fired = timeout_handle;
			timeout_handle = null;
			if (fired) {
				try { fired.cancel(); }
				catch (error) { }
			}
			try { if (!task_handle.finished()) task_handle.kill(); }
			catch (error) { }
			finish(incomplete_report('diagnostic collector timed out'));
		});
	}
	catch (error) { timeout_handle = null; }
	if (!timeout_handle) {
		completed = true;
		try { task_handle.kill(); }
		catch (error) { }
		return false;
	}
	return true;
};

export function start_diagnostics(monitor, result, callback) {
	return start_diagnostics_with(monitor, result, callback, {
		uloop: require('uloop'),
		collect: collect_diagnostics
	});
};
