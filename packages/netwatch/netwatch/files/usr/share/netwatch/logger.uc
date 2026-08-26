const LEVELS = {
	errors: 0,
	normal: 1,
	verbose: 2
};

export function new_logger(log_module, level_provider) {
	function configured_level() {
		let value = level_provider();
		return value in LEVELS ? value : 'normal';
	};

	function emit(required, priority, format, ...args) {
		if (LEVELS[configured_level()] < LEVELS[required])
			return false;

		log_module.syslog(priority, format, ...args);
		return true;
	};

	return {
		error: (priority, format, ...args) =>
			emit('errors', priority, format, ...args),
		normal: (priority, format, ...args) =>
			emit('normal', priority, format, ...args),
		verbose: (priority, format, ...args) =>
			emit('verbose', priority, format, ...args)
	};
};
