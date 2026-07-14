'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require poll';

var callStatus = rpc.declare({ object: 'scheduled-backup', method: 'status' });
var callRun = rpc.declare({ object: 'scheduled-backup', method: 'run' });
var callTestSftp = rpc.declare({ object: 'scheduled-backup', method: 'test_sftp' });
var callTrustHost = rpc.declare({ object: 'scheduled-backup', method: 'trust_host', params: [ 'fingerprint' ] });
var callSetPassword = rpc.declare({ object: 'scheduled-backup', method: 'set_password', params: [ 'password' ] });
var callClearPassword = rpc.declare({ object: 'scheduled-backup', method: 'clear_password' });
var callSetKey = rpc.declare({ object: 'scheduled-backup', method: 'set_key', params: [ 'key' ] });
var callClearKey = rpc.declare({ object: 'scheduled-backup', method: 'clear_key' });

function notify(result, success) {
	if (result && result.ok === false)
		throw new Error(result.error || _('Operation failed'));
	ui.addNotification(null, E('p', {}, success), 'info');
	return result;
}

function reportError(error) {
	ui.addNotification(null, E('p', {}, error.message || String(error)), 'error');
}

function confirmAction(title, message, label, action) {
	ui.showModal(title, [
		E('p', {}, message),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
			E('button', {
				'class': 'btn cbi-button-action important',
				'click': function() {
					ui.hideModal();
					Promise.resolve(action()).catch(reportError);
				}
			}, label)
		])
	]);
}

function actionButton(label, css, handler) {
	return E('button', {
		'class': 'btn cbi-button ' + css,
		'click': handler
	}, label);
}

function absolute(sectionId, value) {
	return !value || value.charAt(0) === '/' ? true : _('Path must be absolute');
}

function nonnegative(sectionId, value) {
	return /^\d+$/.test(value || '') ? true : _('Must be a nonnegative integer');
}

function requiredWhen(option, expected, message) {
	return function(sectionId, value) {
		var peer = this.map.lookupOption(option, sectionId)[0];
		var enabled = peer ? peer.formvalue(sectionId) : null;
		return enabled !== expected || String(value || '').trim() ? true : message;
	};
}

function validateDestination(sectionId, value) {
	if (value !== '1')
		return true;
	var localOption = this.map.lookupOption('local_enabled', sectionId)[0];
	var sftpOption = this.map.lookupOption('sftp_enabled', sectionId)[0];
	var local = localOption && localOption.formvalue(sectionId);
	var sftp = sftpOption && sftpOption.formvalue(sectionId);
	return local === '1' || sftp === '1' ? true : _('Enable at least one destination');
}

function statusRow(label, value) {
	return E('tr', {}, [ E('th', {}, label), E('td', {}, value || _('Not available')) ]);
}

function renderStatus(node, status) {
	status = status || {};
	var size = status.size && /^\d+$/.test(status.size) ? '%1024.2mB'.format(+status.size) : status.size;
	var table = E('table', { 'class': 'table' }, [
		statusRow(_('State'), status.state),
		statusRow(_('Started'), status.started),
		statusRow(_('Finished'), status.finished),
		statusRow(_('Archive'), status.filename),
		statusRow(_('Archive size'), size),
		statusRow(_('Local destination'), [ status.local_result, status.local_message ].filter(Boolean).join(': ')),
		statusRow(_('SFTP destination'), [ status.sftp_result, status.sftp_message ].filter(Boolean).join(': ')),
		statusRow(_('Summary'), status.summary)
	]);
	node.replaceChildren(table);
}

