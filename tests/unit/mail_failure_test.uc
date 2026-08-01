import { deep_equal, equal, truthy } from 'test';
import {
	fixed_mail_failure,
	classify_mail_failure,
	public_mail_failure
} from 'mail_failure';

function repeated(value, count) {
	let output = '';
	for (let i = 0; i < count; i++) output += value;
	return output;
};

function valid_utf8(value) {
	for (let offset = 0; offset < length(value);) {
		let first = ord(substr(value, offset, 1));
		let width;
		if (first < 128) width = 1;
		else if (first >= 194 && first <= 223) width = 2;
		else if (first >= 224 && first <= 239) width = 3;
		else if (first >= 240 && first <= 244) width = 4;
		else return false;
		if (offset + width > length(value)) return false;
		if (width > 1) {
			let second = ord(substr(value, offset + 1, 1));
			if (second < 128 || second > 191 ||
				(first == 224 && second < 160) ||
				(first == 237 && second > 159) ||
				(first == 240 && second < 144) ||
				(first == 244 && second > 143)) return false;
		}
		for (let index = 2; index < width; index++) {
			let continuation = ord(substr(value, offset + index, 1));
			if (continuation < 128 || continuation > 191) return false;
		}
		offset += width;
	}
	return true;
};

// Production bug caught: a network-read failure is flattened into a generic error.
deep_equal(classify_mail_failure(74,
	'msmtp: network read error: the operation timed out', false, null), {
	stage: 'network', summary: 'SMTP network I/O failed.',
	detail: 'network read error: the operation timed out',
	exit_code: 74, exit_name: 'EX_IOERR', smtp_status: null
}, 'network error classified');

// Production bug caught: an outer delivery timeout publishes hostile stderr.
deep_equal(classify_mail_failure(null,
	'msmtp: password=timeout-secret', true, null), {
	stage: 'timeout', summary: 'SMTP network I/O timed out.',
	detail: 'SMTP delivery exceeded its time limit.',
	exit_code: null, exit_name: null, smtp_status: null
}, 'process timeout uses fixed public text');

// Production bug caught: a resolver failure is mislabeled as a process failure.
deep_equal(classify_mail_failure(69,
	'msmtp: cannot locate host smtp.example.test: Name or service not known',
	false, null), {
	stage: 'dns', summary: 'SMTP server name lookup failed.',
	detail: 'cannot locate host smtp.example.test: Name or service not known',
	exit_code: 69, exit_name: 'EX_UNAVAILABLE', smtp_status: null
}, 'DNS error classified');

// Production bug caught: a certificate failure is mislabeled as network I/O.
deep_equal(classify_mail_failure(75,
	'msmtp: TLS certificate verification failed: certificate has expired',
	false, null), {
	stage: 'tls', summary: 'SMTP TLS negotiation failed.',
	detail: 'TLS certificate verification failed: certificate has expired',
	exit_code: 75, exit_name: 'EX_TEMPFAIL', smtp_status: null
}, 'TLS error classified');

// Production bug caught: an authentication rejection is mislabeled as SMTP transport.
deep_equal(classify_mail_failure(77,
	'msmtp: authentication failed (method PLAIN)', false, 535), {
	stage: 'auth', summary: 'SMTP authentication failed.',
	detail: 'authentication failed (method PLAIN)',
	exit_code: 77, exit_name: 'EX_NOPERM', smtp_status: 535
}, 'authentication error classified');

// Production bug caught: credential redaction erases an authorization diagnostic.
deep_equal(classify_mail_failure(1,
	'msmtp: authorization failed', false, null), {
	stage: 'auth', summary: 'SMTP authentication failed.',
	detail: 'authorization failed',
	exit_code: 1, exit_name: null, smtp_status: null
}, 'authorization failure phrase remains classifiable');

// Production bug caught: a parsed permanent SMTP rejection is ignored.
deep_equal(classify_mail_failure(75,
	'msmtp: server message: 550 5.1.1 recipient rejected', false, 550), {
	stage: 'smtp', summary: 'SMTP server rejected the message.',
	detail: 'server message: 550 5.1.1 recipient rejected',
	exit_code: 75, exit_name: 'EX_TEMPFAIL', smtp_status: 550
}, 'SMTP 550 rejection classified');

