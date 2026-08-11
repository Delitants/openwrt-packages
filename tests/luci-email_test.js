#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const viewPath = path.join(__dirname, '..', 'packages', 'netwatch',
	'luci-app-netwatch', 'htdocs', 'luci-static', 'resources', 'view',
	'netwatch', 'email.js');
const viewSource = fs.readFileSync(viewPath, 'utf8');

function createHarness(options = {}) {
	const events = [];
	const notifications = [];
	const timers = [];
	const writes = [];
	const unsets = [];
	const rpcCalls = [];
	const uciLoads = [];
	const uciGets = [];
	const stored = {
		'smtp.password': options.storedPassword || ''
	};
	const rpcReplies = {
		test_email: options.testEmailReplies || [ { ok: true, id: 7 } ],
		set_password: options.setPasswordReplies || [ { ok: true } ],
		status: options.statusReplies || [ {
			version: 1,
			password_stored: options.passwordStored === true,
			mail_test: { id: 7, state: 'sent', started: 100, completed: 101, error: null },
			monitors: []
		} ]
	};
	let now = options.now || 100;
	let currentMap = null;

	class Option {
		constructor(section, type, name, title, description) {
			this.section = section;
			this.type = type;
			this.option = name;
			this.title = title;
			this.description = description;
			this.choices = [];
			this.dependencies = [];
			this.enabled = '1';
			this.disabled = '0';
		}

		value(value, label) {
			this.choices.push([ value, label ]);
		}

		depends(name, value) {
			this.dependencies.push([ name, value ]);
		}

		formvalue() {
			return this.submittedValue || '';
		}
	}

	class Section {
		constructor(map, type, name) {
			this.map = map;
			this.type = type;
			this.name = name;
			this.children = [];
		}

		option(type, name, title, description) {
			const option = new Option(this, type, name, title, description);
			this.children.push(option);
			return option;
		}
	}

	class Map {
		constructor() {
			this.sections = [];
			this.button = {
				disabled: false,
				classList: {
					classes: new Set(),
					add(name) { this.classes.add(name); },
					remove(name) { this.classes.delete(name); }
				}
			};
			currentMap = this;
		}

		section(type, name) {
			const section = new Section(this, type, name);
			this.sections.push(section);
			return section;
		}

		findElement(attribute, name) {
			if (attribute !== 'data-name' || name !== '_test_email')
				return null;
			return { querySelector: selector => selector === 'button' ? this.button : null };
		}

		save() {
			events.push('save');
			const writes = [];
			for (const section of this.sections)
				for (const option of section.children)
					if (Object.prototype.hasOwnProperty.call(option, 'submittedValue') &&
						typeof option.write === 'function')
						writes.push(option.write(section.name, option.submittedValue));
			return Promise.all(writes);
		}

		render() {
			return this;
		}
	}

	function nextReply(method) {
		const replies = rpcReplies[method];
		const reply = replies.length > 1 ? replies.shift() : replies[0];
		return typeof reply === 'function' ? reply() : reply;
	}

	const rpc = {
		declare(specification) {
			return (...args) => {
				events.push(specification.method);
				rpcCalls.push([ specification.method, ...args ]);
				const reply = nextReply(specification.method);
				return reply instanceof Error ? Promise.reject(reply) : Promise.resolve(reply);
			};
		}
	};
	const uci = {
		load(config) {
			uciLoads.push(config);
			return Promise.resolve(config);
		},
		get(config, section, name) {
			uciGets.push([ config, section, name ]);
			return stored[`${section}.${name}`] || '';
		},
		set(config, section, name, value) {
			writes.push([ config, section, name, value ]);
			stored[`${section}.${name}`] = value;
		},
		unset(config, section, name) {
			unsets.push([ config, section, name ]);
			delete stored[`${section}.${name}`];
		},
		apply() {
			events.push('apply');
			return Promise.resolve();
		}
	};
	const ui = {
		addNotification(title, content, level) {
			notifications.push({ content, level });
		}
	};
	const form = {
		Map,
		NamedSection: Symbol('NamedSection'),
		Flag: Symbol('Flag'),
		Value: Symbol('Value'),
		ListValue: Symbol('ListValue'),
		Button: Symbol('Button')
	};
	const view = { extend: definition => definition };
	const L = {
		resolveDefault(value, fallback) {
			return Promise.resolve(value).catch(() => fallback);
		}
	};
	const window = {
		setTimeout(callback, milliseconds) {
			timers.push({ callback, milliseconds });
			return timers.length;
		}
	};
	const FakeDate = { now: () => now };
	const E = (tag, attributes, children) => {
		if (children === undefined) {
			children = attributes;
			attributes = {};
		}

		return {
			tag,
			attributes: attributes || {},
			children: Array.isArray(children) ? children : [ children ]
		};
	};
	const translate = value => value;

	const definition = new Function(
		'view', 'form', 'rpc', 'uci', 'ui', 'L', 'window', 'Date', 'E', '_',
		viewSource
	)(view, form, rpc, uci, ui, L, window, FakeDate, E, translate);
	definition.render([ 'netwatch', {
		version: 1,
		password_stored: options.passwordStored === true,
		mail_test: null,
		monitors: []
	} ]);

	return {
		definition,
		events,
		notifications,
		timers,
		writes,
		unsets,
		rpcCalls,
		uciLoads,
		uciGets,
		uci,
		map: currentMap,
		option(name) {
			for (const section of currentMap.sections)
				for (const option of section.children)
					if (option.option === name)
						return option;
			return null;
		},
		setNow(value) { now = value; },
		runTimer() {
			assert.ok(timers.length, 'a polling timer is pending');
			const timer = timers.shift();
			assert.equal(timer.milliseconds, 1000, 'polling delay is one second');
			timer.callback();
		}
	};
}

