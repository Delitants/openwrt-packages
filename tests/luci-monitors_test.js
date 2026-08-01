#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const viewPath = path.join(__dirname, '..', 'packages', 'netwatch',
	'luci-app-netwatch', 'htdocs', 'luci-static', 'resources', 'view',
	'netwatch', 'monitors.js');
const viewSource = fs.readFileSync(viewPath, 'utf8');

String.prototype.format = function(...values) {
	let index = 0;
	return this.replace(/%s/g, () => String(values[index++]));
};

function createHarness() {
	let currentMap = null;
	const monitors = {
		Test3: {
			type: 'interface',
			target: '',
			interface_selector: 'wifi-iface:default_radio1'
		},
		ping: {
			type: 'ping',
			target: '192.168.4.108',
			interface_selector: ''
		},
		missing: {
			type: 'interface',
			target: '',
			interface_selector: 'wifi-iface:gone'
		}
	};

	class Option {
		constructor(section, type, name, title, description) {
			this.section = section;
			this.type = type;
			this.option = name;
			this.title = title;
			this.description = description;
			this.choices = [];
		}

		value(value, label) {
			this.choices.push([ value, label ]);
		}

		depends() {}
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
			currentMap = this;
		}

		section(type, name) {
			const section = new Section(this, type, name);
			this.sections.push(section);
			return section;
		}

		render() {
			return this;
		}
	}

	const DummyValue = Symbol('DummyValue');
	const form = {
		Map,
		GridSection: Symbol('GridSection'),
		Flag: Symbol('Flag'),
		Value: Symbol('Value'),
		ListValue: {
			extend(definition) {
				return definition;
			}
		},
		DummyValue
	};
	const uci = {
		load(config) {
			return Promise.resolve(config);
		},
		sections(config, type) {
			assert.equal(config, 'netwatch');
			assert.equal(type, 'monitor');
			return Object.values(monitors);
		},
		get(config, section, option) {
			assert.equal(config, 'netwatch');
			return monitors[section][option] || '';
		}
	};
	const rpc = {
		declare(specification) {
			if (specification.method === 'getDHCPLeases')
				return () => Promise.resolve({ dhcp_leases: [], dhcp6_leases: [] });
			if (specification.method === 'interfaces')
				return () => Promise.resolve({ groups: [ {
					id: 'wifi-aps', items: [ {
						selector: 'wifi-iface:default_radio1',
						label: 'AP: Helium+🎈 — radio1 / default_radio1',
						state: 'disabled'
					} ]
				} ], errors: [] });
			throw new Error(`unexpected RPC method: ${specification.method}`);
		}
	};
	const view = { extend: definition => definition };
	const L = { resolveDefault: (value, fallback) => Promise.resolve(value).catch(() => fallback) };
	const translate = value => value;

	const definition = new Function('view', 'form', 'rpc', 'uci', 'L', '_', viewSource)(
		view, form, rpc, uci, L, translate);

	return {
		definition,
		DummyValue,
		map() { return currentMap; },
		option(name) {
			for (const section of currentMap.sections)
				for (const option of section.children)
					if (option.option === name)
						return option;
			return null;
		}
	};
}

(async () => {
	const harness = createHarness();
	const data = await harness.definition.load();
	harness.definition.render(data);

	const target = harness.option('target');
	assert.ok(target, 'editable host target exists');
	assert.equal(target.modalonly, true,
		'grid target must not expose the empty saved target of interface monitors');

	const display = harness.option('_display_target');
	assert.ok(display, 'grid has a display-only target column');
	assert.equal(display.type, harness.DummyValue, 'target display uses LuCI DummyValue');
	assert.equal(display.title, 'Target');
	assert.equal(display.write, null, 'display-only target does not write UCI');
	assert.equal(display.remove, null, 'display-only target does not remove UCI');
	assert.equal(display.textvalue('Test3'),
		'AP: Helium+🎈 — radio1 / default_radio1 (disabled)');
	assert.equal(display.textvalue('ping'), '192.168.4.108');
	assert.equal(display.textvalue('missing'), 'Missing: wifi-iface:gone');
})().catch(error => {
	console.error(error && error.stack ? error.stack : error);
	process.exitCode = 1;
});
