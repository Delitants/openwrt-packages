import { deep_equal } from 'test';
import { service_methods } from 'rpc';

let calls = [];
let handlers = {
	status: (request) => push(calls, [ 'status', request.args ]),
	interfaces: (request) => push(calls, [ 'interfaces', request.args ]),
	check: (request) => push(calls, [ 'check', request.args ]),
	test_email: (request) => push(calls, [ 'test_email', request.args ])
};
let methods = service_methods(handlers);

deep_equal(methods.status.args, { ubus_rpc_session: '' },
	'status accepts LuCI session argument');
deep_equal(methods.interfaces.args, { ubus_rpc_session: '' },
	'interfaces accepts LuCI session argument');
deep_equal(methods.check.args, { id: '', ubus_rpc_session: '' },
	'check accepts ID and LuCI session argument');
deep_equal(methods.test_email.args,
	{ recipient: '', ubus_rpc_session: '' },
	'test email accepts recipient and LuCI session argument');

for (let name in [ 'status', 'interfaces', 'check', 'test_email' ])
	methods[name].call({ args: { ubus_rpc_session: 'session-only' } });
deep_equal(calls, [
	[ 'status', { ubus_rpc_session: 'session-only' } ],
	[ 'interfaces', { ubus_rpc_session: 'session-only' } ],
	[ 'check', { ubus_rpc_session: 'session-only' } ],
	[ 'test_email', { ubus_rpc_session: 'session-only' } ]
], 'all published handlers remain callable');
