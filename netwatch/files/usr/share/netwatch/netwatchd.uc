import * as fs from 'fs';
import * as log from 'log';
import * as ubus from 'ubus';
import * as uci from 'uci';
import * as uloop from 'uloop';
import { normalize_global, normalize_smtp, normalize_monitor } from 'config';
import { new_state, apply_result } from 'state';
import { due_alert, mail_succeeded, mail_failed } from 'alerts';
import { render_msmtp, render_message, split_recipients } from 'message';
import { start_probe } from 'probe';
import { public_status, write_status } from 'store';

const RUNTIME_DIR = '/var/run/netwatch';
const MSMTP_FILE = '/var/run/netwatch/msmtprc';
const MSMTP_TEMP = '/var/run/netwatch/msmtprc.tmp';
const MSMTP_COMMAND = `/usr/bin/msmtp --file=/var/run/netwatch/msmtprc --timeout=60 --read-envelope-from --read-recipients < "$1" >/dev/null 2>&1 &
child=$!
trap 'kill -KILL "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 124' TERM INT
wait "$child"
status=$?
if [ "$status" -eq 0 ]; then
	printf ok > "$2"
fi
exit "$status"`;
const MSMTP_PROCESS_TIMEOUT_MS = 65000;
const SCHEDULER_INTERVAL_MS = 1000;

let daemon_started = time();
let last_reload = daemon_started;
let mail_error = null;
let mail_config_ready = false;
let global_config = normalize_global({});
let smtp_config = normalize_smtp({});
let monitors = [];
let monitor_by_id = {};
let states = [];
let state_by_id = {};
let next_check = {};
let generation = 0;
let scheduler = null;

function persist_status() {
	if (!write_status(daemon_started, last_reload, mail_error, states))
		log.syslog('err', 'unable to write public status');
};

function ensure_runtime_directory() {
	fs.mkdir(RUNTIME_DIR, 0o700);

	if (!fs.stat(RUNTIME_DIR) || !fs.chmod(RUNTIME_DIR, 0o700))
		die('unable to prepare runtime directory\n');
};

function safe_router_hostname() {
	let hostname = trim(fs.readfile('/proc/sys/kernel/hostname', 256) ?? '');

	return (hostname != '' && !!match(hostname, /^[A-Za-z0-9_.-]+$/))
		? hostname
		: 'router';
};

function install_mail_config(contents) {
	let file = fs.open(MSMTP_TEMP, 'w', 0o600);

	if (!file)
		return false;

	if (!fs.chmod(MSMTP_TEMP, 0o600) ||
		file.write(contents) != length(contents) || !file.flush()) {
		file.close();
		fs.unlink(MSMTP_TEMP);
		return false;
	}

	if (!file.close() || !fs.rename(MSMTP_TEMP, MSMTP_FILE)) {
		fs.unlink(MSMTP_TEMP);
		return false;
	}

	if (!fs.chmod(MSMTP_FILE, 0o600)) {
		fs.unlink(MSMTP_FILE);
		return false;
	}

	return true;
};

function configure_mail(next_smtp) {
	let contents;

	fs.unlink(MSMTP_TEMP);
	fs.unlink(MSMTP_FILE);

	try {
		contents = render_msmtp(next_smtp);
	}
	catch (error) {
		mail_config_ready = false;
		mail_error = 'mail configuration invalid';
		return;
	}

	mail_config_ready = install_mail_config(contents);
	mail_error = mail_config_ready ? null : 'mail delivery failed';
};

function fixed_probe_failure(reason, detail) {
	return {
		ok: false,
		reason,
		loss: null,
		avg_rtt: null,
		detail
	};
};

function monitor_state_is_current(id, state) {
	return state_by_id[id] === state;
};

