const SUMMARY_LIMIT = 192;
const DETAIL_LIMIT = 512;

const STAGES = {
	config: true,
	render: true,
	spawn: true,
	dns: true,
	network: true,
	tls: true,
	auth: true,
	smtp: true,
	timeout: true,
	process: true
};

const SUMMARIES = {
	dns: 'SMTP server name lookup failed.',
	network: 'SMTP network I/O failed.',
	tls: 'SMTP TLS negotiation failed.',
	auth: 'SMTP authentication failed.',
	smtp: 'SMTP server rejected the message.',
	config: 'SMTP configuration is invalid.',
	process: 'SMTP delivery process failed.'
};

function safe_exit_code(value) {
	return type(value) == 'int' && value >= 0 && value <= 255 ? value : null;
};

function safe_smtp_status(value) {
	return type(value) == 'int' && value >= 200 && value <= 599 ? value : null;
};

function exit_name(exit_code) {
	if (exit_code == 69) return 'EX_UNAVAILABLE';
	if (exit_code == 74) return 'EX_IOERR';
	if (exit_code == 75) return 'EX_TEMPFAIL';
	if (exit_code == 77) return 'EX_NOPERM';
	if (exit_code == 78) return 'EX_CONFIG';
	return null;
};

function normalize_utf8(value) {
	let output = '';
	for (let offset = 0; offset < length(value);) {
		let first = ord(substr(value, offset, 1));
		let width = 0;
		if (first < 128) width = 1;
		else if (first >= 194 && first <= 223) width = 2;
		else if (first >= 224 && first <= 239) width = 3;
		else if (first >= 240 && first <= 244) width = 4;

		let valid = width > 0 && offset + width <= length(value);
		if (valid && width > 1) {
			let second = ord(substr(value, offset + 1, 1));
			valid = second >= 128 && second <= 191 &&
				!(first == 224 && second < 160) &&
				!(first == 237 && second > 159) &&
				!(first == 240 && second < 144) &&
				!(first == 244 && second > 143);
		}
		for (let index = 2; valid && index < width; index++) {
			let continuation = ord(substr(value, offset + index, 1));
			valid = continuation >= 128 && continuation <= 191;
		}

		if (valid) {
			output += substr(value, offset, width);
			offset += width;
		}
		else {
			output += '?';
			offset++;
		}
	}
	return output;
};

function truncate_text(value, maximum) {
	if (length(value) <= maximum) return value;

	let marker = ' [truncated]';
	let cut = maximum - length(marker);
	while (cut > 0) {
		let byte = ord(substr(value, cut, 1));
		if (byte < 128 || byte >= 192) break;
		cut--;
	}

	return substr(value, 0, cut) + marker;
};

