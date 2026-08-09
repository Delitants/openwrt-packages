import { deep_equal, equal, truthy } from 'test';
import { prepare_delivery, finish_delivery, close_delivery } from 'mail_delivery';

function fake_delivery(options) {
	options = options ?? {};
	let handles = [];
	let opens = [];
	let open_count = 0;

	let deps = {
		mkstemp: (template) => {
			open_count++;
			push(opens, {
				template,
				mode: 0o600,
				unlinked: true
			});

			if (options.fail_open == open_count)
				return null;

			let handle_number = length(handles) + 1;
			let handle = {
				descriptor: 40 + handle_number,
				contents: '',
				close_calls: 0,
				read_limits: [],
				seek_calls: 0,
				write_calls: 0,
				flush_calls: 0
			};
			handle.write = (value) => {
				handle.write_calls++;
				handle.contents = value;
				return options.short_write && handle_number == 1
					? length(value) - 1 : length(value);
			};
			handle.flush = () => {
				handle.flush_calls++;
				return !(options.fail_flush && handle_number == 1);
			};
			handle.seek = (offset) => {
				handle.seek_calls++;
				if (options.throw_seek == handle_number)
					die('fake seek failed');
				return !(options.fail_seek == handle_number);
			};
			handle.read = (limit) => {
				push(handle.read_limits, limit);
				if (options.throw_read == handle_number)
					die('fake read failed');
				return substr(handle.contents, 0, limit);
			};
			handle.fileno = () => options.invalid_fileno == handle_number
				? null : handle.descriptor;
			handle.close = () => {
				handle.close_calls++;
				if (options.throw_close == handle_number)
					die('fake close failed');
				return true;
			};

			push(handles, handle);
			return handle;
		}
	};

	return { deps, handles, opens };
};

function assert_closed_once(fake, label) {
	for (let index = 0; index < length(fake.handles); index++)
		equal(fake.handles[index].close_calls, 1,
			`${label} closes handle ${index + 1} exactly once`);
};

function prepared(fake, message) {
	let resources = prepare_delivery(message ?? 'Subject: test\n\nbody\n', fake.deps);
	truthy(resources, 'delivery resources prepared');
	return resources;
};

// Production bug caught: delivery prepares only message and marker descriptors.
let three = fake_delivery();
let three_resources = prepared(three);
deep_equal(map(three.opens, (entry) => entry.template), [
	'/var/run/netwatch/message-XXXXXX',
	'/var/run/netwatch/result-XXXXXX',
	'/var/run/netwatch/stderr-XXXXXX'
], 'three private delivery files prepared below the runtime directory');
deep_equal(map(three.opens, (entry) => entry.mode), [ 0o600, 0o600, 0o600 ],
	'all delivery files use private mode');
deep_equal(map(three.opens, (entry) => entry.unlinked), [ true, true, true ],
	'all fake private files are immediately unlinked');
deep_equal({
	message_path: three_resources.message_path,
	result_path: three_resources.result_path,
	stderr_path: three_resources.stderr_path
}, {
	message_path: '/proc/self/fd/41',
	result_path: '/proc/self/fd/42',
	stderr_path: '/proc/self/fd/43'
}, 'only inherited descriptor paths are exposed to the daemon');
equal(three.handles[0].contents, 'Subject: test\n\nbody\n',
	'message is written to the private input descriptor');
truthy(close_delivery(three_resources), 'prepared resources close');
assert_closed_once(three, 'normal cancellation');

// Production bug caught: setup failure leaks handles opened before the failure.
for (let fail_open in [ 1, 2, 3 ]) {
	let failed = fake_delivery({ fail_open });
	equal(prepare_delivery('message', failed.deps), null,
		`temporary file ${fail_open} setup failure is rejected`);
	assert_closed_once(failed, `temporary file ${fail_open} setup failure`);
}

for (let setup_case in [
	[ 'short message write', { short_write: true } ],
	[ 'message flush failure', { fail_flush: true } ],
	[ 'message rewind failure', { fail_seek: 1 } ],
	[ 'message descriptor failure', { invalid_fileno: 1 } ],
	[ 'result descriptor failure', { invalid_fileno: 2 } ],
	[ 'stderr descriptor failure', { invalid_fileno: 3 } ]
]) {
	let failed = fake_delivery(setup_case[1]);
	equal(prepare_delivery('message', failed.deps), null,
		`${setup_case[0]} is rejected`);
	assert_closed_once(failed, setup_case[0]);
}