function record_probe_result(id, state, run_generation, result) {
	let completed_at = time();
	let current_monitor = monitor_by_id[id];

	state.busy = false;

	if (!monitor_state_is_current(id, state))
		return;

	if (run_generation != generation || !current_monitor ||
		!current_monitor.enabled) {
		next_check[id] = completed_at;
		persist_status();

		if (scheduler)
			scheduler.set(0);

		return;
	}

	let previous_status = state.status;
	let transition = apply_result(state, current_monitor, result, completed_at);
	next_check[id] = completed_at + current_monitor.interval;

	log.syslog(result.ok ? 'info' : 'warning',
		'monitor %s probe result %s', id, result.ok ? 'healthy' : result.reason);

	if (state.status != previous_status)
		log.syslog('notice', 'monitor %s transition %s', id, transition);

	persist_status();

	if (scheduler)
		scheduler.set(0);
};

function start_monitor_check(monitor) {
	let state = state_by_id[monitor.id];

	if (!state || state.busy || state.mail_busy || !monitor.enabled)
		return false;

	state.busy = true;
	let run_generation = generation;

	if (!start_probe(monitor, (result) =>
		record_probe_result(monitor.id, state, run_generation, result))) {
		record_probe_result(monitor.id, state, run_generation,
			fixed_probe_failure('probe_start', 'unable to start probe'));
		return false;
	}

	persist_status();
	return true;
};

function prepare_message_input(message) {
	let message_file = fs.mkstemp(`${RUNTIME_DIR}/message-XXXXXX`);

	if (!message_file)
		return null;

	let result_file = fs.mkstemp(`${RUNTIME_DIR}/result-XXXXXX`);

	if (!result_file) {
		message_file.close();
		return null;
	}

	if (message_file.write(message) != length(message) ||
		!message_file.flush() || !message_file.seek(0)) {
		message_file.close();
		result_file.close();
		return null;
	}

	let message_descriptor = message_file.fileno();
	let result_descriptor = result_file.fileno();

	if (type(message_descriptor) != 'int' ||
		type(result_descriptor) != 'int') {
		message_file.close();
		result_file.close();
		return null;
	}

	// fs.mkstemp() unlinks both 0600 files immediately. The child inherits the
	// descriptors and reopens them through procfs for input and its success
	// marker. No message or result pathname remains in the runtime directory.
	return {
		message_file,
		message_path: `/proc/self/fd/${message_descriptor}`,
		result_file,
		result_path: `/proc/self/fd/${result_descriptor}`
	};
};

function kill_delivery_process(process_handle) {
	let pid;

	try {
		pid = process_handle.pid();
	}
	catch (error) {
		return false;
	}

	if (type(pid) != 'int' || pid <= 1)
		return false;

	// OpenWrt's base BusyBox enables /bin/kill. Arguments are fixed except for
	// the numeric PID returned by the tracked uloop process.
	let killer;

	try {
		killer = uloop.process('/bin/kill',
			['-TERM', sprintf('%d', pid)], {}, (exit_code) => {});
	}
	catch (error) {
		return false;
	}

	return !!killer;
};

function start_delivery(message, callback) {
	let process_handle = null;
	let timeout_handle = null;
	let completed = false;
	let result_file = null;

	function close_delivery_result() {
		if (!result_file)
			return;

		result_file.close();
		result_file = null;
	};

	function delivery_result_succeeded() {
		let delivered = false;

		if (result_file) {
			try {
				delivered = !!result_file.seek(0) &&
					result_file.read(2) == 'ok';
			}
			catch (error) {
				delivered = false;
			}
		}

		close_delivery_result();
		return delivered;
	};

	function finish(delivered) {
		if (completed)
			return;

		completed = true;

		if (timeout_handle) {
			timeout_handle.cancel();
			timeout_handle = null;
		}

		callback(delivered === true);
	};

	let input = prepare_message_input(message);

	if (!input)
		return false;

	result_file = input.result_file;

	try {
		process_handle = uloop.process('/bin/sh',
			['-c', MSMTP_COMMAND, 'netwatch-msmtp',
				input.message_path, input.result_path], {},
			(exit_code) => {
				let marker_present = delivery_result_succeeded();
				finish(exit_code == 0 && marker_present);
			}
		);
	}
	catch (error) {
		input.message_file.close();
		close_delivery_result();
		return false;
	}

	input.message_file.close();

	if (!process_handle) {
		close_delivery_result();
		return false;
	}

	try {
		timeout_handle = uloop.timer(MSMTP_PROCESS_TIMEOUT_MS, () => {
			kill_delivery_process(process_handle);
			close_delivery_result();
			finish(false);
		});
	}
	catch (error) {
		completed = true;
		kill_delivery_process(process_handle);
		close_delivery_result();
		return false;
	}

	if (!timeout_handle) {
		completed = true;
		kill_delivery_process(process_handle);
		close_delivery_result();
		return false;
	}

	return true;
};

