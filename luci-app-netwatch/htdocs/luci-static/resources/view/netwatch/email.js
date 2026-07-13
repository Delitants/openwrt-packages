'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require ui';

const PASSWORD_PLACEHOLDER = '********';

const callTestEmail = rpc.declare({
	object: 'netwatch', method: 'test_email', params: [ 'recipient' ]
});

return view.extend({
	load() {
		return uci.load('netwatch');
	},

	render() {
		const m = new form.Map('netwatch', _('Netwatch email'),
			_('Configure the SMTP server and notification recipients.'));
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

		o = s.option(form.Value, 'username', _('Username'));

		o = s.option(form.Value, 'password', _('Password'),
			_('Leave the placeholder unchanged to keep the stored password.'));
		o.password = true;
		o.rmempty = true;
		o.cfgvalue = function(sectionId) {
			return uci.get('netwatch', sectionId, 'password') ? PASSWORD_PLACEHOLDER : '';
		};
		o.write = function(sectionId, value) {
			if (value !== '' && value !== PASSWORD_PLACEHOLDER)
				uci.set('netwatch', sectionId, 'password', value);
		};
		o.remove = function() {};

		o = s.option(form.Flag, '_clear_password', _('Clear stored password'),
			_('Explicitly remove the stored SMTP password when saving.'));
		o.default = o.disabled;
		o.rmempty = true;
		o.cfgvalue = function() { return '0'; };
		o.write = function(sectionId, value) {
			if (value === '1')
				uci.unset('netwatch', sectionId, 'password');
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
			const button = ev.currentTarget;
			const recipientOption = this.section.children.find(child => child.option === '_test_recipient');
			const recipient = recipientOption ? (recipientOption.formvalue(sectionId) || '') : '';

			button.disabled = true;
			button.classList.add('spinning');

			return m.save()
				.then(() => uci.apply())
				.then(() => callTestEmail(recipient))
				.then(result => {
					if (!result || result.ok !== true)
						throw new Error('test failed');

					ui.addNotification(null, E('p', _('Test email sent successfully.')), 'info');
				})
				.catch(() => {
					ui.addNotification(null, E('p', _('Test email could not be sent. Check the configuration and system log.')), 'error');
				})
				.finally(() => {
					button.classList.remove('spinning');
					button.disabled = false;
				});
		};

		return m.render();
	}
});
