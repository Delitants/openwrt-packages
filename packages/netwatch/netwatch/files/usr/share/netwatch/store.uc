import * as fs from 'fs';

const STATUS_TEMP = '/var/run/netwatch/status.json.tmp';
const STATUS_FILE = '/var/run/netwatch/status.json';

export function public_status(daemon_started, last_reload, mail_error, states) {
	return {
		version: 1,
		daemon_started,
		last_reload,
		mail_error,
		monitors: states.map((s) => ({
			id: s.id,
			status: s.status,
			last_check: s.last_check,
			last_result: s.last_result,
			consecutive_failures: s.consecutive_failures,
			incident_started: s.incident_started,
			failure_emails: s.failure_emails,
			config_error: s.config_error
		}))
	};
};

export function write_status(daemon_started, last_reload, mail_error, states) {
	let output = `${sprintf('%J',
		public_status(daemon_started, last_reload, mail_error, states))}\n`;
	let file = fs.open(STATUS_TEMP, 'w', 0o600);

	if (!file)
		return false;

	if (file.write(output) != length(output) || !file.flush()) {
		file.close();
		fs.unlink(STATUS_TEMP);
		return false;
	}

	if (!file.close()) {
		fs.unlink(STATUS_TEMP);
		return false;
	}

	if (!fs.rename(STATUS_TEMP, STATUS_FILE)) {
		fs.unlink(STATUS_TEMP);
		return false;
	}

	return true;
};
