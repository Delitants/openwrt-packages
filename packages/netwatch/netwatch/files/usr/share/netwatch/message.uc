import { compact_result_with_evidence } from 'result';

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
	if (type(value) != 'string' || length(value) > 254 ||
		match(value, /[[:cntrl:]]/))
		return false;

	let parts = split(value, '@');

	if (length(parts) != 2)
		return false;

	let local = parts[0];
	let domain = parts[1];

	if (length(local) < 1 || length(local) > 64 ||
		length(domain) < 1 || length(domain) > 253)
		return false;

	for (let atom in split(local, '.'))
		if (atom == '' || !match(atom, /^[A-Za-z0-9!#$%&'*+_=^~-]+$/))
			return false;

	for (let label in split(domain, '.')) {
		if (length(label) < 1 || length(label) > 63 ||
			!match(label, /^[A-Za-z0-9-]+$/) ||
			!match(substr(label, 0, 1), /^[A-Za-z0-9]$/) ||
			!match(substr(label, length(label) - 1, 1), /^[A-Za-z0-9]$/))
			return false;
	}

	return true;
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

function byte(value, offset) {
	return ord(substr(value, offset, 1));
};

function utf8_width(value, offset, field) {
	let first = byte(value, offset);
	let width;

	if (first < 128)
		return 1;
	else if (first >= 194 && first <= 223)
		width = 2;
	else if (first >= 224 && first <= 239)
		width = 3;
	else if (first >= 240 && first <= 244)
		width = 4;
	else
		die(`${field} contains invalid UTF-8`);

	if (offset + width > length(value))
		die(`${field} contains invalid UTF-8`);

	let second = byte(value, offset + 1);

	if (second < 128 || second > 191 ||
		(first == 224 && second < 160) ||
		(first == 237 && second > 159) ||
		(first == 240 && second < 144) ||
		(first == 244 && second > 143))
		die(`${field} contains invalid UTF-8`);

	for (let index = 2; index < width; index++) {
		let continuation = byte(value, offset + index);

		if (continuation < 128 || continuation > 191)
			die(`${field} contains invalid UTF-8`);
	}

	return width;
};

function has_non_ascii(value) {
	for (let offset = 0; offset < length(value); offset++)
		if (byte(value, offset) > 127)
			return true;

	return false;
};

function header_value(value, field) {
	value = safe_text(value, field, false);

	if (!has_non_ascii(value))
		return value;

	let words = [];
	let chunk = '';
	let chunk_length = 0;

	for (let offset = 0; offset < length(value);) {
		let width = utf8_width(value, offset, field);

		if (chunk_length + width > 42) {
			push(words, `=?UTF-8?B?${b64enc(chunk)}?=`);
			chunk = '';
			chunk_length = 0;
		}

		chunk += substr(value, offset, width);
		chunk_length += width;
		offset += width;
	}

	if (chunk != '')
		push(words, `=?UTF-8?B?${b64enc(chunk)}?=`);

	return join('\n ', words);
};

function display_name(value) {
	value = safe_text(value, 'from name', true);

	if (value != '' && has_non_ascii(value))
		return header_value(value, 'from name');

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

function safe_body_block(value, field) {
	if (type(value) != 'string' || length(value) > 65536)
		die(`${field} contains invalid characters`);
	let disallowed_controls = replace(value, /[\t\n]/g, '');
	if (match(disallowed_controls, /[[:cntrl:]]/))
		die(`${field} contains invalid characters`);
	return value;
};

function interface_identity_lines(result, evidence_json) {
	if (type(result) != 'object') die('interface result is required');
	let lines = [
		`Interface: ${safe_text(result.label ?? result.configured_name, 'interface label', false)}`,
		`Selector: ${safe_text(result.selector, 'interface selector', false)}`,
		`Interface kind: ${safe_text(result.kind, 'interface kind', false)}`
	];
	if (type(result.live_device) == 'string' && result.live_device != '')
		push(lines, `Live device: ${safe_text(result.live_device, 'live device', false)}`);
	if (type(result.summary) == 'string' && result.summary != '')
		push(lines, `Summary: ${safe_text(result.summary, 'interface summary', false)}`);
	if (type(result.evidence) == 'object')
		push(lines, `Evidence: ${evidence_json}`);
	return lines;
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
	let raw_from_name = context.smtp.from_name ?? '';
	let from_name = display_name(raw_from_name);
	let recipients = message_recipients(context.recipients);
	let name = safe_text(monitor.name, 'monitor name', false);
	let is_interface = monitor.type == 'interface';
	let target = is_interface ? '' : safe_text(monitor.target, 'monitor target', false);
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
	let compacted;

	if (kind == 'failure') {
		incident = integer(state.incident_started, 'incident time');
		compacted = compact_result_with_evidence(state.last_result);
		result = compacted.value;

		if (type(result) != 'object')
			die('failure result is required');

		let alert_number = integer(state.failure_emails, 'failure email count') + 1;
		let max_alerts = integer(monitor.max_alerts, 'maximum alerts');

		duration = timestamp - incident;
		if (is_interface) {
			let label = safe_text(result.label ?? result.configured_name,
				'interface label', false);
			subject = `[Netwatch DOWN][${hostname}] ${name} — ${label}`;
			body = [
				`Monitor: ${name}`,
				...interface_identity_lines(result, compacted.evidence_json),
				`Reason: ${safe_text(result.reason, 'failure reason', false)}`,
				`Last check: ${rfc5322_date(integer(state.last_check, 'last check'))}`,
				`Incident time: ${rfc5322_date(incident)}`,
				`Duration: ${duration_text(duration)}`,
				`Alert ${alert_number} of ${max_alerts}`
			];
			if (type(context.diagnostic) == 'object' &&
				type(context.diagnostic.text) == 'string') {
				push(body, '');
				push(body, safe_body_block(context.diagnostic.text, 'diagnostic report'));
			}
		}
		else {
			let reason = safe_text(result.reason, 'failure reason', false);
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
	}
	else {
		let pending = state.recovery_pending;

		if (type(pending) != 'object')
			die('recovery details are required');

		incident = integer(pending.incident_started, 'incident time');
		let recovered_at = integer(pending.recovered_at, 'recovery time');

		duration = recovered_at - incident;
		if (is_interface) {
			compacted = compact_result_with_evidence(pending.recovered_result);
			let recovered = compacted.value;
			let label = safe_text(recovered?.label ?? recovered?.configured_name,
				'interface label', false);
			subject = `[Netwatch RECOVERED][${hostname}] ${name} — ${label}`;
			body = [
				`Monitor: ${name}`,
				...interface_identity_lines(recovered, compacted.evidence_json),
				`Recovered state: ${safe_text(recovered.summary, 'recovery summary', false)}`,
				`Incident time: ${rfc5322_date(incident)}`,
				`Recovered at: ${rfc5322_date(recovered_at)}`,
				`Duration: ${duration_text(duration)}`
			];
		}
		else {
			subject = `[Netwatch RECOVERED] ${name}`;
			body = [
				`Monitor: ${name}`,
				`Target: ${target}`,
				`Incident time: ${rfc5322_date(incident)}`,
				`Recovered at: ${rfc5322_date(recovered_at)}`,
				`Duration: ${duration_text(duration)}`
			];
		}
	}

	let headers = [
		from_name != ''
			? has_non_ascii(raw_from_name)
				? `From: ${from_name} <${from}>`
				: `From: "${from_name}" <${from}>`
			: `From: ${from}`,
		`To: ${join(', ', recipients)}`,
		`Date: ${rfc5322_date(timestamp)}`,
		`Message-ID: <netwatch.${timestamp}.${monitor_id}@${hostname}>`,
		`Subject: ${header_value(subject, 'subject')}`,
		'MIME-Version: 1.0',
		'Content-Type: text/plain; charset=UTF-8',
		'Content-Transfer-Encoding: 8bit',
		''
	];

	return `${join('\n', [ ...headers, ...body ])}\n`;
};
