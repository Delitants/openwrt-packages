import { parse_ping } from 'ping';

const PING_INTERVAL_MS = 1000;
const PING_GRACE_MS = 1000;

function probe_result(ok, reason, detail) {
	return {
		ok,
		reason,
		loss: null,
		avg_rtt: null,
		detail
	};
};

function safe_target(target) {
	return type(target) == 'string' &&
		substr(target, 0, 1) != '-' &&
		!!match(target, /^[A-Za-z0-9_.:%-]+$/);
};

function fixed_integer(value, minimum, maximum, fallback) {
	return type(value) == 'int' && value >= minimum && value <= maximum
		? value
		: fallback;
};

export function ping_timeout_ms(monitor) {
	let count = fixed_integer(monitor.packet_count, 1, 20, 3);
	let timeout = fixed_integer(monitor.timeout, 1, 60, 5);

	// BusyBox sends the first packet immediately, waits one second between
	// packets, then allows -W seconds for the final reply. Leave one second for
	// fork, scheduling, output parsing, and delivery to the parent callback.
	return (count - 1) * PING_INTERVAL_MS + timeout * 1000 + PING_GRACE_MS;
};

export function ping_command(monitor) {
	let binary = match(monitor.target, /:/) ? '/bin/ping6' : '/bin/ping';
	let count = fixed_integer(monitor.packet_count, 1, 20, 3);
	let timeout = fixed_integer(monitor.timeout, 1, 60, 5);

	// safe_target() excludes quotes and shell syntax. All other fields are fixed
	// numeric flags, so popen() cannot be turned into a generic shell runner.
	return sprintf("%s -c %d -W %d '%s' 2>&1",
		binary, count, timeout, monitor.target);
};

export function run_ping_with(monitor, fs_module) {
	let proc = fs_module.popen(ping_command(monitor), 'r');

	if (!proc)
		return probe_result(false, 'probe_start', 'unable to start ping');

	// A normalized monitor emits at most twenty reply lines. Keep diagnostic
	// input bounded anyway and never return command stderr verbatim.
	let output = proc.read(16384) ?? '';
	let exit_code = proc.close();

	return parse_ping(output, exit_code ?? 1, monitor);
};

export function tcp_reason(error_code) {
	if (type(error_code) == 'int' && error_code < 0)
		return 'dns';

	// Linux errno values used by OpenWrt: ECONNREFUSED and ETIMEDOUT.
	if (error_code == 111)
		return 'refused';

	if (error_code == 110)
		return 'timeout';

	return 'connect_failed';
};

export function run_tcp_with(monitor, timeout_ms, socket_module) {
	let connection = socket_module.connect(monitor.target, monitor.port,
		{ socktype: socket_module.SOCK_STREAM }, timeout_ms);

	if (connection) {
		connection.close();
		return probe_result(true, null, 'TCP connection succeeded');
	}

	let reason = tcp_reason(socket_module.error(true));
	return probe_result(false, reason, `TCP ${reason}`);
};

function valid_probe(monitor, callback) {
	if (type(monitor) != 'object' || type(callback) != 'function' ||
		!safe_target(monitor.target) || !(monitor.type in ['ping', 'tcp']))
		return false;

	if (monitor.type == 'tcp' &&
		(type(monitor.port) != 'int' || monitor.port < 1 || monitor.port > 65535))
		return false;

	return true;
};

export function start_probe_with(monitor, callback, dependencies) {
	if (!valid_probe(monitor, callback) || type(dependencies) != 'object' ||
		type(dependencies.fs) != 'object' ||
		type(dependencies.socket) != 'object' ||
		type(dependencies.uloop) != 'object')
		return false;

	let timeout_ms = fixed_integer(monitor.timeout, 1, 60, 5) * 1000;
	let parent_timeout_ms = monitor.type == 'ping'
		? ping_timeout_ms(monitor)
		: timeout_ms;
	let task_handle = null;
	let timeout_handle = null;
	let completed = false;

	function finish(result) {
		if (completed)
			return;

		completed = true;

		if (timeout_handle)
			timeout_handle.cancel();

		callback(result);
	};

	task_handle = dependencies.uloop.task(
		() => {
			// uloop.task() serializes this return value to the output callback.
			// Calling pipe.send() as well would emit a second message.
			try {
				return monitor.type == 'ping'
					? run_ping_with(monitor, dependencies.fs)
					: run_tcp_with(monitor, timeout_ms, dependencies.socket);
			}
			catch (error) {
				return probe_result(false,
					monitor.type == 'tcp' ? 'connect_failed' : 'probe_failed',
					'probe failed');
			}
		},
		(result) => finish(result)
	);

	if (!task_handle)
		return false;

	timeout_handle = dependencies.uloop.timer(parent_timeout_ms, () => {
		// The timer is firing now; avoid cancelling its handle from finish().
		timeout_handle = null;

		if (!task_handle.finished())
			task_handle.kill();

		finish(probe_result(false, 'timeout', 'probe timed out'));
	});

	if (!timeout_handle) {
		completed = true;
		task_handle.kill();
		return false;
	}

	return true;
};

export function start_probe(monitor, callback) {
	if (!valid_probe(monitor, callback))
		return false;

	return start_probe_with(monitor, callback, {
		fs: require('fs'),
		socket: require('socket'),
		uloop: require('uloop')
	});
};
