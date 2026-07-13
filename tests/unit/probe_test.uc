import { equal } from 'test';
import {
	ping_timeout_ms,
	ping_command,
	tcp_reason,
	run_ping_with,
	run_tcp_with,
	start_probe_with
} from 'probe';

equal(ping_timeout_ms({ packet_count: 3, timeout: 5 }), 8000,
	'ping timeout includes intervals, final wait, and grace');
equal(ping_timeout_ms({ packet_count: 20, timeout: 60 }), 80000,
	'ping timeout remains bounded at normalized maxima');

equal(tcp_reason(-2), 'dns', 'resolver error normalized');
equal(tcp_reason(111), 'refused', 'connection refusal normalized');
equal(tcp_reason(110), 'timeout', 'connection timeout normalized');
equal(tcp_reason(5), 'connect_failed', 'other connection error normalized');

let ping_invocation = null;
let total_loss = '3 packets transmitted, 0 packets received, 100% packet loss';
let fake_fs = {
	popen: (command, mode) => {
		ping_invocation = `${mode}:${command}`;

		return {
			read: (limit) => limit == 16384 ? total_loss : '',
			close: () => 1
		};
	}
};
let ping_monitor = {
	type: 'ping', target: '198.51.100.9', packet_count: 3, timeout: 5,
	loss_enabled: true, max_loss: 100, rtt_enabled: false
};
let result = run_ping_with(ping_monitor, fake_fs);
equal(ping_invocation, "r:/bin/ping -c 3 -W 5 '198.51.100.9' 2>&1",
	'ping command uses fixed flags and quoted target');
equal(result.reason, 'unreachable', 'total-loss command result parsed');
equal(result.loss, 100, 'total-loss command metric preserved');

let connect_target = null;
let connect_port = null;
let connect_socktype = null;
let connect_timeout = null;
let fake_socket = {
	SOCK_STREAM: 1,
	connect: (target, port, hints, timeout) => {
		connect_target = target;
		connect_port = port;
		connect_socktype = hints.socktype;
		connect_timeout = timeout;
		return null;
	},
	error: (numeric) => numeric ? 111 : 'refused'
};
result = run_tcp_with({ target: 'server.example', port: 443 }, 5000, fake_socket);
equal(connect_target, 'server.example', 'TCP target passed directly');
equal(connect_port, 443, 'TCP port passed directly');
equal(connect_socktype, 1, 'TCP stream hint passed');
equal(connect_timeout, 5000, 'TCP timeout passed in milliseconds');
equal(result.reason, 'refused', 'TCP result normalized');

let task_function = null;
let output_callback = null;
let timeout_callback = null;
let scheduled_timeout = null;
let timer_cancels = 0;
let task_kills = 0;
let task_finished = false;
let fake_uloop = {
	task: (worker, output) => {
		task_function = worker;
		output_callback = output;

		return {
			finished: () => task_finished,
			kill: () => { task_kills++; return true; }
		};
	},
	timer: (timeout, callback) => {
		scheduled_timeout = timeout;
		timeout_callback = callback;

		return {
			cancel: () => { timer_cancels++; return true; }
		};
	}
};
let callback_count = 0;
let callback_reason = null;
let dependencies = { fs: fake_fs, socket: fake_socket, uloop: fake_uloop };
equal(start_probe_with(ping_monitor, (probe_result) => {
	callback_count++;
	callback_reason = probe_result.reason;
}, dependencies), true, 'probe starts through injected dependencies');
equal(scheduled_timeout, 8000, 'ping uses complete parent timeout budget');

let explicit_sends = 0;
let task_result = task_function({
	send: (message) => { explicit_sends++; output_callback(message); }
});
task_finished = true;
output_callback(task_result);
equal(explicit_sends, 0, 'task returns one result instead of explicitly sending');
equal(callback_count, 1, 'result path calls parent exactly once');
equal(callback_reason, 'unreachable', 'result path preserves probe result');
equal(timer_cancels, 1, 'result path cancels timeout');
timeout_callback();
equal(callback_count, 1, 'late timeout cannot call parent again');

task_function = null;
output_callback = null;
timeout_callback = null;
scheduled_timeout = null;
timer_cancels = 0;
task_kills = 0;
task_finished = false;
callback_count = 0;
callback_reason = null;
equal(start_probe_with(ping_monitor, (probe_result) => {
	callback_count++;
	callback_reason = probe_result.reason;
}, dependencies), true, 'second probe starts through injected dependencies');
timeout_callback();
equal(timer_cancels, 1, 'timeout path cancels firing timeout');
equal(task_kills, 1, 'timeout kills unfinished task');
equal(callback_count, 1, 'timeout path calls parent exactly once');
equal(callback_reason, 'timeout', 'timeout path returns normalized reason');
task_result = task_function({
	send: (message) => { explicit_sends++; output_callback(message); }
});
output_callback(task_result);
equal(callback_count, 1, 'late task result cannot call parent again');
