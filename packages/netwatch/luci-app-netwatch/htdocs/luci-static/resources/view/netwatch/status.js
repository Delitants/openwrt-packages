'use strict';
'require view';
'require dom';
'require poll';
'require rpc';
'require uci';
'require ui';

const callStatus = rpc.declare({
	object: 'netwatch', method: 'status', expect: { '': {} }
});

const callCheck = rpc.declare({
	object: 'netwatch', method: 'check', params: [ 'id' ]
});

let checksInFlight = Object.create(null);

function hasChecksInFlight() {
	return Object.keys(checksInFlight).length > 0;
}

function configuredText(value, fallback) {
	if (typeof(value) !== 'string' || value === '')
		return fallback;

	return value.replace(/[\x00-\x1f\x7f]/g, ' ').slice(0, 256);
}

function finiteNumber(value, minimum, maximum) {
	return typeof(value) === 'number' && isFinite(value) &&
		value >= minimum && value <= maximum;
}

function reasonLabel(reason, succeeded) {
	if (succeeded === true)
		return _('Succeeded');

	switch (reason) {
	case 'unreachable':
		return _('Host unreachable');
	case 'packet_loss':
		return _('Packet loss too high');
	case 'high_rtt':
		return _('Delay too high');
	case 'ping_failed':
		return _('Ping failed');
	case 'invalid_output':
		return _('Invalid ping response');
	case 'probe_start':
		return _('Could not start test');
	case 'probe_failed':
		return _('Test failed');
	case 'timeout':
		return _('Timed out');
	case 'dns':
		return _('Name lookup failed');
	case 'refused':
		return _('Connection refused');
	case 'connect_failed':
		return _('Connection failed');
	default:
		return _('Test failed');
	}
}

function formatPingResult(result) {
	if (!result || typeof(result) !== 'object')
		return _('No result');

	const parts = [];

	if (finiteNumber(result.loss, 0, 100))
		parts.push(_('%d%% packet loss').format(Math.round(result.loss)));

	if (finiteNumber(result.avg_rtt, 0, 60000))
		parts.push(_('%s ms average RTT').format(result.avg_rtt.toFixed(3)));

	if (result.ok !== true)
		parts.push(reasonLabel(result.reason, false));
	else if (!parts.length)
		parts.push(reasonLabel(null, true));

	return parts.join('; ');
}

function monitorPort(monitor) {
	const port = Number(monitor.port);
	return Number.isInteger(port) && port >= 1 && port <= 65535 ? port : null;
}

function formatTcpResult(monitor, result) {
	const port = monitorPort(monitor);
	const prefix = port == null ? _('TCP') : _('Port %d').format(port);
	const reason = !result || typeof(result) !== 'object'
		? _('No result')
		: reasonLabel(result.reason, result.ok === true);

	return _('%s: %s').format(prefix, reason);
}

function formatResult(monitor, state) {
	const result = state && typeof(state.last_result) === 'object'
		? state.last_result
		: null;

	return monitor.type === 'tcp'
		? formatTcpResult(monitor, result)
		: formatPingResult(result);
}

function formatTest(monitor) {
	if (monitor.type !== 'tcp')
		return _('Ping');

	const port = monitorPort(monitor);
	return port == null ? _('TCP') : _('TCP port %d').format(port);
}

function formatTimestamp(value, emptyLabel) {
	if (!finiteNumber(value, 1, 253402300799))
		return emptyLabel;

	return new Date(value * 1000).toLocaleString();
}

function formatEmails(value) {
	return finiteNumber(value, 0, 1000000) ? String(Math.floor(value)) : '0';
}

function stateBadge(state) {
	let label = _('Unknown');
	let cssClass = 'label';

	if (state && typeof(state.config_error) === 'string' && state.config_error !== '') {
		label = _('Invalid configuration');
		cssClass = 'label warning';
	}
	else {
		switch (state ? state.status : null) {
		case 'healthy':
			label = _('Healthy');
			cssClass = 'label notice';
			break;
		case 'pending':
			label = _('Pending');
			cssClass = 'label warning';
			break;
		case 'failed':
			label = _('Failed');
			cssClass = 'label warning';
			break;
		case 'disabled':
			label = _('Disabled');
			break;
		}
	}

	return E('span', { 'class': cssClass }, label);
}

