import { deep_equal, equal, truthy } from 'test';
import {
	new_mail_test_tracker, begin_mail_test,
	finish_mail_test, public_mail_test, start_mail_test
} from 'mail_test';
import { fixed_mail_failure } from 'mail_failure';

let tracker = new_mail_test_tracker();
equal(public_mail_test(tracker), null, 'fresh tracker has no public test');

let first = begin_mail_test(tracker, 100);
deep_equal(first, {
	id: 1, state: 'sending', started: 100, completed: null, error: null,
	failure: null
}, 'test begins with bounded sending state');
tracker.current.password = 'injected-secret';
tracker.current.failure = {
	stage: 'auth', summary: 'injected-secret', detail: 'injected-secret',
	exit_code: 77, exit_name: 'EX_NOPERM', smtp_status: 535,
	internal_secret: 'injected-secret'
};
deep_equal(public_mail_test(tracker), {
	id: 1, state: 'sending', started: 100, completed: null, error: null,
	failure: null
}, 'public test projects only bounded lifecycle fields');
equal(finish_mail_test(tracker, 99, {
	ok: false,
	failure: fixed_mail_failure('network', 'stale-secret', 'stale-secret')
}, 101), false,
	'stale completion cannot mutate current test');
truthy(finish_mail_test(tracker, 1, {
	ok: true,
	failure: fixed_mail_failure('auth', 'must-not-survive', 'must-not-survive')
}, 102),
	'matching successful completion accepted');
deep_equal(public_mail_test(tracker), {
	id: 1, state: 'sent', started: 100, completed: 102, error: null,
	failure: null
}, 'success becomes sent without retaining a supplied failure');

let second = begin_mail_test(tracker, 200);
equal(second.id, 2, 'test IDs increase within daemon lifetime');
let internal_failure = {
	stage: 'auth', summary: 'SMTP authentication failed.',
	detail: 'credentials rejected', exit_code: 77,
	exit_name: 'attacker-controlled-name', smtp_status: 535,
	internal_secret: 'transport-secret'
};
truthy(finish_mail_test(tracker, 2, {
	ok: false, failure: internal_failure
}, 205),
	'matching failed completion accepted');
deep_equal(public_mail_test(tracker), {
	id: 2, state: 'failed', started: 200, completed: 205,
	error: 'SMTP authentication failed.',
	failure: {
		stage: 'auth', summary: 'SMTP authentication failed.',
		detail: 'credentials rejected', exit_code: 77,
		exit_name: 'EX_NOPERM', smtp_status: 535
	}
}, 'failure exposes the sanitized summary and exact six-field projection');
equal(match(sprintf('%J', public_mail_test(tracker)), /transport-secret/), null,
	'internal failure properties are never serialized');

let delivery_callback;
let changes = [];
let started = start_mail_test(
	tracker,
	300,
	(callback) => {
		delivery_callback = callback;
		return true;
	},
	() => 305,
	(state) => push(changes, state)
);
deep_equal(started, { ok: true, id: 3 },
	'delivery start returns immediately with the test ID');
equal(public_mail_test(tracker).state, 'sending',
	'delivery remains sending until its callback');
deep_equal(changes, [ {
	id: 3, state: 'sending', started: 300, completed: null, error: null,
	failure: null
} ], 'starting publishes bounded state');

delivery_callback({ ok: true, failure: null });
deep_equal(public_mail_test(tracker), {
	id: 3, state: 'sent', started: 300, completed: 305, error: null,
	failure: null
}, 'delivery callback completes the matching test');
deep_equal(changes[1], public_mail_test(tracker),
	'completion publishes the terminal state once');
equal(length(changes), 2,
	'completion adds exactly one changed notification');

let failed_changes = [];
let failed_start = start_mail_test(
	tracker, 400, (callback) => false, () => 401,
	(state) => push(failed_changes, state)
);
deep_equal(failed_start, {
	ok: false,
	error: 'Unable to start SMTP delivery.',
	failure: fixed_mail_failure('spawn', 'Unable to start SMTP delivery.', '')
}, 'spawn failure returned immediately');
deep_equal(public_mail_test(tracker), {
	id: 4, state: 'failed', started: 400, completed: 401,
	error: 'Unable to start SMTP delivery.',
	failure: fixed_mail_failure('spawn', 'Unable to start SMTP delivery.', '')
}, 'failed start becomes an immediate bounded spawn failure state');
equal(length(failed_changes), 2,
	'failed start publishes sending and one terminal change');

let malformed = begin_mail_test(tracker, 500);
truthy(finish_mail_test(tracker, malformed.id, {
	ok: false, failure: null
}, 501), 'malformed failed completion is accepted defensively');
deep_equal(public_mail_test(tracker), {
	id: 5, state: 'failed', started: 500, completed: 501,
	error: 'SMTP delivery process failed.',
	failure: {
		stage: 'process', summary: 'SMTP delivery process failed.', detail: '',
		exit_code: null, exit_name: null, smtp_status: null
	}
}, 'malformed failed outcome falls back to a fixed six-field failure');
