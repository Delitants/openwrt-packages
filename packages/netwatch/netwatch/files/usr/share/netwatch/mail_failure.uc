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
	return type(value) == 'int' && value >= 100 && value <= 599 ? value : null;
};

function exit_name(exit_code) {
	if (exit_code == 69) return 'EX_UNAVAILABLE';
	if (exit_code == 74) return 'EX_IOERR';
	if (exit_code == 75) return 'EX_TEMPFAIL';
	if (exit_code == 77) return 'EX_NOPERM';
	if (exit_code == 78) return 'EX_CONFIG';
	return null;
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
		/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+[.][A-Z]{2,}\b/gi,
		'[REDACTED]');
	value = replace(value,
		/(\b(user(name)?|account|login|password|pass(word)?|token|secret|credential|authorization|proxy-authorization|api[_-]?key|access[_-]?key|client[_-]?secret|private[_-]?key)\b[ \t]*[:=][ \t]*)("[^"]*"|'[^']*'|[^ \t,;]+)/gi,
		'$1[REDACTED]');
	return value;
};

function sanitize_text(value, maximum, strip_prefix) {
	if (type(value) != 'string') return '';

	value = replace(value, /\r\n?/g, '\n');
	let output = [];
	for (let index, line in split(value, '\n')) {
		if (strip_prefix && index == 0)
			line = replace(line, /^[ \t]*msmtp(\[[0-9]+\])?:[ \t]*/i, '');
		push(output, redact_line(line));
	}

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

	if (exit_code == 78 || match(lower,
		/configuration file|configuration error|account .* not found|invalid configuration/))
		stage = 'config';
	else if (exit_code == 77 || smtp_status in [ 530, 534, 535 ] ||
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
	else if (smtp_status != null || match(lower,
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
