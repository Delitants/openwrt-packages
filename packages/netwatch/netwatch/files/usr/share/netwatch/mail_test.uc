import { fixed_mail_failure, public_mail_failure } from 'mail_failure';

const MAIL_TEST_REJECTIONS = {
	stopping: [ 'process', 'service stopping' ],
	busy: [ 'process', 'mail delivery already running' ],
	reload: [ 'config', 'configuration reload failed' ],
	config: [ 'config', 'mail configuration invalid' ],
	recipient_required: [ 'config', 'recipient is required' ],
	recipient_invalid: [ 'config', 'recipient is invalid' ],
	render: [ 'render', 'message rendering failed' ],
	spawn: [ 'spawn', 'Unable to start SMTP delivery.' ],
	lifecycle: [ 'process', 'SMTP delivery process failed.' ],
	generic: [ 'process', 'test email failed' ]
};

export function new_mail_test_tracker() {
	return { next_id: 1, current: null };
};

export function mail_test_rejection(reason) {
	let mapping = MAIL_TEST_REJECTIONS[reason] ?? MAIL_TEST_REJECTIONS.lifecycle;
	let failure = fixed_mail_failure(mapping[0], mapping[1], '');

	return { ok: false, error: failure.summary, failure };
};

export function mail_test_error(previous, current) {
	if (current?.state == 'sent')
		return null;
	if (current?.state == 'failed')
		return type(current.error) == 'string'
			? current.error
			: MAIL_TEST_REJECTIONS.lifecycle[1];

	return previous;
};

export function begin_mail_test(tracker, now) {
	let current = {
		id: tracker.next_id++, state: 'sending', started: now,
		completed: null, error: null, failure: null
	};
	tracker.current = current;
	return { ...current };
};

export function finish_mail_test(tracker, id, outcome, now) {
	if (tracker?.current?.id !== id || tracker.current.state != 'sending')
		return false;

	let succeeded = outcome?.ok === true;
	let failure = succeeded
		? null
		: public_mail_failure(outcome?.failure ?? {});

	tracker.current.state = succeeded ? 'sent' : 'failed';
	tracker.current.completed = now;
	tracker.current.error = succeeded
		? null
		: (failure?.summary ?? 'mail delivery failed');
	tracker.current.failure = failure;
	return true;
};

export function public_mail_test(tracker) {
	let current = tracker?.current;
	let failure = current?.state == 'failed'
		? public_mail_failure(current.failure ?? {})
		: null;

	return current ? {
		id: current.id,
		state: current.state,
		started: current.started,
		completed: current.completed,
		error: current.state == 'failed'
			? (failure?.summary ?? 'mail delivery failed')
			: null,
		failure
	} : null;
};

export function start_mail_test(
	tracker, now, start_delivery, completed_at, changed
) {
	let current = begin_mail_test(tracker, now);

	function completed() {
		try {
			return completed_at();
		}
		catch (error) {
			return now;
		}
	};

	function publish() {
		try {
			changed(public_mail_test(tracker));
			return true;
		}
		catch (error) {
			return false;
		}
	};

	function reject_started(reason) {
		let rejection = mail_test_rejection(reason);

		if (finish_mail_test(tracker, current.id, rejection, completed()))
			publish();

		return rejection;
	};

	if (!publish())
		return reject_started('lifecycle');

	let started;

	try {
		started = start_delivery((outcome) => {
			if (finish_mail_test(tracker, current.id, outcome, completed()))
				publish();
		});
	}
	catch (error) {
		return reject_started('spawn');
	}

	if (!started)
		return reject_started('spawn');

	return { ok: true, id: current.id };
};
