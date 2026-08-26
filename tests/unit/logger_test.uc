import { deep_equal, equal } from 'test';
import { new_logger } from 'logger';

let calls = [];
let configured = 'normal';
let fake_log = {
	syslog: (priority, format, ...args) =>
		push(calls, [ priority, format, ...args ])
};
let logger = new_logger(fake_log, () => configured);

function exercise(level) {
	calls = [];
	configured = level;
	logger.error('err', 'error %s', 'one');
	logger.normal('notice', 'normal %s', 'two');
	logger.verbose('info', 'verbose %s', 'three');
	return calls;
};

deep_equal(exercise('errors'), [
	[ 'err', 'error %s', 'one' ]
], 'errors level emits only errors');

deep_equal(exercise('normal'), [
	[ 'err', 'error %s', 'one' ],
	[ 'notice', 'normal %s', 'two' ]
], 'normal level suppresses verbose entries');

deep_equal(exercise('verbose'), [
	[ 'err', 'error %s', 'one' ],
	[ 'notice', 'normal %s', 'two' ],
	[ 'info', 'verbose %s', 'three' ]
], 'verbose level emits all entries');

deep_equal(exercise('invalid'), [
	[ 'err', 'error %s', 'one' ],
	[ 'notice', 'normal %s', 'two' ]
], 'invalid runtime level safely normalizes to normal');

configured = 'errors';
calls = [];
equal(logger.verbose('info', 'before'), false,
	'provider value is consulted before suppression');
configured = 'verbose';
equal(logger.verbose('info', 'after'), true,
	'provider changes apply without reconstructing logger');
deep_equal(calls, [ [ 'info', 'after' ] ],
	'only newly enabled call reaches syslog');