function configuredMonitors() {
	return uci.sections('netwatch', 'monitor').filter(function(monitor) {
		return typeof(monitor['.name']) === 'string' && monitor['.name'] !== '';
	});
}

function statusRows(status, table, notice) {
	const stateById = Object.create(null);
	const states = status && Array.isArray(status.monitors) ? status.monitors : [];

	for (const state of states) {
		if (state && typeof(state) === 'object' && typeof(state.id) === 'string')
			stateById[state.id] = state;
	}

	return configuredMonitors().map(function(monitor) {
		const id = monitor['.name'];
		const state = stateById[id] || null;
		const isChecking = !!checksInFlight[id];
		const canCheck = state && state.status !== 'disabled' &&
			!(typeof(state.config_error) === 'string' && state.config_error !== '');
		const button = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': handleCheckNow.bind(null, id, table, notice)
		}, _('Check now'));

		button.disabled = !canCheck || isChecking;
		if (isChecking)
			button.classList.add('spinning');

		return [
			E('span', {}, configuredText(monitor.name, id)),
			E('span', {}, configuredText(monitor.target, _('Not configured'))),
			E('span', {}, formatTest(monitor)),
			stateBadge(state),
			E('span', {}, formatTimestamp(state ? state.last_check : null, _('Never'))),
			E('span', {}, formatResult(monitor, state)),
			E('span', {}, formatTimestamp(state ? state.incident_started : null, '-')),
			E('span', {}, formatEmails(state ? state.failure_emails : null)),
			button
		];
	});
}

function showAvailability(notice, available) {
	dom.content(notice, available ? null : E('p', {
		'class': 'alert-message warning'
	}, _('Live status is temporarily unavailable.')));
}

function refreshStatus(table, notice, force) {
	if (!force && hasChecksInFlight())
		return Promise.resolve();

	return L.resolveDefault(callStatus(), null).then(function(status) {
		if (!force && hasChecksInFlight())
			return;

		const available = !!status && Array.isArray(status.monitors);
		showAvailability(notice, available);
		cbi_update_table(table, statusRows(status, table, notice),
			E('em', {}, _('No monitors configured.')));
	});
}

function handleCheckNow(id, table, notice, ev) {
	if (checksInFlight[id])
		return Promise.resolve();

	const button = ev.currentTarget;
	checksInFlight[id] = true;
	button.disabled = true;
	button.classList.add('spinning');
	button.blur();

	return L.resolveDefault(callCheck(id), null)
		.then(function(result) {
			if (!result || result.ok !== true)
				ui.addNotification(null,
					E('p', {}, _('The check could not be started. Check the service and system log.')),
					'error');
		})
		.finally(function() {
			delete checksInFlight[id];
			button.classList.remove('spinning');
			button.disabled = false;
			return refreshStatus(table, notice, true);
		});
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('netwatch'),
			L.resolveDefault(callStatus(), null)
		]);
	},

	render(data) {
		const initialStatus = data[1];
		const notice = E('div');
		const table = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Monitor')),
				E('th', { 'class': 'th' }, _('Target')),
				E('th', { 'class': 'th' }, _('Test')),
				E('th', { 'class': 'th' }, _('State')),
				E('th', { 'class': 'th' }, _('Last check')),
				E('th', { 'class': 'th' }, _('Result')),
				E('th', { 'class': 'th' }, _('Incident')),
				E('th', { 'class': 'th' }, _('Emails')),
				E('th', { 'class': 'th cbi-section-actions' })
			])
		]);

		showAvailability(notice, !!initialStatus && Array.isArray(initialStatus.monitors));
		cbi_update_table(table, statusRows(initialStatus, table, notice),
			E('em', {}, _('No monitors configured.')));

		poll.add(function() {
			return refreshStatus(table, notice, false);
		});

		return E([
			E('h2', {}, _('Netwatch status')),
			notice,
			table
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
