import { deep_equal, equal, truthy } from 'test';
import {
	new_mail_test_tracker, begin_mail_test,
	finish_mail_test, public_mail_test, start_mail_test
} from 'mail_test';

let tracker = new_mail_test_tracker();
equal(public_mail_test(tracker), null, 'fresh tracker has no public test');

let first = begin_mail_test(tracker, 100);
deep_equal(first, {
	id: 1, state: 'sending', started: 100, completed: null, error: null
}, 'test begins with bounded sending state');
equal(finish_mail_test(tracker, 99, true, 101), false,
	'stale completion cannot mutate current test');
truthy(finish_mail_test(tracker, 1, true, 102),
	'matching successful completion accepted');
equal(public_mail_test(tracker).state, 'sent', 'success becomes sent');

let second = begin_mail_test(tracker, 200);
equal(second.id, 2, 'test IDs increase within daemon lifetime');
truthy(finish_mail_test(tracker, 2, false, 205),
	'matching failed completion accepted');
deep_equal(public_mail_test(tracker), {
	id: 2, state: 'failed', started: 200, completed: 205,
	error: 'mail delivery failed'
}, 'failure exposes only a fixed error');

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
	id: 3, state: 'sending', started: 300, completed: null, error: null
} ], 'starting publishes bounded state');

delivery_callback(true);
deep_equal(public_mail_test(tracker), {
	id: 3, state: 'sent', started: 300, completed: 305, error: null
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
equal(failed_start.ok, false, 'failed delivery start is rejected');
deep_equal(public_mail_test(tracker), {
	id: 4, state: 'failed', started: 400, completed: 401,
	error: 'mail delivery failed'
}, 'failed start becomes an immediate fixed failure state');
equal(length(failed_changes), 2,
	'failed start publishes sending and one terminal change');
