const LIMITS = {
	interval: [5, 86400, 60],
	timeout: [1, 60, 5],
	failures: [1, 100, 3],
	packet_count: [1, 20, 3],
	max_loss: [0, 100, 0],
	max_rtt: [1, 60000, 500],
	initial_delay: [0, 604800, 0],
	max_alerts: [1, 1000, 1]
};

const REPEAT = [0, 600, 1800, 3600];
const TLS = ['none', 'starttls', 'tls'];

function has_line_break(value) {
	return type(value) == 'string' && !!match(value, /[\r\n]/);
};

function uci_bool(value, fallback) {
	if (value == null || value == '')
		return fallback;

	if (type(value) == 'bool')
		return value;

	if (value in [1, '1', 'true', 'yes', 'on'])
		return true;

	if (value in [0, '0', 'false', 'no', 'off'])
		return false;

	return fallback;
};

function plain_string(value, fallback) {
	return type(value) == 'string' && !has_line_break(value) ? value : fallback;
};

function plain_monitor_string(raw, field, fallback, errors) {
	let value = raw?.[field];

	if (value == null)
		return fallback;

	if (type(value) != 'string') {
		push(errors, `${field} must be text`);
		return fallback;
	}

	if (has_line_break(value)) {
		push(errors, `${field} must not contain line breaks`);
		return fallback;
	}

	return value;
};

function plain_integer(value) {
	if (type(value) == 'int')
		return value;

	if (type(value) == 'string' && match(value, /^[0-9]+$/))
		return +value;

	return null;
};

function normalized_integer(value, field, limits, errors) {
	if (value == null || value == '')
		return limits[2];

	let normalized = plain_integer(value);

	if (normalized == null || normalized < limits[0] || normalized > limits[1]) {
		push(errors, `${field} must be between ${limits[0]} and ${limits[1]}`);
		return limits[2];
	}

	return normalized;
};

function default_integer(value, minimum, maximum, fallback) {
	let normalized = plain_integer(value);

	return normalized != null && normalized >= minimum && normalized <= maximum
		? normalized
		: fallback;
};

export function valid_target(value) {
	return type(value) == 'string' &&
		!has_line_break(value) &&
		substr(value, 0, 1) != '-' &&
		!!match(value, /^[A-Za-z0-9_.:%-]+$/);
};

export function normalize_global(raw) {
	raw ??= {};

	return {
		enabled: uci_bool(raw.enabled, true),
		startup_grace: default_integer(raw.startup_grace, 0, 604800, 60),
		recipients: plain_string(raw.recipients, ''),
		mail_retry_backoff: default_integer(raw.mail_retry_backoff, 1, 86400, 300)
	};
};

export function normalize_smtp(raw) {
	raw ??= {};

	return {
		server: plain_string(raw.server, ''),
		port: default_integer(raw.port, 1, 65535, 587),
		tls: raw.tls in TLS ? raw.tls : 'starttls',
		username: plain_string(raw.username, ''),
		password: plain_string(raw.password, ''),
		from: plain_string(raw.from, ''),
		from_name: plain_string(raw.from_name, ''),
		ehlo: plain_string(raw.ehlo, '')
	};
};

export function normalize_monitor(id, raw) {
	raw ??= {};

	let errors = [];
	let monitor_id = plain_monitor_string({ id }, 'id', '', errors);
	let target = plain_monitor_string(raw, 'target', '', errors);
	let monitor_type = plain_monitor_string(raw, 'type', '', errors);
	let repeat_interval = raw.repeat_interval == null || raw.repeat_interval == ''
		? 0
		: plain_integer(raw.repeat_interval);

	if (!valid_target(target))
		push(errors, 'target is invalid');

	if (!(monitor_type in ['ping', 'tcp']))
		push(errors, 'type must be ping or tcp');

	if (!(repeat_interval in REPEAT)) {
		push(errors, 'repeat interval must be 0, 600, 1800, or 3600');
		repeat_interval = 0;
	}

	let value = {
		id: monitor_id,
		enabled: uci_bool(raw.enabled, true),
		name: plain_monitor_string(raw, 'name', monitor_id, errors),
		target,
		type: monitor_type,
		interval: normalized_integer(raw.interval, 'interval', LIMITS.interval, errors),
		timeout: normalized_integer(raw.timeout, 'timeout', LIMITS.timeout, errors),
		failures: normalized_integer(raw.failures, 'failures', LIMITS.failures, errors),
		initial_delay: normalized_integer(raw.initial_delay, 'initial delay', LIMITS.initial_delay, errors),
		repeat_interval,
		max_alerts: normalized_integer(raw.max_alerts, 'max alerts', LIMITS.max_alerts, errors),
		recovery_email: uci_bool(raw.recovery_email, true),
		recipients: plain_monitor_string(raw, 'recipients', '', errors)
	};

	if (monitor_type == 'ping') {
		value.packet_count = normalized_integer(raw.packet_count, 'packet count', LIMITS.packet_count, errors);
		value.loss_enabled = uci_bool(raw.loss_enabled, false);
		value.max_loss = normalized_integer(raw.max_loss, 'max loss', LIMITS.max_loss, errors);
		value.rtt_enabled = uci_bool(raw.rtt_enabled, false);
		value.max_rtt = normalized_integer(raw.max_rtt, 'max RTT', LIMITS.max_rtt, errors);
	}
	else if (monitor_type == 'tcp') {
		value.port = normalized_integer(raw.port, 'port', [1, 65535, null], errors);
	}

	return {
		ok: !length(errors),
		value,
		errors
	};
};
