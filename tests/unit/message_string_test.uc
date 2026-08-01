import { truthy } from 'test';
import { render_message } from 'message';

let output = render_message('failure', {
	smtp: { from: 'router@example.test', from_name: '' },
	recipients: 'ops@example.test',
	monitor: { id: 'wifi', name: 'Wi-Fi', type: 'interface',
		interface_selector: 'wifi-iface:office', max_alerts: 1 },
	state: { incident_started: 1700000000, failure_emails: 0,
		last_check: 1700000001, last_result: {
			ok: false, reason: 'administratively_disabled',
			summary: 'wireless AP is disabled', selector: 'wifi-iface:office',
			kind: 'wifi-iface', configured_name: 'office', label: 'AP: Office',
			evidence: { present: false }
		} },
	router_hostname: 'router', timestamp: 1700000002,
	diagnostic: { text: '', incomplete: false, errors: [], truncated: false }
});

truthy(match(output, /\nTo: ops@example\.test\n/),
	'raw recipient string renders without importing parser');
