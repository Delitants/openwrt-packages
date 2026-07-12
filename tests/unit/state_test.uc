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
	last_result: bad
}, 'recovery preserves completed incident details');
equal(alerted.incident_started, null, 'recovery clears active incident timestamp');
equal(alerted.failure_emails, 0, 'recovery clears successful failure-email count');
equal(alerted.last_email, null, 'recovery clears active incident mail timestamp');
equal(alerted.next_mail_attempt, null, 'recovery clears active incident retry time');
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
