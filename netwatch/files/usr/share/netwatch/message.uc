const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTHS = [
	'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
	'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

function safe_text(value, field, allow_empty) {
	if (type(value) != 'string' || (!allow_empty && value == '') ||
		match(value, /[[:cntrl:]]/))
		die(`${field} contains invalid characters`);

	return value;
};

function valid_address(value) {
	return type(value) == 'string' &&
		!!match(value, /^[^ <>@,]+@[^ <>@,]+$/) &&
		!match(value, /[[:cntrl:]]/);
};

function integer(value, field) {
	if (type(value) != 'int')
		die(`${field} must be an integer`);

	return value;
};

function rfc5322_date(timestamp) {
	let date = gmtime(integer(timestamp, 'timestamp'));

	return sprintf('%s, %02d %s %04d %02d:%02d:%02d +0000',
		WEEKDAYS[date.wday], date.mday, MONTHS[date.mon - 1], date.year,
		date.hour, date.min, date.sec);
};

function duration_text(seconds) {
	seconds = integer(seconds, 'duration');

	if (seconds < 0)
		seconds = 0;

	let parts = [];
	let hours = int(seconds / 3600);
	let minutes = int((seconds % 3600) / 60);
	let remaining = seconds % 60;

	if (hours)
		push(parts, `${hours} hour${hours == 1 ? '' : 's'}`);

	if (minutes)
		push(parts, `${minutes} minute${minutes == 1 ? '' : 's'}`);

	if (remaining || !length(parts))
		push(parts, `${remaining} second${remaining == 1 ? '' : 's'}`);

	return join(' ', parts);
};

function display_name(value) {
	value = safe_text(value, 'from name', true);

	return replace(replace(value, /\\/g, '\\\\'), /"/g, '\\"');
};

function message_recipients(value) {
	if (type(value) == 'string')
		return split_recipients(value);

	if (type(value) != 'array' || !length(value))
		die('recipients must not be empty');

	let recipients = [];

	for (let address in value) {
		address = trim(address);

		if (!valid_address(address))
			die('recipient is invalid');

		push(recipients, address);
	}

	return recipients;
};

export function split_recipients(value) {
	safe_text(value, 'recipients', false);

	let recipients = [];

	for (let address in split(value, ',')) {
		address = trim(address);

		if (!valid_address(address))
			die('recipient is invalid');

		push(recipients, address);
	}

	if (!length(recipients))
		die('recipients must not be empty');

	return recipients;
};

export function render_msmtp(smtp) {
	if (type(smtp) != 'object')
		die('SMTP configuration is required');

	let server = safe_text(smtp.server, 'SMTP server', false);
	let from = safe_text(smtp.from, 'SMTP from address', false);
	let ehlo = safe_text(smtp.ehlo ?? '', 'SMTP EHLO', true);
	let username = safe_text(smtp.username ?? '', 'SMTP username', true);
	let password = safe_text(smtp.password ?? '', 'SMTP password', true);
	let port = integer(smtp.port, 'SMTP port');

	if (!valid_address(from) || port < 1 || port > 65535)
		die('SMTP configuration is invalid');

	if (!(smtp.tls in ['none', 'starttls', 'tls']))
		die('SMTP TLS mode is invalid');

	let lines = ['defaults'];

	if (smtp.tls == 'none')
		push(lines, 'tls off');
	else {
		push(lines, 'tls on');
		push(lines, `tls_starttls ${smtp.tls == 'starttls' ? 'on' : 'off'}`);
	}

	push(lines, 'tls_trust_file /etc/ssl/certs/ca-certificates.crt');
	push(lines, 'syslog LOG_MAIL');
	push(lines, '');
	push(lines, 'account netwatch');
	push(lines, `host ${server}`);
	push(lines, `port ${port}`);
	push(lines, `from ${from}`);

	if (ehlo != '')
		push(lines, `domain ${ehlo}`);

	if (username != '' && password != '') {
		push(lines, 'auth on');
		push(lines, `user ${username}`);
		push(lines, `password ${password}`);
	}

	push(lines, 'account default : netwatch');

	return `${join('\n', lines)}\n`;
};

export function render_message(kind, context) {
	if (!(kind in ['failure', 'recovery']) || type(context) != 'object' ||
		type(context.smtp) != 'object' || type(context.monitor) != 'object' ||
		type(context.state) != 'object')
		die('message context is invalid');

	let timestamp = integer(context.timestamp, 'timestamp');
	let monitor = context.monitor;
	let state = context.state;
	let from = safe_text(context.smtp.from, 'from address', false);
	let from_name = display_name(context.smtp.from_name ?? '');
	let recipients = message_recipients(context.recipients);
	let name = safe_text(monitor.name, 'monitor name', false);
	let target = safe_text(monitor.target, 'monitor target', false);
	let monitor_id = safe_text(monitor.id, 'monitor ID', false);
	let hostname = safe_text(context.router_hostname, 'router hostname', false);

	if (!valid_address(from) || !match(hostname, /^[A-Za-z0-9_.-]+$/) ||
		!match(monitor_id, /^[A-Za-z0-9_.-]+$/))
		die('message header value is invalid');

	let incident;
	let result;
	let duration;
	let body;
	let subject;

	if (kind == 'failure') {
		incident = integer(state.incident_started, 'incident time');
		result = state.last_result;

		if (type(result) != 'object')
			die('failure result is required');

		let reason = safe_text(result.reason, 'failure reason', false);
		let alert_number = integer(state.failure_emails, 'failure email count') + 1;
		let max_alerts = integer(monitor.max_alerts, 'maximum alerts');

		duration = timestamp - incident;
		subject = `[Netwatch DOWN] ${name}`;
		body = [
			`Monitor: ${name}`,
			`Target: ${target}`,
			`Reason: ${reason}`,
			`Incident time: ${rfc5322_date(incident)}`,
			`Duration: ${duration_text(duration)}`,
			`Alert ${alert_number} of ${max_alerts}`
		];
	}
	else {
		let pending = state.recovery_pending;

		if (type(pending) != 'object')
			die('recovery details are required');

		incident = integer(pending.incident_started, 'incident time');
		let recovered_at = integer(pending.recovered_at, 'recovery time');

		duration = recovered_at - incident;
		subject = `[Netwatch RECOVERED] ${name}`;
		body = [
			`Monitor: ${name}`,
			`Target: ${target}`,
			`Incident time: ${rfc5322_date(incident)}`,
			`Recovered at: ${rfc5322_date(recovered_at)}`,
			`Duration: ${duration_text(duration)}`
		];
	}

	let headers = [
		from_name != '' ? `From: "${from_name}" <${from}>` : `From: ${from}`,
		`To: ${join(', ', recipients)}`,
		`Date: ${rfc5322_date(timestamp)}`,
		`Message-ID: <netwatch.${timestamp}.${monitor_id}@${hostname}>`,
		`Subject: ${subject}`,
		'MIME-Version: 1.0',
		'Content-Type: text/plain; charset=UTF-8',
		'Content-Transfer-Encoding: 8bit',
		''
	];

	return `${join('\n', [ ...headers, ...body ])}\n`;
};
