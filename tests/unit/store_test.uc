import { deep_equal, equal, truthy } from 'test';
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

let tainted_status = public_status(10, 20, null, [ {
	id: 'wifi', status: 'failed', last_check: 30, last_transition: 25,
	last_result: {
		ok: false, reason: 'wireless_ap_down', summary: 'wireless AP is not running',
		selector: 'wifi-iface:office', kind: 'wifi-iface', configured_name: 'office',
		label: 'AP: Office', live_device: 'phy0-ap0', observed_at: 30,
		evidence: {
			present: false, secret: 'public-evidence-secret',
			nested: { password: 'public-nested-secret' },
			ssid: 'office\npublic-control-secret'
		},
		diagnostic: { text: 'public-diagnostic-secret' },
		raw_snapshot: { password: 'public-snapshot-secret' },
		smtp: { password: 'public-smtp-secret' },
		config: { password: 'public-config-secret' },
		secret: 'public-top-secret'
	},
	consecutive_failures: 3, incident_started: 25, failure_emails: 1,
	config_error: null
} ]);
let serialized_status = sprintf('%J', tainted_status);
for (let secret in [
	'public-evidence-secret', 'public-nested-secret', 'public-control-secret',
	'public-diagnostic-secret', 'public-snapshot-secret', 'public-smtp-secret',
	'public-config-secret', 'public-top-secret'
])
	equal(length(split(serialized_status, secret)), 1,
		`${secret} absent from public status`);
deep_equal(tainted_status.monitors[0].last_result.evidence, { present: false },
	'public status defensively compacts evidence');