function render_alert(kind, monitor, state, timestamp, recipients) {
	return render_message(kind, {
		smtp: smtp_config,
		recipients,
		monitor,
		state,
		router_hostname: safe_router_hostname(),
		timestamp
	});
};

function alert_render_failed(state, now, error_text) {
	mail_failed(state, now, global_config.mail_retry_backoff);
	mail_error = error_text;
	persist_status();
};

function start_alert(monitor, state, kind, now) {
	if (!mail_config_ready) {
		alert_render_failed(state, now, 'mail configuration invalid');
		return false;
	}

	let message;
	let recipients = monitor.recipients != ''
		? monitor.recipients
		: global_config.recipients;

	try {
		message = render_alert(kind, monitor, state, now, recipients);
	}
	catch (error) {
		alert_render_failed(state, now, 'recipient is invalid');
		return false;
	}

	state.mail_busy = true;
	let incident_started = kind == 'failure'
		? state.incident_started
		: state.recovery_pending?.incident_started;
	let delivery_started = start_delivery(
		message,
		(delivered) => {
			state.mail_busy = false;

			if (!monitor_state_is_current(monitor.id, state))
				return;

			let same_incident = kind == 'failure'
				? state.status == 'failed' &&
					state.incident_started == incident_started
				: state.recovery_pending?.incident_started == incident_started;

			if (same_incident && delivered === true) {
				mail_succeeded(state, kind, time());
				mail_error = null;
				log.syslog('info', 'monitor %s %s mail delivered', monitor.id, kind);
			}
			else if (same_incident) {
				mail_failed(state, time(), global_config.mail_retry_backoff);
				mail_error = 'mail delivery failed';
				log.syslog('err', 'monitor %s %s mail delivery failed', monitor.id, kind);
			}

			persist_status();

			if (scheduler)
				scheduler.set(0);
		}
	);

	if (!delivery_started) {
		state.mail_busy = false;
		mail_failed(state, now, global_config.mail_retry_backoff);
		mail_error = 'mail delivery failed';
		persist_status();
		return false;
	}

	return true;
};

function scheduler_tick() {
	let now = time();

	for (let monitor in monitors) {
		let state = state_by_id[monitor.id];

		if (!state || !monitor.enabled || state.busy || state.mail_busy)
			continue;

		if ((next_check[monitor.id] ?? now) <= now) {
			start_monitor_check(monitor);
			continue;
		}

		let kind = due_alert(state, monitor, now);

		if (kind)
			start_alert(monitor, state, kind, now);
	}

	scheduler.set(SCHEDULER_INTERVAL_MS);
};

function load_configuration() {
	let cursor = uci.cursor();
	let next_global;
	let next_smtp;
	let next_monitors = [];
	let next_monitor_by_id = {};
	let next_states = [];
	let next_state_by_id = {};
	let next_due = {};
	let loaded_at = time();

	try {
		next_global = normalize_global(cursor.get_all('netwatch', 'main') ?? {});
		next_smtp = normalize_smtp(cursor.get_all('netwatch', 'smtp') ?? {});

		cursor.foreach('netwatch', 'monitor', (raw) => {
			let id = raw['.name'];
			let normalized = normalize_monitor(id, raw);
			let monitor = normalized.value;
			let state = state_by_id[id] ?? new_state(id);

			monitor.enabled = next_global.enabled && monitor.enabled && normalized.ok;
			state.config_error = normalized.ok ? null : join('; ', normalized.errors);

			if (!monitor.enabled)
				apply_result(state, monitor, null, loaded_at);

			push(next_monitors, monitor);
			next_monitor_by_id[id] = monitor;
			push(next_states, state);
			next_state_by_id[id] = state;

			let first_due = daemon_started + next_global.startup_grace;
			next_due[id] = next_check[id] ??
				(first_due > loaded_at ? first_due : loaded_at);
		});
	}
	catch (error) {
		log.syslog('err', 'configuration reload failed');
		return false;
	}

	global_config = next_global;
	smtp_config = next_smtp;
	monitors = next_monitors;
	monitor_by_id = next_monitor_by_id;
	states = next_states;
	state_by_id = next_state_by_id;
	next_check = next_due;
	generation++;
	last_reload = loaded_at;

	configure_mail(smtp_config);
	persist_status();
	log.syslog('info', 'configuration reloaded');

	if (scheduler)
		scheduler.set(0);

	return true;
};

