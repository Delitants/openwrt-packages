export function service_methods(handlers) {
	return {
		status: {
			args: { ubus_rpc_session: '' }, call: handlers.status
		},
		interfaces: {
			args: { ubus_rpc_session: '' }, call: handlers.interfaces
		},
		check: {
			args: { id: '', ubus_rpc_session: '' }, call: handlers.check
		},
		test_email: {
			args: { recipient: '', ubus_rpc_session: '' }, call: handlers.test_email
		}
	};
};
