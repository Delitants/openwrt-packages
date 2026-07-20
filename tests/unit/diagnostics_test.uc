import { equal, truthy } from 'test';
import {
	redact_diagnostic_text,
	render_diagnostic_report,
	collect_diagnostics_with,
	command_output_with,
	start_diagnostics_with
} from 'diagnostics';

function repeated(value, count) {
	let output = '';
	for (let i = 0; i < count; i++) output += value;
	return output;
};

function valid_utf8(value) {
	for (let offset = 0; offset < length(value);) {
		let first = ord(substr(value, offset, 1));
		let width;
		if (first < 128) width = 1;
		else if (first >= 194 && first <= 223) width = 2;
		else if (first >= 224 && first <= 239) width = 3;
		else if (first >= 240 && first <= 244) width = 4;
		else return false;
		if (offset + width > length(value)) return false;
		if (width > 1) {
			let second = ord(substr(value, offset + 1, 1));
			if (second < 128 || second > 191 ||
				(first == 224 && second < 160) ||
				(first == 237 && second > 159) ||
				(first == 240 && second < 144) ||
				(first == 244 && second > 143)) return false;
		}
		for (let index = 2; index < width; index++) {
			let continuation = ord(substr(value, offset + index, 1));
			if (continuation < 128 || continuation > 191) return false;
		}
		offset += width;
	}
	return true;
};

let secret_text = 'ssid=Office\nkey=wifi-secret\npassword: smtp secret phrase\n' +
	'psk=wireless-secret\nsae=sae secret phrase\nradius_key=radius-secret\n' +
	'smtp_password=mail-secret\nAuthorization: Bearer token-value';
let redacted = redact_diagnostic_text(secret_text);
for (let secret in [ 'wifi-secret', 'smtp secret phrase', 'wireless-secret',
	'sae secret phrase', 'radius-secret', 'mail-secret', 'token-value' ])
	equal(match(redacted, regexp(secret)), null, `${secret} redacted`);
truthy(match(redacted, /\[REDACTED\]/), 'redaction marker present');

let adversarial_text = 'private_key=private-alias-secret\r\n' +
	'passphrase=passphrase-secret\nwpa_psk=wpa-secret\n' +
	'sae_password=sae-password-secret\nradius_secret=radius-secret-value\n' +
	'radius_password=radius-password-secret\nsmtp_pass=smtp-pass-secret\n' +
	'secret=generic-secret\ncredential=credential-secret\n' +
	'token=token-secret\napi_key=api-key-secret\n' +
	"option key 'uci-option-secret'\nlist sae_password 'uci-list-secret'\n" +
	"key 'quoted-whitespace-secret'\npassphrase whitespace-passphrase-secret\n" +
	'psk whitespace-secret\npassword bare-whitespace-secret\n' +
	'Proxy-Authorization: Basic proxy-header-secret\n' +
	'"Authorization":"Bearer json-bearer-secret"\n' +
	'"proxy-authorization":"Bearer json-proxy-secret"\n' +
	'"password":"escaped\\\"quote-secret"\n' +
	'password=alpha,beta;gamma\n' +
	'-----BEGIN PRIVATE KEY-----\r\npem-line-one-secret\r\n' +
	'pem-line-two-secret\n-----END PRIVATE KEY-----';
let redacted_twice = redact_diagnostic_text(
	redact_diagnostic_text(adversarial_text));
for (let secret in [ 'private-alias-secret', 'json-bearer-secret',
	'passphrase-secret', 'wpa-secret', 'sae-password-secret',
	'radius-secret-value', 'radius-password-secret', 'smtp-pass-secret',
	'generic-secret', 'credential-secret', 'token-secret', 'api-key-secret',
	'uci-option-secret', 'uci-list-secret', 'whitespace-secret',
	'quoted-whitespace-secret', 'whitespace-passphrase-secret',
	'bare-whitespace-secret',
	'proxy-header-secret', 'json-proxy-secret', 'escaped', 'quote-secret',
	'alpha', 'beta', 'gamma',
	'pem-line-one-secret', 'pem-line-two-secret' ])
	equal(match(redacted_twice, regexp(secret)), null,
		`${secret} absent after second redaction pass`);
truthy(match(redacted_twice, /\[REDACTED\]/),
	'adversarial redaction emits marker');

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
truthy(match(bounded.text, /\[older relevant log lines omitted\]/),
	'email marks omitted older relevant log lines');
truthy(match(bounded.text, /netifd line 259/), 'newest log line retained');

let long_error = render_diagnostic_report([], [ repeated('x', 600) ]);
truthy(long_error.truncated, 'truncated error sets report truncation metadata');
let many_errors = [];
for (let i = 0; i < 70; i++) push(many_errors, `source ${i} unavailable`);
let omitted_errors = render_diagnostic_report([], many_errors);
truthy(omitted_errors.truncated, 'omitted errors set report truncation metadata');
truthy(match(omitted_errors.text, /additional collection errors omitted/),
	'error omission notice rendered');

