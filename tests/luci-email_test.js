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
			notifications.push({ text: content.text, level });
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
	const E = (tag, attributes, children) => ({
		tag,
		text: children === undefined ? attributes : children
	});
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
		{ text: 'Test email sent successfully.', level: 'info' }
	]);
});

test('matching failed state uses a fixed notification and releases the button', async () => {
	const harness = createHarness({
		statusReplies: [
			{ version: 1, mail_test: { id: 7, state: 'sending', started: 100, completed: null, error: null }, monitors: [] },
			{ version: 1, mail_test: { id: 7, state: 'failed', started: 100, completed: 101, error: 'mail delivery failed' }, monitors: [] }
		]
	});
	const completion = clickTestButton(harness);
	await flushPromises();
	assert.equal(harness.map.button.disabled, true);
	harness.runTimer();
	await completion;
	assert.equal(harness.map.button.disabled, false);
	assert.deepEqual(harness.notifications, [ {
		text: 'Test email could not be sent. Check the configuration and system log.',
		level: 'error'
	} ]);
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
	assert.deepEqual(harness.notifications, [ {
		text: 'Timed out waiting for the test email result. Check the system log.',
		level: 'error'
	} ]);
});

test('secret-bearing RPC failures never reach notifications', async () => {
	const harness = createHarness({
		testEmailReplies: [ new Error('smtp-password=secret-bearing-exception') ]
	});
	await clickTestButton(harness);
	assert.equal(harness.notifications.length, 1);
	assert.deepEqual(harness.notifications[0], {
		text: 'Test email could not be sent. Check the configuration and system log.',
		level: 'error'
	});
	assert.equal(JSON.stringify(harness.notifications).includes('secret-bearing-exception'), false);
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
