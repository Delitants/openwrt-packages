const fs = require('fs');
const socket = require('socket');
const uloop = require('uloop');
import { parse_ping } from 'ping';

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

function ping_command(monitor) {
	let binary = match(monitor.target, /:/) ? '/bin/ping6' : '/bin/ping';
	let count = fixed_integer(monitor.packet_count, 1, 20, 3);
	let timeout = fixed_integer(monitor.timeout, 1, 60, 5);

	// safe_target() excludes quotes and shell syntax. All other fields are fixed
	// numeric flags, so popen() cannot be turned into a generic shell runner.
	return sprintf("%s -c %d -W %d '%s' 2>&1",
		binary, count, timeout, monitor.target);
};

function run_ping(monitor) {
	let proc = fs.popen(ping_command(monitor), 'r');

	if (!proc)
		return probe_result(false, 'probe_start', 'unable to start ping');

	// A normalized monitor emits at most twenty reply lines. Keep diagnostic
	// input bounded anyway and never return command stderr verbatim.
	let output = proc.read(16384) ?? '';
	let exit_code = proc.close();

	return parse_ping(output, exit_code ?? 1, monitor);
};

function tcp_reason(error_code) {
	if (type(error_code) == 'int' && error_code < 0)
		return 'dns';

	// Linux errno values used by OpenWrt: ECONNREFUSED and ETIMEDOUT.
	if (error_code == 111)
		return 'refused';

	if (error_code == 110)
		return 'timeout';

	return 'connect_failed';
};

function run_tcp(monitor, timeout_ms) {
	let connection = socket.connect(monitor.target, monitor.port,
		{ socktype: socket.SOCK_STREAM }, timeout_ms);

	if (connection) {
		connection.close();
		return probe_result(true, null, 'TCP connection succeeded');
	}

	let reason = tcp_reason(socket.error(true));
	return probe_result(false, reason, `TCP ${reason}`);
};

export function start_probe(monitor, callback) {
	if (type(monitor) != 'object' || type(callback) != 'function' ||
		!safe_target(monitor.target) || !(monitor.type in ['ping', 'tcp']))
		return false;

	if (monitor.type == 'tcp' &&
		(type(monitor.port) != 'int' || monitor.port < 1 || monitor.port > 65535))
		return false;

	let timeout_ms = fixed_integer(monitor.timeout, 1, 60, 5) * 1000;
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

	task_handle = uloop.task(
		(pipe) => {
			let result;

			try {
				result = monitor.type == 'ping'
					? run_ping(monitor)
					: run_tcp(monitor, timeout_ms);
			}
			catch (error) {
				result = probe_result(false,
					monitor.type == 'tcp' ? 'connect_failed' : 'probe_failed',
					'probe failed');
			}

			pipe.send(result);
		},
		(result) => finish(result)
	);

	if (!task_handle)
		return false;

	timeout_handle = uloop.timer(timeout_ms, () => {
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
