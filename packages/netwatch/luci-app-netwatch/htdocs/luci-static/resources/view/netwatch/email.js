'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require ui';

let testEmailInFlight = false;

const callTestEmail = rpc.declare({
	object: 'netwatch', method: 'test_email', params: [ 'recipient' ]
});

const callStatus = rpc.declare({
	object: 'netwatch', method: 'status', expect: { '': {} }
});

const callSetPassword = rpc.declare({
	object: 'netwatch', method: 'set_password', params: [ 'action', 'password' ]
});

function updateStoredPassword(action, password) {
	return L.resolveDefault(callSetPassword(action, password), null).then(result => {
		if (!result || result.ok !== true)
			throw new Error(_('SMTP password could not be updated.'));
	});
}

function delay(milliseconds) {
	return new Promise(resolve => window.setTimeout(resolve, milliseconds));
}

function waitForMailTest(id, deadline) {
	return L.resolveDefault(callStatus(), null).then(status => {
		const test = status && status.mail_test;

		if (test && test.id === id && (test.state === 'sent' || test.state === 'failed'))
			return test.state;
		if (Date.now() >= deadline)
			return 'timeout';

		return delay(1000).then(() => waitForMailTest(id, deadline));
	});
}

function setTestEmailBusy(map, busy) {
	const field = map.findElement('data-name', '_test_email');
	const button = field ? field.querySelector('button') : null;

	if (!button)
		return;

	if (busy) {
		button.disabled = true;
		button.classList.add('spinning');
	}
	else {
		button.classList.remove('spinning');
		button.disabled = false;
	}
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('netwatch'),
			L.resolveDefault(callStatus(), { password_stored: false })
		]);
	},

	render(data) {
		const m = new form.Map('netwatch', _('Netwatch email'),
			_('Configure the SMTP server and notification recipients.'));
		const passwordStored = data && data[1] && data[1].password_stored === true;
		let s, o;

		s = m.section(form.NamedSection, 'main', 'netwatch', _('Notifications'));

		o = s.option(form.Flag, 'enabled', _('Enable Netwatch'));
		o.default = o.enabled;
		o.rmempty = false;

		o = s.option(form.Value, 'startup_grace', _('Startup grace period'), _('Seconds before checks begin after service start.'));
		o.datatype = 'range(0,604800)';
		o.default = '60';
		o.rmempty = false;

		o = s.option(form.Value, 'recipients', _('Global recipients'),
			_('Comma-separated email addresses used unless a monitor overrides them.'));
		o.rmempty = false;

		o = s.option(form.Value, 'mail_retry_backoff', _('Mail retry backoff'), _('Seconds to wait after a failed delivery before trying again.'));
		o.datatype = 'range(1,86400)';
		o.default = '300';
		o.rmempty = false;

		s = m.section(form.NamedSection, 'smtp', 'smtp', _('SMTP server'));

		o = s.option(form.Value, 'server', _('Server'));
		o.datatype = 'host';
		o.rmempty = false;

		o = s.option(form.Value, 'port', _('Port'));
		o.datatype = 'range(1,65535)';
		o.default = '587';
		o.rmempty = false;

		o = s.option(form.ListValue, 'tls', _('TLS mode'));
		o.value('none', _('None'));
		o.value('starttls', _('STARTTLS'));
		o.value('tls', _('TLS from connection start'));
		o.default = 'starttls';
		o.rmempty = false;

		o = s.option(form.Flag, 'tls_insecure',
			_('Disable TLS certificate verification (insecure)'),
			_('This permits man-in-the-middle attacks. Use only when the SMTP certificate cannot be validated through the router trust store.'));
		o.default = o.disabled;
		o.rmempty = true;
		o.depends('tls', 'starttls');
		o.depends('tls', 'tls');

		o = s.option(form.Value, 'username', _('Username'));

		o = s.option(form.Value, 'password', _('Password'), passwordStored
			? _('A password is stored. Leave this field empty to keep it, or enter a replacement.')
			: _('Enter the SMTP password.'));
		o.password = true;
		o.placeholder = passwordStored ? _('Stored password unchanged') : '';
		o.rmempty = true;
		o.cfgvalue = function() { return ''; };
		o.write = function(sectionId, value) {
			const clearOption = this.section.children.find(
				child => child.option === '_clear_password');
			const clearRequested = clearOption &&
				clearOption.formvalue(sectionId) === '1';

			if (value !== '' && !clearRequested)
				return updateStoredPassword('replace', value);
		};
		o.remove = function() {};

		o = s.option(form.Flag, '_clear_password', _('Clear stored password'),
			_('Explicitly remove the stored SMTP password when saving.'));
		o.default = o.disabled;
		o.rmempty = true;
		o.cfgvalue = function() { return '0'; };
		o.write = function(sectionId, value) {
			if (value === '1')
				return updateStoredPassword('clear', '');
		};
		o.remove = function() {};

		o = s.option(form.Value, 'from', _('From address'));
		o.datatype = 'email';
		o.rmempty = false;

		o = s.option(form.Value, 'from_name', _('From name'));

		o = s.option(form.Value, 'ehlo', _('EHLO name'), _('Optional name sent to the SMTP server.'));
		o.datatype = 'hostname';

		o = s.option(form.Value, '_test_recipient', _('Test recipient'),
			_('Optional. Leave empty to use the global recipients.'));
		o.datatype = 'email';
		o.rmempty = true;
		o.cfgvalue = function() { return ''; };
		o.write = function() {};
		o.remove = function() {};

		o = s.option(form.Button, '_test_email', _('Test email'));
		o.inputtitle = _('Save, apply, and send test');
		o.inputstyle = 'apply';
		o.onclick = function(ev, sectionId) {
			if (testEmailInFlight)
				return Promise.resolve();

			const recipientOption = this.section.children.find(child => child.option === '_test_recipient');
			const recipient = recipientOption ? (recipientOption.formvalue(sectionId) || '') : '';

			testEmailInFlight = true;
			setTestEmailBusy(m, true);

			return m.save(null, true)
				.then(() => {
					setTestEmailBusy(m, true);
					return uci.apply();
				})
				.then(() => callTestEmail(recipient))
				.then(result => {
					if (!result || result.ok !== true || !Number.isInteger(result.id))
						throw new Error('test failed');

					return waitForMailTest(result.id, Date.now() + 70000);
				})
				.then(state => {
					if (state === 'sent')
						ui.addNotification(null, E('p', _('Test email sent successfully.')), 'info');
					else if (state === 'failed')
						ui.addNotification(null, E('p', _('Test email could not be sent. Check the configuration and system log.')), 'error');
					else
						ui.addNotification(null, E('p', _('Timed out waiting for the test email result. Check the system log.')), 'error');
				})
				.catch(() => {
					ui.addNotification(null, E('p', _('Test email could not be sent. Check the configuration and system log.')), 'error');
				})
				.finally(() => {
					testEmailInFlight = false;
					setTestEmailBusy(m, false);
				});
		};

		return m.render();
	}
});
