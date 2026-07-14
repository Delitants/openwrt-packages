'use strict';
'require view';
'require form';
'require rpc';
'require uci';

const callDHCPLeases = rpc.declare({
	object: 'luci-rpc', method: 'getDHCPLeases', expect: { '': {} }
});

function addLeaseChoice(option, seen, address, hostname) {
	if (typeof(address) !== 'string')
		return;

	const target = address.replace(/\/\d+$/, '');

	if (target === '' || seen[target])
		return;

	seen[target] = true;
	option.value(target, hostname ? '%s (%s)'.format(hostname, target) : target);
}

function addLeaseChoices(option, leaseInfo) {
	const seen = {};
	const ipv4 = Array.isArray(leaseInfo.dhcp_leases) ? leaseInfo.dhcp_leases : [];
	const ipv6 = Array.isArray(leaseInfo.dhcp6_leases) ? leaseInfo.dhcp6_leases : [];

	for (const lease of ipv4)
		addLeaseChoice(option, seen, lease.ipaddr, lease.hostname);

	for (const lease of ipv6) {
		addLeaseChoice(option, seen, lease.ip6addr, lease.hostname);

		if (Array.isArray(lease.ip6addrs))
			for (const address of lease.ip6addrs)
				addLeaseChoice(option, seen, address, lease.hostname);
	}
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('netwatch'),
			L.resolveDefault(callDHCPLeases(), {})
		]);
	},

	render(data) {
		const leaseInfo = data[1] || {};
		const m = new form.Map('netwatch', _('Netwatch monitors'),
			_('Monitor DHCP clients or manually entered IP addresses and host names.'));
		const s = m.section(form.GridSection, 'monitor', _('Monitors'));
		let o;

		s.anonymous = false;
		s.addremove = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add monitor');

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = o.enabled;
		o.rmempty = false;
		o.editable = true;

		o = s.option(form.Value, 'name', _('Name'));
		o.placeholder = _('Optional label');

		o = s.option(form.ListValue, 'type', _('Test'));
		o.value('ping', _('Ping'));
		o.value('tcp', _('TCP port'));
		o.default = 'ping';
		o.rmempty = false;

		o = s.option(form.Value, 'target', _('Host or IP address'),
			_('Select an active DHCP lease or enter a target manually.'));
		o.datatype = 'or(hostname,ipaddr("nomask"))';
		o.rmempty = false;
		addLeaseChoices(o, leaseInfo);

		o = s.option(form.Value, 'interval', _('Check interval'), _('Seconds between checks.'));
		o.datatype = 'range(5,86400)';
		o.default = '60';
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.Value, 'timeout', _('Timeout'), _('Seconds allowed for each test.'));
		o.datatype = 'range(1,60)';
		o.default = '5';
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.Value, 'failures', _('Failures before down'));
		o.datatype = 'range(1,100)';
		o.default = '3';
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.Value, 'packet_count', _('Ping packets'));
		o.datatype = 'range(1,20)';
		o.default = '3';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('type', 'ping');

		o = s.option(form.Flag, 'loss_enabled', _('Check packet loss'));
		o.default = o.disabled;
		o.modalonly = true;
		o.depends('type', 'ping');

		o = s.option(form.Value, 'max_loss', _('Maximum packet loss'), _('Percent.'));
		o.datatype = 'range(0,100)';
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;
		o.depends({ type: 'ping', loss_enabled: '1' });

		o = s.option(form.Flag, 'rtt_enabled', _('Check high delay'));
		o.default = o.disabled;
		o.modalonly = true;
		o.depends('type', 'ping');

		o = s.option(form.Value, 'max_rtt', _('Maximum average delay'), _('Milliseconds.'));
		o.datatype = 'range(1,60000)';
		o.default = '500';
		o.rmempty = false;
		o.modalonly = true;
		o.depends({ type: 'ping', rtt_enabled: '1' });

		o = s.option(form.Value, 'port', _('TCP port'));
		o.datatype = 'range(1,65535)';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('type', 'tcp');

		o = s.option(form.ListValue, 'initial_delay', _('First email'));
		o.value('0', _('Immediately'));
		o.value('300', _('After 5 minutes'));
		o.value('600', _('After 10 minutes'));
		o.value('900', _('After 15 minutes'));
		o.value('1800', _('After 30 minutes'));
		o.value('3600', _('After 1 hour'));
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.ListValue, 'repeat_interval', _('Repeat emails'));
		o.value('0', _('One time'));
		o.value('600', _('Every 10 minutes'));
		o.value('1800', _('Every 30 minutes'));
		o.value('3600', _('Every hour'));
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.Value, 'max_alerts', _('Maximum emails'));
		o.datatype = 'range(1,1000)';
		o.default = '1';
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.Value, 'recipients', _('Recipient override'),
			_('Comma-separated addresses. Leave empty to use the global recipients.'));
		o.modalonly = true;

		o = s.option(form.Flag, 'recovery_email', _('Send recovery email'));
		o.default = o.enabled;
		o.rmempty = false;
		o.modalonly = true;

		return m.render();
	}
});
