export function new_mail_test_tracker() {
	return { next_id: 1, current: null };
};

export function begin_mail_test(tracker, now) {
	let current = {
		id: tracker.next_id++, state: 'sending', started: now,
		completed: null, error: null
	};
	tracker.current = current;
	return { ...current };
};

export function finish_mail_test(tracker, id, delivered, now) {
	if (tracker?.current?.id !== id || tracker.current.state != 'sending')
		return false;
	tracker.current.state = delivered === true ? 'sent' : 'failed';
	tracker.current.completed = now;
	tracker.current.error = delivered === true ? null : 'mail delivery failed';
	return true;
};

export function public_mail_test(tracker) {
	return tracker?.current ? { ...tracker.current } : null;
};

export function start_mail_test(
	tracker, now, start_delivery, completed_at, changed
) {
	let current = begin_mail_test(tracker, now);
	changed(public_mail_test(tracker));

	let started = start_delivery((delivered) => {
		if (finish_mail_test(tracker, current.id, delivered, completed_at()))
			changed(public_mail_test(tracker));
	});

	if (!started) {
		finish_mail_test(tracker, current.id, false, completed_at());
		changed(public_mail_test(tracker));
		return { ok: false, error: 'mail delivery failed' };
	}

	return { ok: true, id: current.id };
};