async function flushPromises(rounds = 16) {
	for (let index = 0; index < rounds; index++)
		await Promise.resolve();
}

async function clickTestButton(harness) {
	const buttonOption = harness.option('_test_email');
	assert.ok(buttonOption, 'test email button exists');
	return buttonOption.onclick.call(buttonOption, {}, 'smtp');
}

function textContent(node) {
	if (node == null)
		return '';
	if (typeof node === 'string' || typeof node === 'number')
		return String(node);
	if (Array.isArray(node))
		return node.map(textContent).join('');
	return textContent(node.children);
}

function findElements(node, tag, result = []) {
	if (node && typeof node === 'object' && !Array.isArray(node)) {
		if (node.tag === tag)
			result.push(node);
		findElements(node.children, tag, result);
	}
	else if (Array.isArray(node)) {
		for (const child of node)
			findElements(child, tag, result);
	}

	return result;
}

function validFailure(overrides = {}) {
	return Object.assign({
		stage: 'network',
		summary: 'SMTP network I/O failed.',
		detail: 'connection timed out',
		exit_code: 74,
		exit_name: 'EX_IOERR',
		smtp_status: null
	}, overrides);
}

function failedMailTest(failure) {
	return {
		id: 7,
		state: 'failed',
		started: 100,
		completed: 101,
		error: failure.summary,
		failure
	};
}

function notificationText(notification) {
	return textContent(notification.content);
}

if (!String.prototype.format) {
	Object.defineProperty(String.prototype, 'format', {
		value(...values) {
			let index = 0;
			return this.replace(/%[sd]/g, () => String(values[index++]));
		}
	});
}

const tests = [];
function test(name, callback) {
	tests.push({ name, callback });
}

test('stored password stays out of browser UCI and empty submission preserves it', async () => {
	const harness = createHarness({
		passwordStored: true,
		storedPassword: 'stored-secret-value'
	});
	await harness.definition.load();
	const password = harness.option('password');
	assert.ok(password, 'password option exists');
	assert.equal(password.cfgvalue('smtp'), '');
	assert.equal(password.placeholder, 'Stored password unchanged');
	assert.equal(password.description,
		'A password is stored. Leave this field empty to keep it, or enter a replacement.');
	password.submittedValue = '';
	await harness.map.save();
	assert.deepEqual(harness.writes, []);
	assert.deepEqual(harness.rpcCalls.filter(call => call[0] === 'set_password'), []);
	assert.deepEqual(harness.uciLoads, [ 'netwatch' ]);
	assert.equal(harness.uciLoads.includes('netwatch-secrets'), false);
	assert.equal(harness.uciGets.some(call => call[2] === 'password'), false);
});

test('ordinary save sends a replacement through only the write-only RPC', async () => {
	const harness = createHarness({ passwordStored: true });
	const password = harness.option('password');
	password.submittedValue = 'new-visible-entry';
	await harness.map.save();
	assert.deepEqual(harness.rpcCalls, [
		[ 'set_password', 'replace', 'new-visible-entry' ]
	]);
	assert.deepEqual(harness.writes, []);
	assert.deepEqual(harness.unsets, []);
	assert.equal(password.submittedValue, 'new-visible-entry');
});