let multibyte_sections = [];
let per_section_multibyte = render_diagnostic_report([
	{ title: 'Per-section multibyte', text: repeated('€', 6000) }
], []);
truthy(length(per_section_multibyte.text) <= 16432,
	'multibyte section body bounded to 16 KiB plus fixed framing');
truthy(match(per_section_multibyte.text, /section truncated/),
	'per-section multibyte truncation rendered');
truthy(valid_utf8(per_section_multibyte.text),
	'per-section multibyte cut retains valid UTF-8');
for (let i = 0; i < 6; i++)
	push(multibyte_sections, { title: `Multibyte ${i}`, text: repeated('€', 6000) });
truthy(length(repeated('€', 6000)) * length(multibyte_sections) > 65536,
	'aggregate fixture exceeds 64 KiB before rendering');
let multibyte = render_diagnostic_report(multibyte_sections,
	[ 'wireless status unavailable' ]);
truthy(length(multibyte.text) <= 65536,
	'aggregate multibyte report bounded to 64 KiB');
truthy(multibyte.truncated, 'aggregate multibyte truncation reported');
truthy(valid_utf8(multibyte.text),
	'per-section and aggregate multibyte cuts retain valid UTF-8');
truthy(match(multibyte.text, /Diagnostic collection incomplete/),
	'incomplete footer remains visible under aggregate truncation');
truthy(match(multibyte.text, /wireless status unavailable/),
	'bounded source failure remains visible under aggregate truncation');

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

let required_reads = [];
let degraded_sysfs = collect_diagnostics_with(
	{ type: 'interface', interface_selector: 'device:eth0' },
	{ reason: 'link_down', label: 'eth0', live_device: 'eth0', evidence: {} },
	{
		clock: () => 1700000100,
		snapshot: () => ({ configured: { devices: [ { name: 'eth0' } ] },
			runtime: { devices: { eth0: { up: false } } }, sources: {}, errors: [] }),
		readfile: (path, limit) => {
			push(required_reads, path);
			return path == '/sys/class/net/eth0/operstate' ? 'down\n' : null;
		},
		readlink: (path) => null,
		command: (name, command) => name == 'logread'
			? 'netifd: eth0 link failed' : 'link details'
	});
equal(length(required_reads), 10, 'all fixed required sysfs facts attempted');
truthy(match(degraded_sysfs.text, /"operstate"\s*:\s*"down"/),
	'successful sysfs fact preserved through partial read failure');
truthy(degraded_sysfs.incomplete, 'null required sysfs reads mark report incomplete');
truthy(match(degraded_sysfs.text, /kernel interface facts incomplete/),
	'bounded required sysfs failure detail rendered');
truthy(length(degraded_sysfs.text) <= 65536,
	'degraded sysfs report remains bounded');

let optional_driver = collect_diagnostics_with(
	{ type: 'interface', interface_selector: 'device:eth0' },
	{ reason: null, label: 'eth0', live_device: 'eth0', evidence: {} },
	{
		clock: () => 1700000100,
		snapshot: () => ({ configured: { devices: [ { name: 'eth0' } ] },
			runtime: { devices: { eth0: { up: true } } }, sources: {}, errors: [] }),
		readfile: (path, limit) => match(path, /\/address$/)
			? '00:11:22:33:44:55\n' : '1\n',
		readlink: (path) => null,
		command: (name, command) => name == 'logread'
			? 'netifd: eth0 link ready' : 'link details'
	});
equal(optional_driver.incomplete, false,
	'optional driver symlink absence does not degrade report');

let correlated_lines = [];
for (let i = 0; i < 260; i++) push(correlated_lines, `netifd: lan event ${i}`);
for (let line in [
	'netifd: wan failed',
	'hostapd: guest disabled',
	'netifd: vlan20 lost link',
	'netifd: lan-backup lost link',
	'kernel: br-lan carrier lost'
]) push(correlated_lines, line);
let correlated = collect_diagnostics_with(
	{ type: 'interface', interface_selector: 'network:lan' },
	{ reason: 'link_down', label: 'Local network', live_device: 'br-lan',
		evidence: { device: 'br-lan' } },
	{
		clock: () => 1700000100,
		snapshot: () => ({
			configured: { networks: [ { id: 'lan', device: 'br-lan' } ] },
			runtime: { interfaces: [ { interface: 'lan', device: 'br-lan' } ] },
			sources: {}, errors: []
		}),
		readfile: (path, limit) => null,
		readlink: (path) => null,
		command: (name, command) => name == 'logread'
			? join('\n', correlated_lines) : 'link details'
	});
for (let unrelated in [ 'wan failed', 'guest disabled', 'vlan20', 'lan-backup' ])
	equal(match(correlated.text, regexp(unrelated)), null,
		`${unrelated} log excluded without exact selected token`);
