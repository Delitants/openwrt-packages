import { deep_equal, equal, truthy } from 'test';
import {
	new_mail_test_tracker, begin_mail_test,
	finish_mail_test, public_mail_test, start_mail_test,
	mail_test_error, mail_test_rejection
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

equal(mail_test_error('SMTP authentication failed.', {
	state: 'sending', error: null
}), 'SMTP authentication failed.',
	'sending preserves the previous global mail error');
equal(mail_test_error('SMTP authentication failed.', {
	state: 'sent', error: null
}), null, 'terminal success clears the global mail error');
equal(mail_test_error('SMTP authentication failed.', {
	state: 'failed', error: 'SMTP network I/O failed.'
}), 'SMTP network I/O failed.',
	'terminal failure replaces the global mail error with its sanitized summary');

let rejection_cases = [
	[ 'stopping', {
		ok: false, error: 'service stopping', failure: {
			stage: 'process', summary: 'service stopping', detail: '',
			exit_code: null, exit_name: null, smtp_status: null
		}
	} ],
	[ 'busy', {
		ok: false, error: 'mail delivery already running', failure: {
			stage: 'process', summary: 'mail delivery already running', detail: '',
			exit_code: null, exit_name: null, smtp_status: null
		}
	} ],
	[ 'reload', {
		ok: false, error: 'configuration reload failed', failure: {
			stage: 'config', summary: 'configuration reload failed', detail: '',
			exit_code: null, exit_name: null, smtp_status: null
		}
	} ],
	[ 'config', {
		ok: false, error: 'mail configuration invalid', failure: {
			stage: 'config', summary: 'mail configuration invalid', detail: '',
			exit_code: null, exit_name: null, smtp_status: null
		}
	} ],
	[ 'recipient_required', {
		ok: false, error: 'recipient is required', failure: {
			stage: 'config', summary: 'recipient is required', detail: '',
			exit_code: null, exit_name: null, smtp_status: null
		}
	} ],
	[ 'recipient_invalid', {
		ok: false, error: 'recipient is invalid', failure: {
			stage: 'config', summary: 'recipient is invalid', detail: '',
			exit_code: null, exit_name: null, smtp_status: null
		}
	} ],
	[ 'render', {
		ok: false, error: 'message rendering failed', failure: {
			stage: 'render', summary: 'message rendering failed', detail: '',
			exit_code: null, exit_name: null, smtp_status: null
		}
	} ],
	[ 'spawn', {
		ok: false, error: 'Unable to start SMTP delivery.', failure: {
			stage: 'spawn', summary: 'Unable to start SMTP delivery.', detail: '',
			exit_code: null, exit_name: null, smtp_status: null
		}
	} ],
	[ 'lifecycle', {
		ok: false, error: 'SMTP delivery process failed.', failure: {
			stage: 'process', summary: 'SMTP delivery process failed.', detail: '',
			exit_code: null, exit_name: null, smtp_status: null
		}
	} ],
	[ 'generic', {
		ok: false, error: 'test email failed', failure: {
			stage: 'process', summary: 'test email failed', detail: '',
			exit_code: null, exit_name: null, smtp_status: null
		}
	} ]
];

for (let test_case in rejection_cases)
	deep_equal(mail_test_rejection(test_case[0]), test_case[1],
		`${test_case[0]} rejection uses its exact fixed public mapping`);

let lifecycle_failure = {
	ok: false, error: 'SMTP delivery process failed.', failure: {
		stage: 'process', summary: 'SMTP delivery process failed.', detail: '',
		exit_code: null, exit_name: null, smtp_status: null
	}
};

let persistence_tracker = new_mail_test_tracker();
let persistence_notifications = 0;
let persistence_starts = 0;
let persistence_result = start_mail_test(
	persistence_tracker, 600,
	(callback) => {
		persistence_starts++;
		return true;
	},
	() => 601,
	(state) => {
		persistence_notifications++;
		die('password=persistence-secret');
	}
);
deep_equal(persistence_result, lifecycle_failure,
	'initial persistence exception returns a fixed process rejection');
equal(persistence_starts, 0,
	'delivery does not start after initial lifecycle persistence fails');
equal(persistence_notifications, 2,
	'terminal persistence is attempted once after initial persistence failure');
deep_equal(public_mail_test(persistence_tracker), {
	id: 1, state: 'failed', started: 600, completed: 601,
	error: 'SMTP delivery process failed.',
	failure: lifecycle_failure.failure
}, 'repeated persistence exception leaves a bounded terminal process failure');
equal(match(sprintf('%J', persistence_result), /persistence-secret/), null,
	'persistence exception text is absent from the immediate rejection');

let throwing_start_tracker = new_mail_test_tracker();
let throwing_start_changes = [];
let throwing_start_result = start_mail_test(
	throwing_start_tracker, 700,
	(callback) => die('token=delivery-starter-secret'),
	() => 701,
	(state) => push(throwing_start_changes, state)
);
deep_equal(throwing_start_result, mail_test_rejection('spawn'),
	'throwing delivery starter returns the exact spawn rejection');
equal(length(throwing_start_changes), 2,
	'throwing delivery starter publishes sending and terminal failure once');
equal(public_mail_test(throwing_start_tracker).state, 'failed',
	'throwing delivery starter cannot leave public state sending');
equal(match(sprintf('%J', throwing_start_result), /delivery-starter-secret/), null,
	'delivery starter exception text is absent from the immediate rejection');

let terminal_throw_tracker = new_mail_test_tracker();
let terminal_throw_changes = 0;
let terminal_throw_result = start_mail_test(
	terminal_throw_tracker, 800,
	(callback) => false,
	() => 801,
	(state) => {
		terminal_throw_changes++;
		if (state.state == 'failed')
			die('terminal-persistence-secret');
	}
);
deep_equal(terminal_throw_result, mail_test_rejection('spawn'),
	'terminal persistence exception cannot replace the spawn rejection');
equal(terminal_throw_changes, 2,
	'failed starter attempts one bounded terminal notification');
equal(public_mail_test(terminal_throw_tracker).state, 'failed',
	'terminal persistence exception leaves public state failed');

let asynchronous_tracker = new_mail_test_tracker();
let asynchronous_callback;
let asynchronous_changes = 0;
deep_equal(start_mail_test(
	asynchronous_tracker, 900,
	(callback) => {
		asynchronous_callback = callback;
		return true;
	},
	() => 901,
	(state) => {
		asynchronous_changes++;
		if (state.state == 'sent')
			die('late-persistence-secret');
	}
), { ok: true, id: 1 }, 'asynchronous delivery starts normally');
asynchronous_callback({ ok: true, failure: null });
equal(asynchronous_changes, 2,
	'asynchronous terminal persistence is attempted exactly once');
equal(public_mail_test(asynchronous_tracker).state, 'sent',
	'asynchronous terminal persistence exception cannot undo completion');