test('ordinary save clears through only the write-only RPC', async () => {
	const harness = createHarness({ passwordStored: true });
	const clear = harness.option('_clear_password');
	clear.submittedValue = '1';
	await harness.map.save();
	assert.deepEqual(harness.rpcCalls, [ [ 'set_password', 'clear', '' ] ]);
	assert.deepEqual(harness.writes, []);
	assert.deepEqual(harness.unsets, []);
});

test('explicit clear wins over a simultaneously typed replacement', async () => {
	const harness = createHarness({ passwordStored: true });
	harness.option('password').submittedValue = 'must-not-be-submitted';
	harness.option('_clear_password').submittedValue = '1';
	await harness.map.save();
	assert.deepEqual(harness.rpcCalls, [ [ 'set_password', 'clear', '' ] ]);
});

test('write-only RPC failures expose only a fixed local error', async () => {
	const harness = createHarness({
		setPasswordReplies: [ new Error('secret-bearing-password-backend-error') ]
	});
	const password = harness.option('password');
	password.submittedValue = 'new-visible-entry';
	await assert.rejects(harness.map.save(), error => {
		assert.equal(error.message, 'SMTP password could not be updated.');
		assert.equal(error.message.includes('secret-bearing-password-backend-error'), false);
		return true;
	});
});

test('TLS certificate bypass is default-off and only depends on TLS modes', () => {
	const harness = createHarness();
	const insecure = harness.option('tls_insecure');
	assert.ok(insecure, 'tls_insecure option exists');
	assert.equal(insecure.default, insecure.disabled);
	assert.equal(insecure.rmempty, true);
	assert.deepEqual(insecure.dependencies, [
		[ 'tls', 'starttls' ],
		[ 'tls', 'tls' ]
	]);
});

test('test email stays busy while polling and completes on matching sent state', async () => {
	const harness = createHarness({
		testEmailReplies: [ { ok: true, id: 7 } ],
		statusReplies: [
			{ version: 1, mail_test: { id: 7, state: 'sending', started: 100, completed: null, error: null }, monitors: [] },
			{ version: 1, mail_test: { id: 99, state: 'sent', started: 90, completed: 91, error: null }, monitors: [] },
			{ version: 1, mail_test: { id: 7, state: 'sent', started: 100, completed: 101, error: null }, monitors: [] }
		]
	});
	harness.option('password').submittedValue = 'test-flow-visible-entry';
	const completion = clickTestButton(harness);
	await flushPromises();
	assert.deepEqual(harness.events,
		[ 'save', 'set_password', 'apply', 'test_email', 'status' ]);
	assert.equal(harness.map.button.disabled, true);
	assert.equal(harness.timers.length, 1);
	harness.runTimer();
	await flushPromises();
	assert.equal(harness.map.button.disabled, true);
	assert.equal(harness.notifications.length, 0);
	assert.equal(harness.timers.length, 1);
	harness.runTimer();
	await completion;
	assert.equal(harness.map.button.disabled, false);
	assert.deepEqual(harness.notifications, [
		{
			content: {
				tag: 'p', attributes: {},
				children: [ 'Test email sent successfully.' ]
			},
			level: 'info'
		}
	]);
});

test('a second click is ignored while the first test waits for its matching result', async () => {
	const harness = createHarness({
		statusReplies: [
			{ version: 1, mail_test: { id: 7, state: 'sending', started: 100, completed: null, error: null }, monitors: [] },
			{ version: 1, mail_test: { id: 7, state: 'sent', started: 100, completed: 101, error: null, failure: null }, monitors: [] }
		]
	});
	const first = clickTestButton(harness);
	const second = clickTestButton(harness);

	await second;
	await flushPromises();
	assert.equal(harness.map.button.disabled, true);
	assert.deepEqual(harness.rpcCalls.filter(call => call[0] === 'test_email'),
		[ [ 'test_email', '' ] ]);
	harness.runTimer();
	await first;
	assert.equal(harness.map.button.disabled, false);
	assert.equal(notificationText(harness.notifications[0]), 'Test email sent successfully.');
});

