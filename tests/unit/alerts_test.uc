import { equal } from 'test';
import { due_alert, mail_succeeded, mail_failed } from 'alerts';
import { new_state, apply_result } from 'state';

function failed_state(started) {
	return {
		status: 'failed', incident_started: started,
		failure_emails: 0, last_email: null, next_mail_attempt: null,
		recovery_eligible: false, recovery_pending: null
	};
};

let delayed = failed_state(1000);
let delayed_monitor = { initial_delay: 300, repeat_interval: 0, max_alerts: 1 };
equal(due_alert(delayed, delayed_monitor, 1299), null,
	'first alert waits for initial delay');
equal(due_alert(delayed, delayed_monitor, 1300), 'failure',
	'first alert is due at incident start plus initial delay');

let one_time = failed_state(2000);
let one_time_monitor = { initial_delay: 0, repeat_interval: 0, max_alerts: 5 };
equal(due_alert(one_time, one_time_monitor, 2000), 'failure',
	'one-time alert is initially due');
mail_succeeded(one_time, 'failure', 2000);
equal(one_time.failure_emails, 1, 'successful failure mail increments count');
equal(one_time.last_email, 2000, 'successful failure mail records send time');
equal(one_time.recovery_eligible, true,
	'successful failure mail makes recovery eligible');
equal(due_alert(one_time, one_time_monitor, 10000), null,
	'one-time mode stops after first successful send');

let ten = failed_state(3000);
let ten_monitor = { initial_delay: 0, repeat_interval: 600, max_alerts: 3 };
mail_succeeded(ten, 'failure', 3000);
equal(due_alert(ten, ten_monitor, 3599), null, 'ten-minute repeat waits');
equal(due_alert(ten, ten_monitor, 3600), 'failure', 'ten-minute repeat becomes due');

let thirty = failed_state(4000);
let thirty_monitor = { initial_delay: 0, repeat_interval: 1800, max_alerts: 3 };
mail_succeeded(thirty, 'failure', 4000);
equal(due_alert(thirty, thirty_monitor, 5799), null, 'thirty-minute repeat waits');
equal(due_alert(thirty, thirty_monitor, 5800), 'failure',
	'thirty-minute repeat becomes due');

let sixty = failed_state(5000);
let sixty_monitor = { initial_delay: 0, repeat_interval: 3600, max_alerts: 3 };
mail_succeeded(sixty, 'failure', 5000);
equal(due_alert(sixty, sixty_monitor, 8599), null, 'sixty-minute repeat waits');
equal(due_alert(sixty, sixty_monitor, 8600), 'failure',
	'sixty-minute repeat becomes due');

let capped = failed_state(6000);
let capped_monitor = { initial_delay: 0, repeat_interval: 600, max_alerts: 2 };
mail_succeeded(capped, 'failure', 6000);
mail_succeeded(capped, 'failure', 6600);
equal(capped.failure_emails, 2, 'successful failure mails reach cap');
equal(due_alert(capped, capped_monitor, 7200), null,
	'maximum successful failure-email count stops alerts');

let retry = failed_state(0);
let retry_monitor = { initial_delay: 0, repeat_interval: 600, max_alerts: 3 };
equal(due_alert(retry, retry_monitor, 0), 'failure', 'failure alert starts due');
mail_failed(retry, 100, 300);
equal(retry.failure_emails, 0, 'failed send does not consume alert allowance');
equal(retry.recovery_eligible, false, 'failed send does not enable recovery mail');
equal(retry.next_mail_attempt, 400, 'failed send records retry backoff');
equal(due_alert(retry, retry_monitor, 399), null, 'retry backoff suppresses early send');
equal(due_alert(retry, retry_monitor, 400), 'failure',
	'failed failure mail becomes due after backoff');

let recovery = {
	status: 'healthy', incident_started: null,
	failure_emails: 0, last_email: null, next_mail_attempt: null,
	recovery_eligible: false,
	recovery_pending: { incident_started: 7000, recovered_at: 7060,
		failure_emails: 1, last_result: { ok: false, reason: 'timeout' } }
};
let recovery_monitor = { initial_delay: 0, repeat_interval: 0, max_alerts: 1 };
equal(due_alert(recovery, recovery_monitor, 7060), 'recovery',
	'queued recovery alert is immediately due');
mail_failed(recovery, 7060, 300);
equal(recovery.recovery_pending != null, true,
	'failed recovery send preserves pending recovery');
equal(due_alert(recovery, recovery_monitor, 7359), null,
	'failed recovery send observes retry backoff');
equal(due_alert(recovery, recovery_monitor, 7360), 'recovery',
	'recovery retry becomes due after backoff');
mail_succeeded(recovery, 'recovery', 7360);
equal(recovery.recovery_pending, null,
	'successful recovery mail clears pending recovery');
equal(recovery.next_mail_attempt, null,
	'successful recovery mail clears retry schedule');

let recovery_retry_monitor = {
	enabled: true, failures: 1, recovery_email: true,
	initial_delay: 0, repeat_interval: 0, max_alerts: 1
};
let failed_probe = {
	ok: false, reason: 'timeout', loss: 100, avg_rtt: null, detail: 'timed out'
};
let healthy_probe = {
	ok: true, reason: null, loss: 0, avg_rtt: 10, detail: 'reachable'
};

let retry_into_incident = new_state('retry-into-incident');
equal(apply_result(retry_into_incident, recovery_retry_monitor, failed_probe, 7500),
	'opened', 'pre-retry incident opens');
mail_succeeded(retry_into_incident, 'failure', 7500);
equal(apply_result(retry_into_incident, recovery_retry_monitor, healthy_probe, 7560),
	'recovered', 'pre-retry incident recovers');
mail_failed(retry_into_incident, 7560, 300);
equal(apply_result(retry_into_incident, recovery_retry_monitor, failed_probe, 7620),
	'opened', 'new incident opens during recovery retry backoff');
equal(retry_into_incident.next_mail_attempt, 7860,
	'new incident preserves global mail retry backoff');
equal(due_alert(retry_into_incident, recovery_retry_monitor, 7859), null,
	'new incident cannot bypass global mail retry backoff');
equal(due_alert(retry_into_incident, recovery_retry_monitor, 7860), 'failure',
	'new incident alert is due at preserved backoff boundary');

let recovery_retry = new_state('recovery-retry');
equal(apply_result(recovery_retry, recovery_retry_monitor, failed_probe, 8000),
	'opened', 'recovery-retry incident opens');
mail_succeeded(recovery_retry, 'failure', 8000);
equal(apply_result(recovery_retry, recovery_retry_monitor, healthy_probe, 8060),
	'recovered', 'recovery-retry incident recovers');
equal(due_alert(recovery_retry, recovery_retry_monitor, 8060), 'recovery',
	'recovery-retry mail is initially due');
mail_failed(recovery_retry, 8060, 300);
equal(apply_result(recovery_retry, recovery_retry_monitor, healthy_probe, 8120),
	'healthy', 'intervening healthy result remains healthy');
equal(recovery_retry.next_mail_attempt, 8360,
	'intervening healthy result preserves recovery retry backoff');
equal(due_alert(recovery_retry, recovery_retry_monitor, 8359), null,
	'intervening healthy result cannot bypass recovery retry backoff');
equal(due_alert(recovery_retry, recovery_retry_monitor, 8360), 'recovery',
	'recovery retry is due at preserved backoff boundary');