// Production bug caught: a zero exit is accepted without the private marker.
let success = fake_delivery();
let success_resources = prepared(success);
success.handles[1].contents = 'ok';
success.handles[2].contents = 'unused warning';
deep_equal(finish_delivery(success_resources, 0, false), {
	ok: true,
	failure: null
}, 'zero exit plus private marker succeeds');
deep_equal(success.handles[1].read_limits, [ 2 ],
	'success marker read is bounded');
deep_equal(success.handles[2].read_limits, [ 4096 ],
	'normal stderr read is capped at 4096 bytes');
assert_closed_once(success, 'success');

let missing_marker = fake_delivery();
let missing_marker_resources = prepared(missing_marker);
missing_marker.handles[2].contents = 'msmtp: helper exited without marker';
deep_equal(finish_delivery(missing_marker_resources, 0, false), {
	ok: false,
	failure: {
		stage: 'process', summary: 'SMTP delivery process failed.',
		detail: 'helper exited without marker', exit_code: 0,
		exit_name: null, smtp_status: null
	}
}, 'zero exit without marker fails');
assert_closed_once(missing_marker, 'missing marker failure');

// Production bug caught: nonzero msmtp exits are flattened to a boolean.
let nonzero = fake_delivery();
let nonzero_resources = prepared(nonzero);
nonzero.handles[1].contents = 'ok';
nonzero.handles[2].contents =
	'msmtp: network read error: the operation timed out';
deep_equal(finish_delivery(nonzero_resources, 74, false), {
	ok: false,
	failure: {
		stage: 'network', summary: 'SMTP network I/O failed.',
		detail: 'network read error: the operation timed out', exit_code: 74,
		exit_name: 'EX_IOERR', smtp_status: null
	}
}, 'nonzero exit returns classified failure despite marker');
assert_closed_once(nonzero, 'nonzero failure');

// Production bug caught: timeout publishes hostile stderr instead of fixed text.
let timeout = fake_delivery();
let timeout_resources = prepared(timeout);
timeout.handles[2].contents = 'msmtp: password=timeout-secret';
deep_equal(finish_delivery(timeout_resources, null, true), {
	ok: false,
	failure: {
		stage: 'timeout', summary: 'SMTP network I/O timed out.',
		detail: 'SMTP delivery exceeded its time limit.', exit_code: null,
		exit_name: null, smtp_status: null
	}
}, 'timeout ignores hostile stderr');
deep_equal(timeout.handles[2].read_limits, [ 4096 ],
	'timeout stderr read remains capped');
assert_closed_once(timeout, 'timeout');

// Production bug caught: a result-read exception bypasses descriptor cleanup.
let read_failure = fake_delivery({ throw_read: 2 });
let read_failure_resources = prepared(read_failure);
read_failure.handles[2].contents = 'msmtp: helper failed';
deep_equal(finish_delivery(read_failure_resources, 1, false), {
	ok: false,
	failure: {
		stage: 'process', summary: 'SMTP delivery process failed.',
		detail: 'helper failed', exit_code: 1,
		exit_name: null, smtp_status: null
	}
}, 'marker read failure returns a classified outcome');
assert_closed_once(read_failure, 'marker read failure');

// Production bug caught: cancellation, shutdown, or repeated cleanup double-closes FDs.
for (let lifecycle in [ 'cancellation', 'shutdown' ]) {
	let stopped = fake_delivery();
	let stopped_resources = prepared(stopped);
	truthy(close_delivery(stopped_resources), `${lifecycle} cleanup succeeds`);
	truthy(close_delivery(stopped_resources), `${lifecycle} cleanup is idempotent`);
	assert_closed_once(stopped, lifecycle);
}

let close_failure = fake_delivery({ throw_close: 2 });
let close_failure_resources = prepared(close_failure);
equal(close_delivery(close_failure_resources), false,
	'close failure is reported after attempting every descriptor');
truthy(close_delivery(close_failure_resources),
	'repeated cleanup after close failure remains idempotent');
assert_closed_once(close_failure, 'close failure');
