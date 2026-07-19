import { deep_equal, equal } from 'test';
import { new_state, apply_result } from 'state';

let monitor = { enabled: true, failures: 3, recovery_email: true };
let good = {
	ok: true, reason: null, loss: 0, avg_rtt: 12.5, detail: 'reachable'
};
let bad = {
	ok: false, reason: 'timeout', loss: 100, avg_rtt: null, detail: 'timed out'
};

let fresh = new_state('stable-keys');
deep_equal(fresh, {
	id: 'stable-keys', status: 'unknown', consecutive_failures: 0,
	last_check: null, last_result: null, incident_started: null,
	last_transition: null,
	failure_emails: 0, last_email: null, next_mail_attempt: null,
	recovery_eligible: false, recovery_pending: null,
	busy: false, config_error: null
}, 'new state exposes stable keys');

let s = new_state('cfg001');
equal(apply_result(s, monitor, good, 100), 'became_healthy', 'initial success');
equal(apply_result(s, monitor, bad, 200), 'pending', 'first failure');
equal(apply_result(s, monitor, bad, 260), 'pending', 'second failure');
equal(apply_result(s, monitor, bad, 320), 'opened', 'third failure opens');
equal(s.incident_started, 320, 'incident timestamp');
equal(apply_result(s, monitor, bad, 350), 'failed', 'unchanged failure stays failed');
equal(s.incident_started, 320, 'unchanged failure does not reopen incident');
equal(apply_result(s, monitor, good, 380), 'recovered', 'recovery transition');
equal(s.failure_emails, 0, 'new healthy state clears incident count');
equal(s.recovery_pending, null, 'unalerted incident has no recovery email');

let pending = new_state('pending-reset');
equal(apply_result(pending, monitor, bad, 500), 'pending', 'pending reset first failure');
equal(apply_result(pending, monitor, good, 560), 'became_healthy', 'pending success becomes healthy');
equal(pending.consecutive_failures, 0, 'pending success clears consecutive failures');

let disabled = new_state('disabled');
equal(apply_result(disabled, { enabled: false, failures: 1 }, bad, 600),
	'disabled', 'disabled monitor transition');
equal(disabled.status, 'disabled', 'disabled monitor remains disabled');
equal(disabled.consecutive_failures, 0, 'disabled monitor does not count failures');

let alerted = new_state('alerted');
let immediate = { enabled: true, failures: 1, recovery_email: true };
equal(apply_result(alerted, immediate, bad, 700), 'opened', 'alerted incident opens');
alerted.failure_emails = 2;
alerted.last_email = 720;
alerted.next_mail_attempt = 800;
alerted.recovery_eligible = true;
equal(apply_result(alerted, immediate, good, 760), 'recovered', 'alerted incident recovers');
deep_equal(alerted.recovery_pending, {
	incident_started: 700,
	recovered_at: 760,
	failure_emails: 2,
	last_result: bad,
	recovered_result: good
}, 'recovery preserves completed incident details');
equal(alerted.incident_started, null, 'recovery clears active incident timestamp');
equal(alerted.failure_emails, 0, 'recovery clears successful failure-email count');
equal(alerted.last_email, null, 'recovery clears active incident mail timestamp');
equal(alerted.next_mail_attempt, 800, 'recovery preserves global mail retry time');
equal(alerted.recovery_eligible, false, 'recovery clears active eligibility');

equal(apply_result(alerted, immediate, bad, 900), 'opened', 'later failure opens new incident');
equal(alerted.recovery_pending, null, 'new incident drops stale recovery notification');
equal(alerted.failure_emails, 0, 'new incident receives fresh failure-email allowance');

let disabled_recovery = new_state('no-recovery-mail');
let recovery_off = { enabled: true, failures: 1, recovery_email: false };
equal(apply_result(disabled_recovery, recovery_off, bad, 1000), 'opened',
	'recovery-disabled incident opens');
disabled_recovery.recovery_eligible = true;
disabled_recovery.failure_emails = 1;
equal(apply_result(disabled_recovery, recovery_off, good, 1060), 'recovered',
	'recovery-disabled incident closes');
equal(disabled_recovery.recovery_pending, null,
	'recovery-disabled monitor does not queue recovery email');

let interface_state = new_state('wifi');
let interface_monitor = { enabled: true, failures: 1, recovery_email: true };
let failed_interface = {
	ok: false, reason: 'wireless_ap_down', selector: 'wifi-iface:office'
};
let recovered_interface = {
	ok: true, reason: null, selector: 'wifi-iface:office',
	label: 'AP: Office', live_device: 'phy0-ap0', evidence: { present: true }
};
equal(apply_result(interface_state, interface_monitor, failed_interface, 100), 'opened',
	'interface incident opens');
equal(interface_state.last_transition, 100, 'failed transition time recorded');
interface_state.recovery_eligible = true;
equal(apply_result(interface_state, interface_monitor, recovered_interface, 160), 'recovered',
	'interface incident recovers');
equal(interface_state.last_transition, 160, 'recovery transition time recorded');
deep_equal(interface_state.recovery_pending.recovered_result, recovered_interface,
	'fresh recovery result retained for concise recovery email');