function redact_line(value) {
	value = replace(value, /[[:cntrl:]]/g, ' ');
	value = replace(value, /<[^>]*>/g, ' ');
	value = replace(value, /[<>]/g, ' ');
	value = replace(value,
		/[A-Z0-9.!#$%&'*+\/?^_`{|}~-]+@(\[[A-Z0-9:.%-]+\]|[A-Z0-9][A-Z0-9.-]*)/gi,
		'[REDACTED]');
	return value;
};

function credential_line(value) {
	if (match(value,
		/\b(user(name)?|account|login|password|pass(word)?|passwordeval|token|secret|credential|auth|authorization|proxy-authorization|api[_-]?key|access[_-]?key|client[_-]?secret|private[_-]?key)\b[ \t]*[:=]/i) ||
		match(value,
		/\b(user(name)?|login|password|pass(word)?|passwordeval|token|secret|credential|auth|api[_-]?key|access[_-]?key|client[_-]?secret|private[_-]?key)\b[ \t]+/i))
		return true;

	if (!match(value, /\b(authorization|proxy-authorization)\b[ \t]+/i))
		return false;

	return !match(value,
		/^[ \t]*(authorization|proxy-authorization)[ \t]+failed[ \t]*$/i);
};

function sanitize_text(value, maximum, strip_prefix) {
	if (type(value) != 'string') return '';

	value = normalize_utf8(value);
	value = replace(value, /\r\n?/g, '\n');
	let output = [];
	let private_key = false;
	let credentials_redacted = false;
	for (let index, line in split(value, '\n')) {
		if (!private_key && match(line, /-----BEGIN [^-]*PRIVATE KEY-----/i)) {
			push(output, '[REDACTED PRIVATE KEY]');
			private_key = !match(line, /-----END [^-]*PRIVATE KEY-----/i);
			continue;
		}
		if (private_key) {
			if (match(line, /-----END [^-]*PRIVATE KEY-----/i)) private_key = false;
			continue;
		}
		if (strip_prefix && index == 0)
			line = replace(line, /^[ \t]*msmtp(\[[0-9]+\])?:[ \t]*/i, '');
		line = redact_line(line);
		if (credential_line(line)) {
			credentials_redacted = true;
			continue;
		}
		push(output, line);
	}
	if (credentials_redacted) push(output, '[REDACTED CREDENTIALS]');

	value = trim(replace(join(' ', output), /[[:space:]]+/g, ' '));
	return truncate_text(value, maximum);
};

function fallback_failure() {
	return {
		stage: 'process', summary: SUMMARIES.process, detail: '',
		exit_code: null, exit_name: null, smtp_status: null
	};
};

function make_failure(stage, summary, detail, exit_code, smtp_status) {
	exit_code = safe_exit_code(exit_code);
	return {
		stage,
		summary: sanitize_text(summary, SUMMARY_LIMIT, false),
		detail: sanitize_text(detail, DETAIL_LIMIT, false),
		exit_code,
		exit_name: exit_name(exit_code),
		smtp_status: safe_smtp_status(smtp_status)
	};
};

export function fixed_mail_failure(stage, summary, detail) {
	if (type(stage) != 'string' || !(stage in STAGES))
		return fallback_failure();

	return make_failure(stage, summary, detail, null, null);
};

export function classify_mail_failure(exit_code, stderr, timed_out, smtp_status) {
	exit_code = safe_exit_code(exit_code);
	smtp_status = safe_smtp_status(smtp_status);

	if (timed_out === true)
		return make_failure('timeout', 'SMTP network I/O timed out.',
			'SMTP delivery exceeded its time limit.', exit_code, smtp_status);

	let detail = sanitize_text(stderr, DETAIL_LIMIT, true);
	let lower = lc(detail);
	let stage;

	if (smtp_status != null)
		stage = smtp_status in [ 530, 534, 535 ] ? 'auth' : 'smtp';
	else if (exit_code == 78 || match(lower,
		/configuration file|configuration error|account .* not found|invalid configuration/))
		stage = 'config';
	else if (exit_code == 77 ||
		match(lower, /authentication|authorization failed|credentials rejected/))
		stage = 'auth';
	else if (match(lower,
		/\btls\b|certificate|starttls|handshake|unknown ca|certificate verify failed/))
		stage = 'tls';
	else if (match(lower,
		/\bdns\b|cannot locate host|name or service not known|name resolution|host not found|no address associated/))
		stage = 'dns';
	else if (exit_code == 74 || match(lower,
		/network|connect|connection|socket|read error|write error|timed? out|timeout|broken pipe|unreachable/))
		stage = 'network';
	else if (match(lower,
		/server message|smtp status|recipient rejected|sender rejected|message rejected/))
		stage = 'smtp';
	else
		stage = 'process';

	return make_failure(stage, SUMMARIES[stage], detail, exit_code, smtp_status);
};

export function public_mail_failure(value) {
	if (value == null) return null;
	if (type(value) != 'object' || type(value.stage) != 'string' ||
		!(value.stage in STAGES) || type(value.summary) != 'string' ||
		type(value.detail) != 'string')
		return fallback_failure();

	return make_failure(value.stage, value.summary, value.detail,
		value.exit_code, value.smtp_status);
};