// Production bug caught: generic network text or exit 74 overrides parsed SMTP 550.
deep_equal(classify_mail_failure(74,
	'msmtp: server message: 550 connection rejected', false, 550), {
	stage: 'smtp', summary: 'SMTP server rejected the message.',
	detail: 'server message: 550 connection rejected',
	exit_code: 74, exit_name: 'EX_IOERR', smtp_status: 550
}, 'parsed SMTP rejection outranks generic network evidence');

// Production bug caught: local configuration errors are reported as remote failures.
deep_equal(classify_mail_failure(78,
	'msmtp: account default not found in configuration file', false, null), {
	stage: 'config', summary: 'SMTP configuration is invalid.',
	detail: 'account default not found in configuration file',
	exit_code: 78, exit_name: 'EX_CONFIG', smtp_status: null
}, 'configuration error classified');

// Production bug caught: an unrecognized exit invents a symbolic name or category.
deep_equal(classify_mail_failure(1,
	'msmtp: helper exited unexpectedly', false, 999), {
	stage: 'process', summary: 'SMTP delivery process failed.',
	detail: 'helper exited unexpectedly',
	exit_code: 1, exit_name: null, smtp_status: null
}, 'unknown process error remains bounded and generic');

// Production bug caught: SMTP status 100 is accepted and forces an SMTP category.
deep_equal(classify_mail_failure(1, 'msmtp: helper exited unexpectedly',
	false, 100), {
	stage: 'process', summary: 'SMTP delivery process failed.',
	detail: 'helper exited unexpectedly',
	exit_code: 1, exit_name: null, smtp_status: null
}, 'SMTP status lower boundary below 200 rejected');

// Production bug caught: SMTP status 199 is accepted and forces an SMTP category.
deep_equal(classify_mail_failure(1, 'msmtp: helper exited unexpectedly',
	false, 199), {
	stage: 'process', summary: 'SMTP delivery process failed.',
	detail: 'helper exited unexpectedly',
	exit_code: 1, exit_name: null, smtp_status: null
}, 'SMTP status upper boundary below 200 rejected');

let spaced_user = classify_mail_failure(1,
	'msmtp: user alice\nserver unavailable', false, null);

// Production bug caught: msmtp whitespace-form usernames remain public.
equal(spaced_user.detail, 'server unavailable [REDACTED CREDENTIALS]',
	'whitespace-form username redacted and useful detail retained');

let spaced_password = classify_mail_failure(1,
	'msmtp: password secret\nretry denied', false, null);

// Production bug caught: msmtp whitespace-form passwords remain public.
equal(spaced_password.detail, 'retry denied [REDACTED CREDENTIALS]',
	'whitespace-form password redacted and useful detail retained');

let authorization = classify_mail_failure(1,
	'msmtp: Authorization: Bearer session-token\nserver refused request',
	false, null);

// Production bug caught: Authorization redaction removes only the scheme, not its token.
equal(authorization.detail,
	'server refused request [REDACTED CREDENTIALS]',
	'complete Authorization value redacted and useful detail retained');

let whitespace_authorization = classify_mail_failure(1,
	'msmtp: Authorization Bearer whitespace-session-token\nserver refused request',
	false, null);

// Production bug caught: preserving diagnostics exposes whitespace Authorization tokens.
equal(whitespace_authorization.detail,
	'server refused request [REDACTED CREDENTIALS]',
	'whitespace Authorization bearer value remains fully redacted');

let private_key = classify_mail_failure(75,
	'msmtp: TLS failed\n-----BEGIN PRIVATE KEY-----\n' +
	'private-key-material\n-----END PRIVATE KEY-----\nserver closed connection',
	false, null);

// Production bug caught: PEM private-key bodies and armor survive sanitization.
equal(private_key.detail,
	'TLS failed [REDACTED PRIVATE KEY] server closed connection',
	'PEM private key replaced while useful detail remains');

let local_mailbox = classify_mail_failure(1,
	'msmtp: recipient alice@localhost\nserver rejected request', false, null);

// Production bug caught: an email address with a single-label domain remains public.
equal(local_mailbox.detail,
	'recipient [REDACTED] server rejected request',
	'single-label email address redacted');

let literal_mailbox = classify_mail_failure(1,
	'msmtp: sender bob@[192.0.2.1]\nserver rejected request', false, null);

// Production bug caught: an email address with an address-literal domain remains public.
equal(literal_mailbox.detail,
	'sender [REDACTED] server rejected request',
	'address-literal email address redacted');

let punycode_mailbox = classify_mail_failure(1,
	'msmtp: recipient carol@example.xn--p1ai\nserver rejected request', false, null);