let transitions = new_state('transition-matrix');
let transition_monitor = { enabled: true, failures: 3, recovery_email: true };
equal(apply_result(transitions, transition_monitor, good, 1100), 'became_healthy',
	'unknown becomes healthy');
equal(transitions.last_transition, 1100, 'unknown to healthy records transition');
equal(apply_result(transitions, transition_monitor, good, 1110), 'healthy',
	'healthy remains healthy');
equal(transitions.last_transition, 1100, 'unchanged healthy preserves transition');
equal(apply_result(transitions, transition_monitor, bad, 1120), 'pending',
	'healthy becomes pending');
equal(transitions.last_transition, 1120, 'healthy to pending records transition');
equal(apply_result(transitions, transition_monitor, bad, 1130), 'pending',
	'pending remains pending');
equal(transitions.last_transition, 1120, 'unchanged pending preserves transition');
equal(apply_result(transitions, transition_monitor, bad, 1140), 'opened',
	'pending becomes failed');
equal(transitions.last_transition, 1140, 'pending to failed records transition');
equal(apply_result(transitions, transition_monitor, bad, 1150), 'failed',
	'failed remains failed');
equal(transitions.last_transition, 1140, 'unchanged failed preserves transition');
equal(apply_result(transitions, transition_monitor, good, 1160), 'recovered',
	'failed becomes healthy');
equal(transitions.last_transition, 1160, 'failed to healthy records transition');
equal(apply_result(transitions, { ...transition_monitor, enabled: false }, null, 1170),
	'disabled', 'healthy becomes disabled');
equal(transitions.last_transition, 1170, 'disable records transition');
equal(apply_result(transitions, { ...transition_monitor, enabled: false }, null, 1180),
	'disabled', 'disabled remains disabled');
equal(transitions.last_transition, 1170, 'unchanged disabled preserves transition');
equal(apply_result(transitions, transition_monitor, good, 1190), 'became_healthy',
	'disabled monitor re-enables healthy');
equal(transitions.last_transition, 1190, 're-enable records transition');

let tainted_interface = new_state('tainted-interface');
let tainted_failure = {
	ok: false, reason: 'wireless_ap_down', summary: 'wireless AP is not running',
	selector: 'wifi-iface:office', kind: 'wifi-iface', configured_name: 'office',
	label: 'AP: Office', live_device: 'phy0-ap0', observed_at: 1200,
	evidence: {
		radio: 'radio0', present: false, secret: 'failure-evidence-secret',
		nested: { password: 'failure-nested-secret' }, list: [ 'failure-array-secret' ],
		ssid: 'office\ncontrol-secret'
	},
	diagnostic: { text: 'failure-diagnostic-secret' },
	raw_snapshot: { password: 'failure-snapshot-secret' },
	smtp: { password: 'failure-smtp-secret' },
	config: { password: 'failure-config-secret' },
	secret: 'failure-top-secret'
};
equal(apply_result(tainted_interface, immediate, tainted_failure, 1200), 'opened',
	'tainted interface failure opens');
let retained_failure = sprintf('%J', tainted_interface.last_result);
for (let secret in [
	'failure-evidence-secret', 'failure-nested-secret', 'failure-array-secret',
	'control-secret', 'failure-diagnostic-secret', 'failure-snapshot-secret',
	'failure-smtp-secret', 'failure-config-secret', 'failure-top-secret'
])
	equal(length(split(retained_failure, secret)), 1,
		`${secret} absent from retained failure`);

tainted_interface.recovery_eligible = true;
let tainted_recovery = {
	...recovered_interface, summary: 'wireless AP is running', kind: 'wifi-iface',
	configured_name: 'office', observed_at: 1260,
	evidence: {
		present: true, secret: 'recovery-evidence-secret',
		nested: { password: 'recovery-nested-secret' }
	},
	diagnostic: { text: 'recovery-diagnostic-secret' },
	raw_snapshot: { password: 'recovery-snapshot-secret' },
	config: { password: 'recovery-config-secret' },
	secret: 'recovery-top-secret'
};
equal(apply_result(tainted_interface, immediate, tainted_recovery, 1260), 'recovered',
	'tainted interface incident recovers');
let retained_recovery = sprintf('%J', tainted_interface.recovery_pending);
for (let secret in [
	'failure-evidence-secret', 'failure-diagnostic-secret', 'failure-snapshot-secret',
	'recovery-evidence-secret', 'recovery-nested-secret', 'recovery-diagnostic-secret',
	'recovery-snapshot-secret', 'recovery-config-secret', 'recovery-top-secret'
])
	equal(length(split(retained_recovery, secret)), 1,
		`${secret} absent from recovery state`);

let oversized_interface = new_state('oversized-interface');
let oversized_ssid = '';
for (let i = 0; i < 5000; i++) oversized_ssid += 'x';
equal(apply_result(oversized_interface, immediate, {
	...tainted_failure, evidence: { ssid: oversized_ssid }
}, 1300), 'opened', 'oversized evidence failure opens');
deep_equal(oversized_interface.last_result.evidence, {},
	'oversized evidence dropped before state retention');
