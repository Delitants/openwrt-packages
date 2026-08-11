import * as fs from 'fs';
import { classify_mail_failure, fixed_mail_failure } from 'mail_failure';

const RUNTIME_DIR = '/var/run/netwatch';
const STDERR_LIMIT = 4096;
const PROCESS_TIMEOUT_MS = 65000;

function dependencies(deps) {
	return type(deps?.mkstemp) == 'function' ? deps : {
		mkstemp: (template) => fs.mkstemp(template),
		stat: (path) => fs.stat(path),
		readlink: (path) => fs.readlink(path)
	};
};

function private_descriptor(deps, path) {
	let status;
	let target;

	try {
		status = deps.stat(path);
		target = deps.readlink(path);
	}
	catch (error) {
		return false;
	}

	return type(status?.mode) == 'int' &&
		(status.mode & 0o777) == 0o600 &&
		type(target) == 'string' && !!match(target, / \(deleted\)$/);
};

function process_failure() {
	return {
		ok: false,
		failure: fixed_mail_failure('process',
			'SMTP delivery process failed.', '')
	};
};

export function close_delivery(resources) {
	if (type(resources) != 'object' || resources.closed === true)
		return true;

	resources.closed = true;
	let closed = true;

	for (let name in [ 'message_file', 'result_file', 'stderr_file' ]) {
		let handle = resources[name];
		resources[name] = null;

		if (!handle)
			continue;

		try {
			if (!handle.close())
				closed = false;
		}
		catch (error) {
			closed = false;
		}
	}

	return closed;
};

export function prepare_delivery(message, deps) {
	if (type(message) != 'string')
		return null;

	deps = dependencies(deps);
	let resources = {
		message_file: null,
		message_path: null,
		result_file: null,
		result_path: null,
		stderr_file: null,
		stderr_path: null,
		closed: false
	};

	try {
		resources.message_file = deps.mkstemp(`${RUNTIME_DIR}/message-XXXXXX`);
		if (!resources.message_file) {
			close_delivery(resources);
			return null;
		}

		resources.result_file = deps.mkstemp(`${RUNTIME_DIR}/result-XXXXXX`);
		if (!resources.result_file) {
			close_delivery(resources);
			return null;
		}

		resources.stderr_file = deps.mkstemp(`${RUNTIME_DIR}/stderr-XXXXXX`);
		if (!resources.stderr_file ||
			resources.message_file.write(message) != length(message) ||
			!resources.message_file.flush() ||
			!resources.message_file.seek(0)) {
			close_delivery(resources);
			return null;
		}

		let message_descriptor = resources.message_file.fileno();
		let result_descriptor = resources.result_file.fileno();
		let stderr_descriptor = resources.stderr_file.fileno();

		if (type(message_descriptor) != 'int' ||
			type(result_descriptor) != 'int' ||
			type(stderr_descriptor) != 'int') {
			close_delivery(resources);
			return null;
		}

		resources.message_path = `/proc/self/fd/${message_descriptor}`;
		resources.result_path = `/proc/self/fd/${result_descriptor}`;
		resources.stderr_path = `/proc/self/fd/${stderr_descriptor}`;

		if (!private_descriptor(deps, resources.message_path) ||
			!private_descriptor(deps, resources.result_path) ||
			!private_descriptor(deps, resources.stderr_path)) {
			close_delivery(resources);
			return null;
		}

		return resources;
	}
	catch (error) {
		close_delivery(resources);
		return null;
	}
};

export function finish_delivery(resources, exit_code, timed_out) {
	if (type(resources) != 'object' || resources.closed === true)
		return process_failure();

	let marker = '';
	let stderr = '';

	try {
		if (resources.result_file?.seek(0))
			marker = resources.result_file.read(2) ?? '';
	}
	catch (error) {
		marker = '';
	}

	try {
		if (resources.stderr_file?.seek(0))
			stderr = resources.stderr_file.read(STDERR_LIMIT) ?? '';
	}
	catch (error) {
		stderr = '';
	}

	let succeeded = timed_out !== true && exit_code === 0 && marker == 'ok';
	close_delivery(resources);

	return succeeded
		? { ok: true, failure: null }
		: {
			ok: false,
			failure: classify_mail_failure(exit_code, stderr,
				timed_out === true, null)
		};
};

export function start_delivery_with(message, callback, deps) {
	if (type(callback) != 'function' ||
		type(deps?.prepare) != 'function' ||
		type(deps?.finish) != 'function' ||
		type(deps?.close) != 'function' ||
		type(deps?.spawn) != 'function' ||
		type(deps?.timer) != 'function' ||
		type(deps?.kill) != 'function' ||
		type(deps?.settled) != 'function')
		return null;

	let resources;

	try {
		resources = deps.prepare(message);
	}
	catch (error) {
		return null;
	}

	if (!resources)
		return null;

	let process_handle = null;
	let timeout_handle = null;
	let completed = false;
	let cancelled = false;
	let context = { stop: null };

	function cancel_timeout() {
		if (!timeout_handle)
			return true;

		let handle = timeout_handle;
		timeout_handle = null;

		try {
			return !!handle.cancel();
		}
		catch (error) {
			return false;
		}
	};

	function settle(outcome, publish) {
		if (completed)
			return false;

		completed = true;
		cancel_timeout();
		deps.close(resources);
		deps.settled(context);

		if (publish)
			callback(outcome);

		return true;
	};

	context.stop = () => {
		if (completed || cancelled)
			return false;

		cancelled = true;
		cancel_timeout();
		deps.close(resources);
		deps.kill(process_handle);
		return true;
	};

	try {
		process_handle = deps.spawn(resources, (exit_code) => {
			if (completed)
				return;

			if (cancelled) {
				settle(null, false);
				return;
			}

			let outcome = deps.finish(resources, exit_code, false);
			settle(outcome, true);
		});
	}
	catch (error) {
		deps.close(resources);
		return null;
	}

	if (!process_handle) {
		deps.close(resources);
		return null;
	}

	try {
		timeout_handle = deps.timer(
			type(deps.timeout_ms) == 'int' ? deps.timeout_ms : PROCESS_TIMEOUT_MS,
			() => {
				if (completed || !timeout_handle)
					return;

				cancel_timeout();
				deps.kill(process_handle);
				let outcome = deps.finish(resources, null, true);
				settle(outcome, true);
			}
		);
	}
	catch (error) {
		completed = true;
		deps.kill(process_handle);
		deps.close(resources);
		return null;
	}

	if (!timeout_handle) {
		completed = true;
		deps.kill(process_handle);
		deps.close(resources);
		return null;
	}

	return context;
};
