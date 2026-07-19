import { deep_equal, equal } from 'test';
import { compact_evidence, compact_evidence_json, compact_result } from 'result';

let current_evidence = {
	up: true, available: true, auto: false, device: 'eth0', proto: 'dhcp',
	present: true, carrier: false, operstate: 'down', mtu: 1500,
	pending: false, disabled: false, retry_setup_failed: false,
	radio: 'radio0', ssid: 'Office', radio_up: true, ifname: 'phy0-ap0',
	live_present: true, device_up: true, device_operstate: 'up'
};
deep_equal(compact_evidence(current_evidence), current_evidence,
	'current interface evidence schema remains unchanged');
equal(compact_evidence_json(current_evidence), sprintf('%J', current_evidence),
	'current interface evidence serializes unchanged');

deep_equal(compact_evidence({
	present: false,
	secret: 'unknown-secret',
	nested: { password: 'nested-secret' },
	list: [ 'array-secret' ],
	ssid: 'office\ncontrol-secret'
}), { present: false }, 'unknown nested array and control evidence dropped');

let oversized = '';
for (let i = 0; i < 5000; i++) oversized += 'x';
deep_equal(compact_evidence({ ssid: oversized }), {},
	'oversized evidence dropped');
equal(compact_evidence_json({ ssid: oversized }), sprintf('%J', {}),
	'oversized evidence serialization is bounded');

deep_equal(compact_result({
	ok: false, reason: 'wireless_ap_down', summary: 'wireless AP is not running',
	selector: 'wifi-iface:office', kind: 'wifi-iface', configured_name: 'office',
	label: 'AP: Office', live_device: 'phy0-ap0', observed_at: 100,
	evidence: { present: false, secret: 'result-evidence-secret' },
	diagnostic: { text: 'result-diagnostic-secret' },
	raw_snapshot: { password: 'result-snapshot-secret' },
	smtp: { password: 'result-smtp-secret' },
	config: { password: 'result-config-secret' }, secret: 'result-top-secret'
}), {
	ok: false, reason: 'wireless_ap_down', summary: 'wireless AP is not running',
	selector: 'wifi-iface:office', kind: 'wifi-iface', configured_name: 'office',
	label: 'AP: Office', live_device: 'phy0-ap0', observed_at: 100,
	evidence: { present: false }
}, 'result normalizer retains only approved compact fields');

deep_equal(compact_result({
	ok: false, reason: 'timeout', loss: 100, avg_rtt: null, detail: 'timed out',
	secret: 'host-secret'
}), {
	ok: false, reason: 'timeout', loss: 100, avg_rtt: null, detail: 'timed out'
}, 'host probe result fields remain compatible');