function request_check(request) {
	try {
		let id = request.args?.id;
		let monitor = type(id) == 'string' ? monitor_by_id[id] : null;
		let state = type(id) == 'string' ? state_by_id[id] : null;

		if (!monitor || !state)
			return { ok: false, error: 'monitor not found' };

		if (!monitor.enabled)
			return { ok: false, error: 'monitor unavailable' };

		if (state.busy || state.mail_busy)
			return { ok: false, error: 'check already running' };

		next_check[id] = time();
		scheduler.set(0);
		return { ok: true };
	}
	catch (error) {
		return { ok: false, error: 'check request failed' };
	}
};

function test_message(recipients, now) {
	let state = new_state('test');

	state.status = 'failed';
	state.incident_started = now;
	state.last_result = fixed_probe_failure('test', 'test notification');

	return render_message('failure', {
		smtp: smtp_config,
		recipients,
		monitor: {
			id: 'test',
			name: 'Netwatch test',
			target: safe_router_hostname(),
			max_alerts: 1
		},
		state,
		router_hostname: safe_router_hostname(),
		timestamp: now
	});
};

function request_test_email(request) {
	let message;

	try {
		if (!mail_config_ready)
			return { ok: false, error: 'mail configuration invalid' };

		let recipient = request.args?.recipient;
		let configured = type(recipient) == 'string' && recipient != ''
			? recipient
			: global_config.recipients;

		if (configured == '')
			return { ok: false, error: 'recipient is required' };

		let recipients;

		try {
			recipients = split_recipients(configured);
		}
		catch (error) {
			return { ok: false, error: 'recipient is invalid' };
		}

		message = test_message(recipients, time());
	}
	catch (error) {
		return { ok: false, error: 'test email failed' };
	}

	try {
		request.defer();
	}
	catch (error) {
		return { ok: false, error: 'test email failed' };
	}

	let delivery_started = start_delivery(message, (delivered) => {
		mail_error = delivered ? null : 'mail delivery failed';
		request.reply(delivered
			? { ok: true }
			: { ok: false, error: 'mail delivery failed' });
		persist_status();
	});

	if (!delivery_started) {
		mail_error = 'mail delivery failed';
		request.reply({ ok: false, error: 'mail delivery failed' });
		persist_status();
	}

	return;
};

log.openlog('netwatch', ['pid'], 'daemon');

if (!uloop.init())
	die('unable to initialize event loop\n');

ensure_runtime_directory();

let conn = ubus.connect();

if (!conn)
	die('unable to connect to ubus\n');

if (!load_configuration())
	die('unable to load configuration\n');

let service_object = conn.publish('netwatch', {
	status: {
		args: {},
		call: (request) => public_status(
			daemon_started, last_reload, mail_error, states)
	},
	check: {
		args: { id: '' },
		call: request_check
	},
	test_email: {
		args: { recipient: '' },
		call: request_test_email
	}
});

if (!service_object)
	die('unable to publish ubus service\n');

let reload_signal = uloop.signal('HUP', () => load_configuration());

if (!reload_signal)
	die('unable to install reload handler\n');

scheduler = uloop.timer(0, scheduler_tick);

if (!scheduler)
	die('unable to start scheduler\n');

uloop.run();
