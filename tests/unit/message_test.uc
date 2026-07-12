import { deep_equal, equal, truthy } from 'test';
import { split_recipients, render_msmtp, render_message } from 'message';

function rejected(callback, label) {
	let did_reject = false;

	try {
		callback();
	}
	catch (error) {
		did_reject = true;
	}

	truthy(did_reject, label);
};

deep_equal(split_recipients('a@example.test, b@example.test'),
	['a@example.test', 'b@example.test'], 'comma-separated recipients split');
rejected(() => split_recipients('a@example.test\rb@example.test'),
	'carriage return in recipients rejected');
rejected(() => split_recipients('a@example.test\nb@example.test'),
	'line feed in recipients rejected');
rejected(() => split_recipients('a@example.test,,b@example.test'),
	'empty recipient rejected');

let smtp = {
	server: 'smtp.example.test', port: 587, tls: 'starttls',
	username: 'router-user', password: 'top-secret-value',
	from: 'router@example.test', from_name: 'Network Router',
	ehlo: 'router.example.test'
};
let msmtp = render_msmtp(smtp);
truthy(match(msmtp, /(^|\n)tls on(\n|$)/), 'STARTTLS enables TLS');
truthy(match(msmtp, /(^|\n)tls_starttls on(\n|$)/), 'STARTTLS mode enabled');
truthy(match(msmtp,
	/(^|\n)tls_trust_file \/etc\/ssl\/certs\/ca-certificates\.crt(\n|$)/),
	'CA trust store configured');
truthy(match(msmtp, /(^|\n)syslog LOG_MAIL(\n|$)/), 'mail facility logging configured');
truthy(match(msmtp, /(^|\n)auth on(\n|$)/), 'authentication enabled with credentials');
truthy(match(msmtp, /(^|\n)user router-user(\n|$)/), 'authentication user rendered');
truthy(match(msmtp, /(^|\n)password top-secret-value(\n|$)/),
	'password confined to msmtp config');

let implicit = render_msmtp({ ...smtp, tls: 'tls' });
truthy(match(implicit, /(^|\n)tls on(\n|$)/), 'implicit TLS enables TLS');
truthy(match(implicit, /(^|\n)tls_starttls off(\n|$)/),
	'implicit TLS disables STARTTLS upgrade');

let anonymous = render_msmtp({
	...smtp, username: 'router-user', password: ''
});
equal(match(anonymous, /(^|\n)(auth|user|password) /), null,
	'partial credentials omit all authentication lines');

let no_tls = render_msmtp({
	...smtp, tls: 'none', username: '', password: ''
});
truthy(match(no_tls, /(^|\n)tls off(\n|$)/), 'disabled TLS rendered explicitly');
equal(match(no_tls, /(^|\n)tls_starttls /), null,
	'disabled TLS omits STARTTLS setting');

rejected(() => render_msmtp({ ...smtp, server: 'smtp.example.test\npassword stolen' }),
	'msmtp line injection rejected');

let context = {
	smtp,
	recipients: ['ops@example.test', 'noc@example.test'],
	monitor: {
		id: 'gateway', name: 'Gateway', target: '192.0.2.1', max_alerts: 3
	},
	state: {
		incident_started: 1700000000, failure_emails: 1,
		last_result: { ok: false, reason: 'timeout', detail: 'probe timed out' }
	},
	router_hostname: 'router.example.test',
	timestamp: 1700000065
};
let failure = render_message('failure', context);
truthy(match(failure, /^From: /), 'From header rendered');
truthy(match(failure, /\nTo: ops@example\.test, noc@example\.test\n/),
	'To header rendered');
truthy(match(failure, /\nDate: Tue, 14 Nov 2023 22:14:25 \+0000\n/),
	'RFC 5322 Date header rendered');
truthy(match(failure, /\nMessage-ID: <[^\r\n]+@router\.example\.test>\n/),
	'Message-ID header rendered');
truthy(match(failure, /\nSubject: \[Netwatch DOWN\] Gateway/),
	'failure subject prefix rendered');
truthy(match(failure, /\nMIME-Version: 1\.0\n/), 'MIME version rendered');
truthy(match(failure, /\nContent-Type: text\/plain; charset=UTF-8\n/),
	'plain UTF-8 content type rendered');
truthy(match(failure, /\nContent-Transfer-Encoding: 8bit\n/),
	'8bit transfer encoding rendered');
truthy(match(failure, /\nTarget: 192\.0\.2\.1\n/), 'failure target rendered');
truthy(match(failure, /\nReason: timeout\n/), 'failure reason rendered');
truthy(match(failure, /\nIncident time: Tue, 14 Nov 2023 22:13:20 \+0000\n/),
	'failure incident time rendered');
truthy(match(failure, /\nDuration: 1 minute 5 seconds\n/),
	'failure duration rendered');
truthy(match(failure, /\nAlert 2 of 3\n/), 'failure alert count rendered');
equal(match(failure, /top-secret-value/), null,
	'password absent from rendered message');

let recovery = render_message('recovery', {
	...context,
	state: {
		recovery_pending: {
			incident_started: 1700000000, recovered_at: 1700000120,
			failure_emails: 2,
			last_result: { ok: false, reason: 'timeout', detail: 'probe timed out' }
		}
	},
	timestamp: 1700000180
});
truthy(match(recovery, /\nSubject: \[Netwatch RECOVERED\] Gateway/),
	'recovery subject prefix rendered');
truthy(match(recovery, /\nTarget: 192\.0\.2\.1\n/), 'recovery target rendered');
truthy(match(recovery, /\nIncident time: Tue, 14 Nov 2023 22:13:20 \+0000\n/),
	'recovery incident time rendered');
truthy(match(recovery, /\nRecovered at: Tue, 14 Nov 2023 22:15:20 \+0000\n/),
	'recovery time rendered');
truthy(match(recovery, /\nDuration: 2 minutes\n/), 'recovery duration rendered');
equal(match(recovery, /top-secret-value/), null,
	'password absent from recovery message');

rejected(() => render_message('failure', {
	...context,
	monitor: { ...context.monitor, name: 'Gateway\r\nBcc: thief@example.test' }
}), 'message header injection rejected');
