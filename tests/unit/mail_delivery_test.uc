import { deep_equal, equal, truthy } from 'test';
import {
	prepare_delivery, finish_delivery, close_delivery, start_delivery_with
} from 'mail_delivery';

function fake_delivery(options) {
	options = options ?? {};
	let handles = [];
	let opens = [];
	let open_count = 0;

	let deps = {
		mkstemp: (template) => {
			open_count++;
			push(opens, template);

			if (options.throw_open == open_count)
				die('fake open failed');

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
				if (options.throw_write && handle_number == 1)
					die('fake write failed');
				handle.contents = value;
				return options.short_write && handle_number == 1
					? length(value) - 1 : length(value);
			};
			handle.flush = () => {
				handle.flush_calls++;
				if (options.throw_flush && handle_number == 1)
					die('fake flush failed');
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
		},
		stat: (path) => ({ mode: options.private_mode ?? 0o600 }),
		readlink: (path) => options.linked_descriptor
			? '/var/run/netwatch/still-linked'
			: '/var/run/netwatch/private-file (deleted)'
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
deep_equal(three.opens, [
	'/var/run/netwatch/message-XXXXXX',
	'/var/run/netwatch/result-XXXXXX',
	'/var/run/netwatch/stderr-XXXXXX'
], 'three private delivery files prepared below the runtime directory');
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
	[ 'thrown temporary-file open', { throw_open: 2 } ],
	[ 'short message write', { short_write: true } ],
	[ 'thrown message write', { throw_write: true } ],
	[ 'message flush failure', { fail_flush: true } ],
	[ 'thrown message flush', { throw_flush: true } ],
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

// Production bug caught: privacy is trusted rather than checked on real descriptors.
for (let privacy_case in [
	[ 'non-private descriptor mode', { private_mode: 0o640 } ],
	[ 'descriptor pathname remains linked', { linked_descriptor: true } ]
]) {
	let failed = fake_delivery(privacy_case[1]);
	equal(prepare_delivery('message', failed.deps), null,
		`${privacy_case[0]} is rejected`);
	assert_closed_once(failed, privacy_case[0]);
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

for (let stderr_failure in [
	[ 'stderr seek failure', { throw_seek: 3 } ],
	[ 'stderr read failure', { throw_read: 3 } ]
]) {
	let failed = fake_delivery(stderr_failure[1]);
	let failed_resources = prepared(failed);
	deep_equal(finish_delivery(failed_resources, 1, false), {
		ok: false,
		failure: {
			stage: 'process', summary: 'SMTP delivery process failed.',
			detail: '', exit_code: 1, exit_name: null, smtp_status: null
		}
	}, `${stderr_failure[0]} returns a fixed bounded failure`);
	assert_closed_once(failed, stderr_failure[0]);
}

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

function fake_lifecycle(options) {
	options = options ?? {};
	let files = fake_delivery(options.files);
	let process_callback = null;
	let timer_callback = null;
	let spawn_calls = 0;
	let timer_calls = 0;
	let kill_calls = 0;
	let settled_calls = 0;
	let published = [];
	let timer_handle = { cancel_calls: 0 };
	timer_handle.cancel = () => { timer_handle.cancel_calls++; return true; };
	let process_handle = { name: 'fake-msmtp-shell' };

	let context;
	context = start_delivery_with('message',
		(outcome) => push(published, outcome), {
			prepare: (message) => prepare_delivery(message, files.deps),
			finish: finish_delivery,
			close: close_delivery,
			spawn: (resources, callback) => {
				spawn_calls++;
				process_callback = callback;
				if (options.throw_spawn) die('fake spawn failed');
				return options.fail_spawn ? null : process_handle;
			},
			timer: (milliseconds, callback) => {
				timer_calls++;
				equal(milliseconds, 65000, 'delivery lifecycle retains 65 second timeout');
				timer_callback = callback;
				if (options.throw_timer) die('fake timer failed');
				return options.fail_timer ? null : timer_handle;
			},
			kill: (process) => {
				equal(process, process_handle, 'delivery kills only its tracked process');
				kill_calls++;
				return true;
			},
			settled: (finished) => {
				equal(finished, context, 'settlement identifies the owned delivery context');
				settled_calls++;
			}
		});

	return {
		files, context, published, timer_handle,
		process_callback: () => process_callback,
		timer_callback: () => timer_callback,
		spawn_calls: () => spawn_calls,
		timer_calls: () => timer_calls,
		kill_calls: () => kill_calls,
		settled_calls: () => settled_calls
	};
};

// Production bug caught: lifecycle setup failures reach process/timer work or leak FDs.
for (let setup_case in [
	[ 'open failure', { files: { fail_open: 2 } } ],
	[ 'write failure', { files: { short_write: true } } ],
	[ 'flush failure', { files: { fail_flush: true } } ]
]) {
	let failed = fake_lifecycle(setup_case[1]);
	equal(failed.context, null, `${setup_case[0]} prevents delivery start`);
	equal(failed.spawn_calls(), 0, `${setup_case[0]} does not spawn`);
	equal(failed.timer_calls(), 0, `${setup_case[0]} does not create timer`);
	assert_closed_once(failed.files, `lifecycle ${setup_case[0]}`);
}

for (let spawn_case in [
	[ 'spawn failure', { fail_spawn: true } ],
	[ 'thrown spawn', { throw_spawn: true } ]
]) {
	let failed = fake_lifecycle(spawn_case[1]);
	equal(failed.context, null, `${spawn_case[0]} rejects delivery start`);
	equal(failed.timer_calls(), 0, `${spawn_case[0]} does not create timer`);
	assert_closed_once(failed.files, spawn_case[0]);
}

for (let timer_case in [
	[ 'timer failure', { fail_timer: true } ],
	[ 'thrown timer', { throw_timer: true } ]
]) {
	let failed = fake_lifecycle(timer_case[1]);
	equal(failed.context, null, `${timer_case[0]} rejects delivery start`);
	equal(failed.kill_calls(), 1, `${timer_case[0]} kills spawned process`);
	assert_closed_once(failed.files, timer_case[0]);
	failed.process_callback()(124);
	equal(failed.kill_calls(), 1, `${timer_case[0]} late exit does not kill again`);
	equal(failed.settled_calls(), 0, `${timer_case[0]} late exit does not settle`);
	equal(length(failed.published), 0, `${timer_case[0]} late exit does not publish`);
	assert_closed_once(failed.files, `${timer_case[0]} late exit`);
}

// Production bug caught: a late canceled timer kills an already completed process.
let normal = fake_lifecycle();
truthy(normal.context, 'normal lifecycle starts');
normal.files.handles[1].contents = 'ok';
normal.process_callback()(0);
deep_equal(normal.published, [ { ok: true, failure: null } ],
	'normal process completion publishes one structured outcome');
equal(normal.timer_handle.cancel_calls, 1, 'normal completion cancels its timer once');
equal(normal.settled_calls(), 1, 'normal completion settles once');
assert_closed_once(normal.files, 'normal lifecycle completion');
normal.timer_callback()();
equal(normal.kill_calls(), 0, 'late canceled timer does not kill completed process');
equal(normal.settled_calls(), 1, 'late canceled timer does not settle again');
equal(length(normal.published), 1, 'late canceled timer does not publish again');
assert_closed_once(normal.files, 'late timer after normal completion');

// Production bug caught: a late process callback overrides a timeout result.
let timed = fake_lifecycle();
truthy(timed.context, 'timeout lifecycle starts');
timed.files.handles[2].contents = 'msmtp: password=timeout-secret';
timed.timer_callback()();
equal(timed.kill_calls(), 1, 'timeout kills tracked process once');
equal(timed.published[0].failure.stage, 'timeout',
	'timeout publishes fixed timeout outcome');
equal(timed.settled_calls(), 1, 'timeout settles once');
assert_closed_once(timed.files, 'timeout lifecycle');
timed.process_callback()(124);
timed.timer_callback()();
equal(timed.kill_calls(), 1, 'late callbacks do not kill again after timeout');
equal(timed.settled_calls(), 1, 'late callbacks do not settle again after timeout');
equal(length(timed.published), 1, 'late callbacks do not publish after timeout');
assert_closed_once(timed.files, 'late callbacks after timeout');

// Production bug caught: shutdown cancellation publishes or closes again on callbacks.
let stopped = fake_lifecycle();
truthy(stopped.context, 'shutdown lifecycle starts');
truthy(stopped.context.stop(), 'shutdown cancellation stops active delivery');
equal(stopped.kill_calls(), 1, 'shutdown cancellation kills tracked process once');
equal(stopped.timer_handle.cancel_calls, 1, 'shutdown cancellation cancels timer once');
equal(length(stopped.published), 0, 'shutdown cancellation publishes no outcome');
assert_closed_once(stopped.files, 'shutdown cancellation');
stopped.timer_callback()();
equal(stopped.kill_calls(), 1, 'late timer after shutdown does not kill again');
stopped.process_callback()(124);
stopped.process_callback()(124);
equal(stopped.settled_calls(), 1, 'late shutdown process callback settles once');
equal(length(stopped.published), 0, 'late shutdown callbacks remain unpublished');
assert_closed_once(stopped.files, 'late shutdown callbacks');
