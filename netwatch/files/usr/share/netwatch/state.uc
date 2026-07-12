export function new_state(id) {
	return {
		id,
		status: 'unknown',
		consecutive_failures: 0,
		last_check: null,
		last_result: null,
		incident_started: null,
		failure_emails: 0,
		last_email: null,
		next_mail_attempt: null,
		recovery_eligible: false,
		recovery_pending: null,
		busy: false,
		config_error: null
	};
};

function clear_active_incident(state) {
	state.consecutive_failures = 0;
	state.incident_started = null;
	state.failure_emails = 0;
	state.last_email = null;
	state.recovery_eligible = false;
};

export function apply_result(state, monitor, result, now) {
	if (!monitor.enabled) {
		state.status = 'disabled';
		clear_active_incident(state);
		state.recovery_pending = null;
		return 'disabled';
	}

	let previous_status = state.status;

	if (result.ok) {
		if (previous_status == 'failed' && state.recovery_eligible &&
			monitor.recovery_email) {
			state.recovery_pending = {
				incident_started: state.incident_started,
				recovered_at: now,
				failure_emails: state.failure_emails,
				last_result: state.last_result
			};
		}

		state.last_check = now;
		state.last_result = result;
		state.status = 'healthy';
		clear_active_incident(state);

		if (previous_status == 'failed')
			return 'recovered';

		return previous_status == 'healthy' ? 'healthy' : 'became_healthy';
	}

	state.last_check = now;
	state.last_result = result;
	state.consecutive_failures++;

	if (previous_status == 'failed')
		return 'failed';

	if (state.consecutive_failures < monitor.failures) {
		state.status = 'pending';
		return 'pending';
	}

	state.status = 'failed';
	state.incident_started = now;
	state.failure_emails = 0;
	state.last_email = null;
	state.recovery_eligible = false;
	state.recovery_pending = null;
	return 'opened';
};
