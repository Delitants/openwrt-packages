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