test('matching failed state renders a collapsed six-field disclosure from the terminal object', async () => {
	const failure = validFailure();
	const harness = createHarness({
		statusReplies: [
			{ version: 1, mail_test: { id: 7, state: 'sending', started: 100, completed: null, error: null }, monitors: [] },
			{ version: 1, mail_test: failedMailTest(failure), monitors: [] }
		]
	});
	const completion = clickTestButton(harness);
	await flushPromises();
	assert.equal(harness.map.button.disabled, true);
	harness.runTimer();
	await completion;
	assert.equal(harness.map.button.disabled, false);
	assert.equal(harness.notifications.length, 1);
	const notification = harness.notifications[0];
	assert.equal(notification.level, 'error');
	assert.equal(notification.content.tag, 'div');
	assert.equal(textContent(notification.content.children[0]),
		'Test email failed: SMTP network I/O failed.');

	const details = findElements(notification.content, 'details');
	assert.equal(details.length, 1);
	assert.equal(Object.hasOwn(details[0].attributes, 'open'), false,
		'technical details are collapsed by default');
	assert.deepEqual(findElements(details[0], 'summary').map(textContent),
		[ 'Show technical details' ]);
	assert.deepEqual(findElements(details[0], 'dt').map(textContent),
		[ 'Stage', 'Detail', 'Exit', 'SMTP status', 'Test ID' ]);
	assert.deepEqual(findElements(details[0], 'dd').map(textContent),
		[ 'network', 'connection timed out', 'EX_IOERR (74)', 'Unavailable', '7' ]);
});

test('immediate test_email failure renders the same validated disclosure without polling', async () => {
	const failure = validFailure({
		stage: 'config',
		summary: 'SMTP configuration is invalid.',
		detail: 'account is incomplete',
		exit_code: null,
		exit_name: null,
		smtp_status: 535
	});
	const harness = createHarness({
		testEmailReplies: [ { ok: false, failure } ]
	});

	await clickTestButton(harness);
	assert.deepEqual(harness.events, [ 'save', 'apply', 'test_email' ]);
	assert.equal(harness.map.button.disabled, false);
	assert.equal(harness.notifications.length, 1);
	assert.equal(notificationText(harness.notifications[0]),
		'Test email failed: SMTP configuration is invalid.Show technical detailsStageconfigDetailaccount is incompleteExitUnavailableSMTP status535Test IDUnavailable');
});

test('hostile server text is retained only as text child nodes', async () => {
	const hostileDetail = '<img src=x onerror="password=leaked">';
	const failure = validFailure({ detail: hostileDetail });
	const harness = createHarness({
		statusReplies: [ { version: 1, mail_test: failedMailTest(failure), monitors: [] } ]
	});

	await clickTestButton(harness);
	const notification = harness.notifications[0];
	assert.equal(findElements(notification.content, 'img').length, 0);
	assert.equal(findElements(notification.content, 'dd')[1].children[0], hostileDetail);
});

test('extra or secret-bearing failure properties are never rendered', async () => {
	const failure = validFailure({
		password: 'smtp-password-secret',
		username: 'smtp-user-secret',
		address: 'ops@example.test',
		token: 'rpc-token-secret',
		unexpected: 'untrusted-extra-value'
	});
	const harness = createHarness({
		statusReplies: [ { version: 1, mail_test: failedMailTest(failure), monitors: [] } ]
	});

	await clickTestButton(harness);
	assert.equal(notificationText(harness.notifications[0]),
		'Test email could not be sent. Check the configuration and system log.');
	for (const secret of [ 'smtp-password-secret', 'smtp-user-secret',
		'ops@example.test', 'rpc-token-secret', 'untrusted-extra-value' ])
		assert.equal(notificationText(harness.notifications[0]).includes(secret), false);
});

test('malformed failures retain the fixed local error', async () => {
	const failure = validFailure({ stage: 'invented-stage' });
	const harness = createHarness({
		statusReplies: [ { version: 1, mail_test: failedMailTest(failure), monitors: [] } ]
	});

	await clickTestButton(harness);
	assert.equal(notificationText(harness.notifications[0]),
		'Test email could not be sent. Check the configuration and system log.');
});

test('prototype property names are not accepted as failure stages', async () => {
	for (const stage of [ 'toString', 'constructor', '__proto__' ]) {
		const failure = validFailure({ stage });
		const harness = createHarness({
			statusReplies: [ { version: 1, mail_test: failedMailTest(failure), monitors: [] } ]
		});

		await clickTestButton(harness);
		assert.equal(notificationText(harness.notifications[0]),
			'Test email could not be sent. Check the configuration and system log.', stage);
	}
});