truthy(match(correlated.text, /kernel: br-lan carrier lost/),
	'exact child device token retains kernel log');
equal(match(correlated.text, /netifd: lan event 0\n/), null,
	'oldest correlated log line discarded');
truthy(match(correlated.text, /netifd: lan event 259/),
	'newest correlated log line retained');
let retained_correlated_lines = 0;
for (let line in split(correlated.text, '\n'))
	if (match(line, /^(netifd: lan event [0-9]+|kernel: br-lan carrier lost)$/))
		retained_correlated_lines++;
equal(retained_correlated_lines, 200,
	'exactly newest 200 selected-object log lines retained');
truthy(correlated.truncated,
	'discarded correlated log lines set report truncation metadata');

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

let command_paths = [];
let command_opens = [];
let command_limits = [];
let command_io = {
	stat: (path) => { push(command_paths, path); return {}; },
	popen: (command, mode) => {
		push(command_opens, `${mode}:${command}`);
		return {
			read: (limit) => { push(command_limits, limit); return `output for ${command}`; },
			close: () => 0
		};
	}
};
for (let operation in [
	[ 'link', "/sbin/ip -details address show dev 'eth0' 2>&1" ],
	[ 'iwinfo', "/usr/bin/iwinfo 'phy0-ap0' info 2>&1" ],
	[ 'logread', '/sbin/logread 2>&1' ]
]) {
	let command_result = command_output_with(operation[0], operation[1], command_io);
	truthy(command_result.ok, `${operation[0]} exact command accepted`);
	truthy(match(command_result.text, /output for/),
		`${operation[0]} output retained`);
}
equal(join(',', command_paths), '/sbin/ip,/usr/bin/iwinfo,/sbin/logread',
	'only fixed executable paths checked');
equal(join(',', command_limits), '262144,262144,262144',
	'every command read capped at 262144 bytes');
truthy(match(join('\n', command_opens), /^r:\/sbin\/ip/),
	'fixed command opened read-only');

let rejected_io_calls = 0;
let rejected_io = {
	stat: (path) => { rejected_io_calls++; return {}; },
	popen: (command, mode) => { rejected_io_calls++; return null; }
};
for (let operation in [
	[ 'link', "/sbin/ip -details address show dev 'eth0';reboot' 2>&1" ],
	[ 'link', "/sbin/ip -details address show dev 'eth0' 2>&1 extra" ],
	[ 'iwinfo', "/usr/bin/iwinfo 'phy0-ap0;reboot' info 2>&1" ],
	[ 'logread', '/sbin/logread --all 2>&1' ],
	[ 'other', '/sbin/logread 2>&1' ],
	[ 'link', `/sbin/ip -details address show dev '${repeated('a', 65)}' 2>&1` ]
])
	equal(command_output_with(operation[0], operation[1], rejected_io), null,
		`${operation[0]} non-fixed command rejected`);
equal(rejected_io_calls, 0, 'rejected templates never reach filesystem or process I/O');

let missing_opens = 0;
equal(command_output_with('iwinfo', "/usr/bin/iwinfo 'radio0' info 2>&1", {
	stat: (path) => null,
	popen: (command, mode) => { missing_opens++; return null; }
}), null, 'missing optional executable rejected');
equal(missing_opens, 0, 'missing executable never opened');

let failed_command = command_output_with('link',
	"/sbin/ip -details address show dev 'eth0' 2>&1", {
		stat: (path) => ({}),
		popen: (command, mode) => ({
			read: (limit) => 'partial link facts',
			close: () => 2
		})
	});
equal(failed_command.text, 'partial link facts',
	'nonzero command status retains successful output');
equal(failed_command.ok, false, 'nonzero command status reported');

let failed_collection = collect_diagnostics_with(
	{ type: 'interface', interface_selector: 'device:eth0' },
	{ reason: 'link_down', label: 'eth0', live_device: 'eth0', evidence: {} },
	{
		clock: () => 1700000100,
		snapshot: () => ({ configured: { devices: [ { name: 'eth0' } ] },
			runtime: { devices: { eth0: { up: false } } }, sources: {}, errors: [] }),
		readfile: (path, limit) => null,
		readlink: (path) => null,
		command: (name, command) => command_output_with(name, command, {
			stat: (path) => ({}),
			popen: (fixed, mode) => ({
				read: (limit) => name == 'link'
					? 'partial link facts' : 'netifd: eth0 link failed',
				close: () => name == 'link' ? 2 : 0
			})
		})
	});
truthy(match(failed_collection.text, /partial link facts/),
	'failed command output retained in report');
truthy(match(failed_collection.text, /link details unavailable/),
	'failed command error rendered');
truthy(failed_collection.incomplete,
	'failed command status marks collection incomplete');

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
