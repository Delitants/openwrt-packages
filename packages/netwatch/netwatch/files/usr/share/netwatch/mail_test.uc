import { fixed_mail_failure, public_mail_failure } from 'mail_failure';

export function new_mail_test_tracker() {
	return { next_id: 1, current: null };
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
	changed(public_mail_test(tracker));

	let started = start_delivery((outcome) => {
		if (finish_mail_test(tracker, current.id, outcome, completed_at()))
			changed(public_mail_test(tracker));
	});

	if (!started) {
		let failure = fixed_mail_failure(
			'spawn', 'Unable to start SMTP delivery.', '');
		finish_mail_test(tracker, current.id, { ok: false, failure }, completed_at());
		changed(public_mail_test(tracker));
		return { ok: false, error: failure.summary, failure };
	}

	return { ok: true, id: current.id };
};
