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