return view.extend({
	load: function() {
		return Promise.all([ uci.load('scheduled-backup'), callStatus() ]);
	},

	render: function(data) {
		var m = new form.Map('scheduled-backup', _('Scheduled Backup'),
			_('Create OpenWrt-compatible configuration backups on a friendly schedule.'));
		var s, o, statusNode, statusPoll;
		var startStatusPolling = function() {
			if (statusPoll)
				return;
			statusPoll = function() {
				return callStatus().then(function(status) {
					if (statusNode)
						renderStatus(statusNode, status);
					if (status.state !== 'running') {
						poll.remove(statusPoll);
						statusPoll = null;
					}
				});
			};
			poll.add(statusPoll, 5);
		};

		s = m.section(form.NamedSection, 'main', 'scheduled_backup', _('General'));
		s.addremove = false;
		o = s.option(form.Flag, 'enabled', _('Enable scheduled backups'));
		o.rmempty = false;
		o.validate = validateDestination;

		s = m.section(form.NamedSection, 'main', 'scheduled_backup', _('Schedule'));
		s.addremove = false;
		o = s.option(form.ListValue, 'schedule_mode', _('Frequency'));
		o.value('daily', _('Daily'));
		o.value('weekly', _('Weekly'));
		o.rmempty = false;
		o = s.option(form.ListValue, 'weekday', _('Weekday'));
	[ _('Sunday'), _('Monday'), _('Tuesday'), _('Wednesday'), _('Thursday'), _('Friday'), _('Saturday') ]
		.forEach(function(day, index) { o.value(String(index), day); });
		o.depends('schedule_mode', 'weekly');
		o = s.option(form.Value, 'hour', _('Hour'));
		o.datatype = 'range(0,23)';
		o.rmempty = false;
		o = s.option(form.Value, 'minute', _('Minute'));
		o.datatype = 'range(0,59)';
		o.rmempty = false;

		s = m.section(form.NamedSection, 'main', 'scheduled_backup', _('Local Storage'));
		s.addremove = false;
		o = s.option(form.Flag, 'local_enabled', _('Enable local storage'));
		o.rmempty = false;
		o = s.option(form.Value, 'local_path', _('Directory'));
		o.depends('local_enabled', '1');
		o.validate = function(sectionId, value) {
			return requiredWhen('local_enabled', '1', _('Local directory is required')).call(this, sectionId, value) === true
				? absolute(sectionId, value) : _('Local directory is required');
		};
		o = s.option(form.Value, 'local_keep', _('Backups to keep'));
		o.description = _('Use 0 for unlimited retention.');
		o.datatype = 'uinteger';
		o.validate = nonnegative;
		o.depends('local_enabled', '1');

		s = m.section(form.NamedSection, 'main', 'scheduled_backup', _('SFTP'));
		s.addremove = false;
		o = s.option(form.Flag, 'sftp_enabled', _('Enable SFTP'));
		o.rmempty = false;
		o = s.option(form.Value, 'sftp_host', _('Host'));
		o.validate = requiredWhen('sftp_enabled', '1', _('SFTP host is required'));
		o.depends('sftp_enabled', '1');
		o = s.option(form.Value, 'sftp_port', _('Port'));
		o.datatype = 'range(1,65535)';
		o.rmempty = false;
		o.depends('sftp_enabled', '1');
		o = s.option(form.Value, 'sftp_user', _('Username'));
		o.validate = requiredWhen('sftp_enabled', '1', _('SFTP username is required'));
		o.depends('sftp_enabled', '1');
		o = s.option(form.Value, 'sftp_path', _('Remote directory'));
		o.validate = function(sectionId, value) {
			return requiredWhen('sftp_enabled', '1', _('Remote directory is required')).call(this, sectionId, value) === true
				? absolute(sectionId, value) : _('Remote directory is required');
		};
		o.depends('sftp_enabled', '1');
		o = s.option(form.ListValue, 'sftp_auth', _('Authentication'));
		o.value('password', _('Password'));
		o.value('key', _('Private key'));
		o.depends('sftp_enabled', '1');
		o = s.option(form.Value, 'sftp_keep', _('Backups to keep'));
		o.description = _('Use 0 for unlimited retention.');
		o.datatype = 'uinteger';
		o.validate = nonnegative;
		o.depends('sftp_enabled', '1');
		o = s.option(form.Value, 'connect_timeout', _('Connection timeout (seconds)'));
		o.datatype = 'range(1,2147483647)';
		o.depends('sftp_enabled', '1');
		o = s.option(form.Value, 'transfer_timeout', _('Transfer timeout (seconds)'));
		o.datatype = 'range(1,2147483647)';
		o.depends('sftp_enabled', '1');

		s = m.section(form.NamedSection, 'main', 'scheduled_backup', _('Credentials'));
		s.addremove = false;
		o = s.option(form.Value, '_password', _('Password (write-only)'));
		o.password = true;
		o.rmempty = true;
		o.placeholder = _('Leave blank to preserve the stored password');
		o.depends({ sftp_enabled: '1', sftp_auth: 'password' });
		o.cfgvalue = function() { return ''; };
		o.write = function(sectionId, value) {
		if (!value) return Promise.resolve();
		return callSetPassword(value).then(function(result) {
			document.querySelectorAll('input[name="cbid.scheduled-backup.main._password"]').forEach(function(input) { input.value = ''; });
			return notify(result, _('Password saved'));
		});
	};
		o = s.option(form.TextValue, '_private_key', _('Private key (write-only)'));
		o.rows = 5;
		o.rmempty = true;
		o.placeholder = _('Leave blank to preserve the stored private key');
		o.depends({ sftp_enabled: '1', sftp_auth: 'key' });
		o.cfgvalue = function() { return ''; };
		o.write = function(sectionId, value) {
		if (!value) return Promise.resolve();
		return callSetKey(value).then(function(result) {
			document.querySelectorAll('textarea[name="cbid.scheduled-backup.main._private_key"]').forEach(function(input) { input.value = ''; });
			return notify(result, _('Private key saved'));
		});
	};
		o = s.option(form.DummyValue, '_clear_password');
		o.depends({ sftp_enabled: '1', sftp_auth: 'password' });
		o.renderWidget = function() {
			return actionButton(_('Clear Password'), 'cbi-button-negative', function() {
				confirmAction(_('Clear Password'), _('Remove the stored SFTP password?'), _('Clear'), function() {
					return callClearPassword().then(function(r) { return notify(r, _('Password cleared')); });
				});
			});
		};
		o = s.option(form.DummyValue, '_clear_private_key');
		o.depends({ sftp_enabled: '1', sftp_auth: 'key' });
		o.renderWidget = function() {
			return actionButton(_('Clear Private Key'), 'cbi-button-negative', function() {
				confirmAction(_('Clear Private Key'), _('Remove the stored SFTP private key?'), _('Clear'), function() {
					return callClearKey().then(function(r) { return notify(r, _('Private key cleared')); });
				});
			});
		};

		s = m.section(form.NamedSection, 'main', 'scheduled_backup', _('Operations'));
		s.addremove = false;
		o = s.option(form.DummyValue, '_operations');
		o.renderWidget = function() {
		return E('div', {}, [
			actionButton(_('Run Now'), 'cbi-button-action', function() {
				confirmAction(_('Run Now'), _('Start a backup with the current applied configuration?'), _('Run Now'), function() {
					startStatusPolling();
					return callRun().then(function(r) { return notify(r, _('Backup started')); });
				});
			}), ' ',
			actionButton(_('Test SFTP'), 'cbi-button-action', function() {
				callTestSftp().then(function(result) {
					if (result.ok === false) throw new Error(result.error || _('SFTP test failed'));
					if (result.result === 'verified') {
						ui.showModal(_('SFTP Test'), [ E('p', {}, _('SFTP authentication and remote path verified.')),
							E('div', { 'class': 'right' }, [ actionButton(_('Close'), '', ui.hideModal) ]) ]);
						return;
					}
					var fingerprints = result.fingerprints || '';
					ui.showModal(_('SFTP Test'), [ E('p', {}, _('Server fingerprints:')), E('pre', {}, fingerprints),
						E('div', { 'class': 'right' }, [ actionButton(_('Close'), '', ui.hideModal), ' ',
							actionButton(_('Trust Host'), 'cbi-button-action important', function() {
								var fingerprint = fingerprints.split(/\s+/).filter(function(v) { return /^SHA256:/.test(v); })[0];
								if (!fingerprint) return reportError(new Error(_('No host fingerprint was returned')));
								ui.hideModal();
								confirmAction(_('Trust Host'), _('Trust host fingerprint %s?').format(fingerprint), _('Trust Host'), function() {
									return callTrustHost(fingerprint).then(function(r) { return notify(r, _('Host trusted')); });
								});
							}) ]) ]);
				}).catch(reportError);
			})
		]);
	};

		s = m.section(form.NamedSection, 'main', 'scheduled_backup', _('Status'));
		s.addremove = false;
		o = s.option(form.DummyValue, '_status');
		o.renderWidget = function() {
		statusNode = E('div', { 'id': 'scheduled-backup-status' });
		renderStatus(statusNode, data[1]);
		if (data[1] && data[1].state === 'running')
			startStatusPolling();
		return statusNode;
	};

		return m.render();
	}
});