test('failure validator rejects invalid field types, ranges, and exit-name mismatches', async () => {
	const invalidFailures = [
		validFailure({ summary: 7 }),
		validFailure({ detail: false }),
		validFailure({ exit_code: -1 }),
		validFailure({ exit_code: 256 }),
		validFailure({ exit_code: 74.5 }),
		validFailure({ exit_code: '74' }),
		validFailure({ smtp_status: 199 }),
		validFailure({ smtp_status: 600 }),
		validFailure({ smtp_status: 535.5 }),
		validFailure({ smtp_status: '535' }),
		validFailure({ exit_name: 'EX_CONFIG' })
	];

	for (const failure of invalidFailures) {
		const harness = createHarness({
			statusReplies: [ { version: 1, mail_test: failedMailTest(failure), monitors: [] } ]
		});

		await clickTestButton(harness);
		assert.equal(notificationText(harness.notifications[0]),
			'Test email could not be sent. Check the configuration and system log.');
	}
});

test('multibyte UTF-8 boundaries permit only backend-bounded summary and detail values', async () => {
	const summaryAtLimit = 'é'.repeat(96);
	const detailAtLimit = '😀'.repeat(128);
	const validHarness = createHarness({
		statusReplies: [ { version: 1, mail_test: failedMailTest(validFailure({
			summary: summaryAtLimit, detail: detailAtLimit
		})), monitors: [] } ]
	});

	await clickTestButton(validHarness);
	assert.equal(textContent(validHarness.notifications[0].content.children[0]),
		`Test email failed: ${summaryAtLimit}`,
		'96 two-byte characters are exactly 192 UTF-8 bytes');
	assert.equal(findElements(validHarness.notifications[0].content, 'dd')[1].children[0],
		detailAtLimit, '128 four-byte characters are exactly 512 UTF-8 bytes');

	for (const failure of [
		validFailure({ summary: 'é'.repeat(97) }),
		validFailure({ detail: '😀'.repeat(129) })
	]) {
		const harness = createHarness({
			statusReplies: [ { version: 1, mail_test: failedMailTest(failure), monitors: [] } ]
		});

		await clickTestButton(harness);
		assert.equal(notificationText(harness.notifications[0]),
			'Test email could not be sent. Check the configuration and system log.');
	}
});

test('polling has a bounded timeout and reports a fixed timeout notification', async () => {
	const sending = {
		version: 1,
		mail_test: { id: 7, state: 'sending', started: 100, completed: null, error: null },
		monitors: []
	};
	const harness = createHarness({ statusReplies: [ sending ] });
	const completion = clickTestButton(harness);
	await flushPromises();
	assert.equal(harness.map.button.disabled, true);
	harness.setNow(70101);
	harness.runTimer();
	await completion;
	assert.equal(harness.map.button.disabled, false);
	assert.equal(harness.timers.length, 0);
	assert.equal(notificationText(harness.notifications[0]),
		'Timed out waiting for the test email result. Check the system log.');
});

test('secret-bearing RPC failures retain the fixed local error', async () => {
	const harness = createHarness({
		testEmailReplies: [ new Error('smtp-password=secret-bearing-exception') ]
	});
	await clickTestButton(harness);
	assert.equal(harness.notifications.length, 1);
	assert.equal(notificationText(harness.notifications[0]),
		'Test email could not be sent. Check the configuration and system log.');
	assert.equal(JSON.stringify(harness.notifications).includes('secret-bearing-exception'), false);
});

test('status RPC rejection immediately retains the fixed local error', async () => {
	const harness = createHarness({
		statusReplies: [ new Error('smtp-password=status-rpc-secret') ]
	});

	const completion = clickTestButton(harness);
	await flushPromises();
	assert.equal(harness.timers.length, 0,
		'status RPC rejection must not be converted into a polling timeout');
	await completion;
	assert.equal(harness.map.button.disabled, false);
	assert.equal(notificationText(harness.notifications[0]),
		'Test email could not be sent. Check the configuration and system log.');
	assert.equal(JSON.stringify(harness.notifications).includes('status-rpc-secret'), false);
});

(async () => {
	let failures = 0;
	for (const { name, callback } of tests) {
		try {
			await callback();
			console.log(`PASS ${name}`);
		}
		catch (error) {
			failures++;
			console.error(`FAIL ${name}`);
			console.error(error && error.stack ? error.stack : error);
		}
	}
	if (failures)
		process.exitCode = 1;
})();
