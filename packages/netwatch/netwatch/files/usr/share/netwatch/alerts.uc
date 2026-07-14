export function due_alert(state, monitor, now) {
	if (state.next_mail_attempt != null && now < state.next_mail_attempt)
		return null;

	if (state.recovery_pending != null)
		return 'recovery';

	if (state.status != 'failed' || state.incident_started == null ||
		state.failure_emails >= monitor.max_alerts)
		return null;

	if (state.failure_emails == 0)
		return now >= state.incident_started + monitor.initial_delay
			? 'failure'
			: null;

	if (monitor.repeat_interval == 0 || state.last_email == null)
		return null;

	return now >= state.last_email + monitor.repeat_interval
		? 'failure'
		: null;
};

export function mail_succeeded(state, kind, now) {
	if (kind == 'failure') {
		state.failure_emails++;
		state.recovery_eligible = true;
	}
	else if (kind == 'recovery') {
		state.recovery_pending = null;
	}
	else {
		return;
	}

	state.last_email = now;
	state.next_mail_attempt = null;
};

export function mail_failed(state, now, retry_backoff) {
	state.next_mail_attempt = now + retry_backoff;
};
