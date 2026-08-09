import * as fs from 'fs';
import { classify_mail_failure, fixed_mail_failure } from 'mail_failure';

const RUNTIME_DIR = '/var/run/netwatch';
const STDERR_LIMIT = 4096;

function dependencies(deps) {
	return type(deps?.mkstemp) == 'function' ? deps : {
		mkstemp: (template) => fs.mkstemp(template)
	};
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