// Production bug caught: punycode TLD text remains after partial mailbox redaction.
equal(punycode_mailbox.detail,
	'recipient [REDACTED] server rejected request',
	'punycode email address redacted completely');

let hostile = 'msmtp: user=alice\r\n' +
	'recipient alice@example.test\npassword=secret\n' +
	'token=secret\n<script>alert(1)</script>\u0000\u0007 ' + repeated('x', 4097);
let sanitized = classify_mail_failure(1, hostile, false, null);

// Production bug caught: credential values survive failure-detail sanitization.
equal(match(sanitized.detail, /alice|alice@example[.]test|secret/i), null,
	'credentials and envelope address removed');

// Production bug caught: controls and HTML delimiters reach a public rendering surface.
equal(match(sanitized.detail, /[\r\n<>]/), null,
	'controls and HTML delimiters removed');

// Production bug caught: removing the control sanitizer exposes an embedded NUL byte.
equal(length(split(sanitized.detail, '\u0000')), 1,
	'NUL control byte removed explicitly');

// Production bug caught: removing the control sanitizer exposes an embedded BEL byte.
equal(length(split(sanitized.detail, '\u0007')), 1,
	'BEL control byte removed explicitly');

// Production bug caught: a hostile server response grows without the detail bound.
truthy(length(sanitized.detail) <= 512, 'detail is at most 512 bytes');

let oversized_fixed = fixed_mail_failure('render',
	'user=alice password=secret token=secret ' + repeated('s', 4097),
	'alice@example.test <b>unsafe</b> ' + repeated('d', 4097));

// Production bug caught: a caller-provided summary exceeds its independent public bound.
truthy(length(oversized_fixed.summary) <= 192, 'summary is at most 192 bytes');

// Production bug caught: fixed failures bypass summary credential redaction.
equal(match(oversized_fixed.summary, /alice|secret/i), null,
	'fixed summary credentials removed');

// Production bug caught: a caller-provided detail exceeds its independent public bound.
truthy(length(oversized_fixed.detail) <= 512, 'fixed detail is at most 512 bytes');

// Production bug caught: fixed failures preserve envelope addresses or HTML delimiters.
equal(match(oversized_fixed.detail, /alice@example[.]test|[<>]/i), null,
	'fixed detail address and HTML removed');

let multibyte_fixed = fixed_mail_failure('render',
	'x' + repeated('€', 100), 'x' + repeated('€', 200));

// Production bug caught: summary truncation cuts a multibyte sequence at byte 192.
equal(length(multibyte_fixed.summary), 190,
	'UTF-8 summary observes the 192-byte boundary without a partial code point');

// Production bug caught: a bounded summary is byte-limited but invalid UTF-8.
truthy(valid_utf8(multibyte_fixed.summary),
	'UTF-8 summary remains valid after truncation');

// Production bug caught: detail truncation cuts a multibyte sequence at byte 512.
equal(length(multibyte_fixed.detail), 511,
	'UTF-8 detail observes the 512-byte boundary without a partial code point');

// Production bug caught: a bounded detail is byte-limited but invalid UTF-8.
truthy(valid_utf8(multibyte_fixed.detail),
	'UTF-8 detail remains valid after truncation');

// Production bug caught: an untrusted stage lets callers invent public categories.
deep_equal(fixed_mail_failure('private-stage', 'leak me', 'leak me too'), {
	stage: 'process', summary: 'SMTP delivery process failed.', detail: '',
	exit_code: null, exit_name: null, smtp_status: null
}, 'unknown fixed stage uses safe fallback');

let internal = classify_mail_failure(74,
	'msmtp: network read error: connection reset', false, null);
internal.internal_secret = 'must-not-be-public';

// Production bug caught: public projection copies arbitrary internal properties.
deep_equal(public_mail_failure(internal), {
	stage: 'network', summary: 'SMTP network I/O failed.',
	detail: 'network read error: connection reset',
	exit_code: 74, exit_name: 'EX_IOERR', smtp_status: null
}, 'public failure includes exactly the six allowed fields');

// Production bug caught: an absent failure is converted into a visible process error.
equal(public_mail_failure(null), null, 'absent public failure remains absent');

// Production bug caught: malformed internal state reaches the public API unchanged.
deep_equal(public_mail_failure({ stage: 'invented', internal_secret: 'secret' }), {
	stage: 'process', summary: 'SMTP delivery process failed.', detail: '',
	exit_code: null, exit_name: null, smtp_status: null
}, 'malformed public failure uses safe fallback');
