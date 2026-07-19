import { deep_equal, equal, truthy } from 'test';
import {
	parse_interface_selector,
	inventory_from_snapshot,
	collect_interface_snapshot_with,
	collect_interface_inventory_with
} from 'interfaces';

deep_equal(parse_interface_selector('wifi-iface:guest_5g'),
	{ kind: 'wifi-iface', id: 'guest_5g' }, 'selector parsed');
equal(parse_interface_selector('wifi-iface:@wifi-iface[0]'), null,
	'list-position selector rejected');

let snapshot = {
	configured: {
		networks: [
			{ id: 'lan', disabled: false, auto: true, description: 'Local network' },
			{ id: 'wan', disabled: true, auto: false }
		],
		devices: [ { name: 'br-lan', type: 'bridge' } ],
		radios: [
			{ id: 'radio0', disabled: false, band: '5g' },
			{ id: 'radio1', disabled: true, band: '2g' }
		],
		wifi_ifaces: [
			{ id: 'office0', device: 'radio0', mode: 'ap', ssid: 'Office WiFi', disabled: false },
			{ id: 'office1', device: 'radio1', mode: 'ap', ssid: 'Office WiFi', disabled: true },
			{ id: 'client0', device: 'radio0', mode: 'sta', ssid: 'Upstream', disabled: false }
		]
	},
	runtime: {
		interfaces: [
			{ interface: 'lan', up: true, available: true, device: 'br-lan' },
			{ interface: 'dmz', up: false, available: true, device: 'eth9' }
		],
		devices: {
			'br-lan': { up: true, carrier: true, present: true },
			'eth9': { up: false, carrier: false, present: true },
			'phy0-ap0': { up: true, carrier: true, present: true, operstate: 'up' },
			"eth0';reboot": { up: true, carrier: true, present: true }
		},
		wireless: {
			radio0: {
				up: true, pending: false, disabled: false,
				interfaces: [ { section: 'office0', ifname: 'phy0-ap0', config: { mode: 'ap', ssid: 'Office WiFi' } } ]
			}
		},
		sys_devices: [ 'br-lan', 'eth9', 'phy0-ap0', "eth0';reboot" ]
	},
	errors: []
};

let inventory = inventory_from_snapshot(snapshot);
equal(length(inventory.groups), 4, 'four groups returned');
equal(inventory.groups[0].id, 'networks', 'networks first');
truthy(match(sprintf('%J', inventory.groups[0].items), /network:dmz/),
	'live-only logical network included');
equal(inventory.groups[1].items[1].selector, 'device:eth9', 'live-only device included');
equal(inventory.groups[2].items[1].selector, 'wifi-radio:radio1', 'absent disabled radio included');
equal(inventory.groups[3].items[0].label,
	'AP: Office WiFi — radio0 / office0 (phy0-ap0)', 'custom SSID and live device shown');
equal(inventory.groups[3].items[1].label,
	'AP: Office WiFi — radio1 / office1', 'duplicate SSID disambiguated');
equal(length(inventory.groups[3].items), 2, 'non-AP wireless section omitted');
equal(match(sprintf('%J', inventory), /reboot/), null,
	'live names outside the selector grammar are omitted');

let calls = [];
let collected = collect_interface_snapshot_with({
	foreach: (config, section_type, callback) => {
		push(calls, `${config}:${section_type}`);
		if (config == 'wireless' && section_type == 'wifi-iface')
			callback({ '.name': 'secret_ap', device: 'radio0', mode: 'ap', ssid: 'Safe', key: 'do-not-return' });
	},
	call: (object, method) => object == 'network.device' ? {} : null,
	lsdir: (path) => [],
	readfile: (path, limit) => null
});
truthy('wireless:wifi-iface' in calls, 'wireless sections queried');
equal(match(sprintf('%J', collected), /do-not-return/), null, 'secret UCI value excluded');
truthy(length(collected.errors) >= 1, 'source failures normalized');

function candidate(inventory, group_id, selector) {
	for (let group in inventory.groups)
		if (group.id == group_id)
			for (let item in group.items)
				if (item.selector == selector) return item;
	return null;
};

let nested = collect_interface_snapshot_with({
	foreach: (config, section_type, callback) => {
		if (config == 'network' && section_type == 'interface')
			callback({ '.name': 'lan', description: 'Safe', routes: [ { token: 'nested-secret' } ] });
		if (config == 'wireless' && section_type == 'wifi-iface')
			callback({ '.name': 'safe_ap', device: 'radio0', mode: 'ap', ssid: 'Safe',
				network: [ { password: 'nested-secret' } ] });
	},
	call: (object, method) => object == 'network.interface'
		? { interface: [ { interface: 'lan', device: 'br-lan', errors: [ { token: 'nested-secret' } ] } ] }
		: object == 'network.device' ? {} : {},
	lsdir: (path) => [],
	readfile: (path, limit) => null
});
equal(match(sprintf('%J', nested), /nested-secret/), null,
	'nested UCI and ubus secrets omitted');

let unavailable = inventory_from_snapshot({
	configured: {
		networks: [ { id: 'lan', disabled: false, auto: true } ],
		devices: [ { name: 'br-lan', disabled: false } ],
		radios: [ { id: 'radio0', disabled: false } ],
		wifi_ifaces: [ { id: 'main_ap', device: 'radio0', mode: 'ap', disabled: false } ]
	},
	runtime: { interfaces: [], devices: {}, wireless: {}, sys_devices: [] },
	sources: {
		logical_runtime: false, device_runtime: false, wireless_runtime: false, sysfs_devices: false
	},
	errors: []
});
equal(candidate(unavailable, 'networks', 'network:lan').present, null,
	'network presence unknown when runtime source fails');
equal(candidate(unavailable, 'networks', 'network:lan').state, null,
	'network state unknown when runtime source fails');
equal(candidate(unavailable, 'devices', 'device:br-lan').present, null,
	'device presence unknown when both device sources fail');
equal(candidate(unavailable, 'devices', 'device:br-lan').state, null,
	'device state unknown when both device sources fail');
equal(candidate(unavailable, 'wifi-radios', 'wifi-radio:radio0').present, null,
	'radio presence unknown when wireless source fails');
equal(candidate(unavailable, 'wifi-aps', 'wifi-iface:main_ap').state, null,
	'AP state unknown when wireless source fails');

let union = inventory_from_snapshot({
	configured: {
		networks: [],
		devices: [ { name: 'br-lan' }, { name: 'br-lan' } ],
		radios: [], wifi_ifaces: []
	},
	runtime: { interfaces: [], devices: { eth9: { up: true, present: true } }, wireless: {}, sys_devices: [] },
	sources: { logical_runtime: true, device_runtime: true, wireless_runtime: true, sysfs_devices: false },
	errors: []
});
equal(length(union.groups[1].items), 2, 'configured duplicate device selector deduplicated');
equal(candidate(union, 'devices', 'device:eth9').present, true,
	'live device status key included when sysfs fails');
equal(candidate(union, 'devices', 'device:eth9').enabled, null,
	'live-only device enabled state unknown');

let disabled_parent = inventory_from_snapshot({
	configured: {
		networks: [], devices: [],
		radios: [ { id: 'radio0', disabled: true } ],
		wifi_ifaces: [ { id: 'guest_ap', device: 'radio0', mode: 'ap', disabled: false } ]
	},
	runtime: { interfaces: [], devices: {}, wireless: {}, sys_devices: [] },
	sources: { logical_runtime: true, device_runtime: true, wireless_runtime: false, sysfs_devices: true },
	errors: []
});
equal(candidate(disabled_parent, 'wifi-aps', 'wifi-iface:guest_ap').enabled, false,
	'configured-disabled parent radio disables AP');
equal(candidate(disabled_parent, 'wifi-aps', 'wifi-iface:guest_ap').state, 'disabled',
	'configured-disabled parent radio gives known disabled AP state');

let partial = collect_interface_snapshot_with({
	foreach: (config, section_type, callback) => {
		if (config == 'network' && section_type == 'interface') callback({ '.name': 'lan' });
		if (config == 'network' && section_type == 'device') callback({ name: 'br-lan' });
	},
	call: (object, method) => object == 'network.device' ? { eth9: { up: true } } : null,
	lsdir: (path) => [ 'br-lan' ],
	readfile: (path, limit) => null
});
equal(partial.sources.logical_runtime, false, 'logical runtime outage recorded');
equal(partial.sources.device_runtime, true, 'device runtime remains available');
equal(partial.sources.sysfs_devices, true, 'sysfs remains available');
equal(length(partial.configured.networks), 1, 'UCI data retained through ubus outage');
truthy('eth9' in partial.runtime.devices, 'device status retained through logical outage');
truthy('br-lan' in partial.runtime.sys_devices, 'sysfs data retained through ubus outage');

let ubus_outage = collect_interface_inventory_with({
	cursor: () => ({
		foreach: (config, section_type, callback) => {
			if (config == 'network' && section_type == 'interface') callback({ '.name': 'lan' });
		}
	}),
	connect: () => null,
	lsdir: (path) => [ 'br-lan' ],
	readfile: (path, limit) => null
});
truthy(candidate(ubus_outage, 'networks', 'network:lan'),
	'configured network retained when connection construction fails');
truthy(candidate(ubus_outage, 'devices', 'device:br-lan'),
	'sysfs device retained when connection construction fails');
truthy('ubus unavailable' in ubus_outage.errors, 'connection construction failure reported');

let uci_outage = collect_interface_inventory_with({
	cursor: () => die('unavailable'),
	connect: () => ({ call: (object, method, args) => object == 'network.device' ? { eth9: { up: true } } : null }),
	lsdir: (path) => [],
	readfile: (path, limit) => null
});
truthy(candidate(uci_outage, 'devices', 'device:eth9'),
	'live device retained when cursor construction fails');
truthy('uci unavailable' in uci_outage.errors, 'cursor construction failure reported');

let ap_radio_down = inventory_from_snapshot({
	configured: {
		networks: [], devices: [],
		radios: [ { id: 'radio0', disabled: false } ],
		wifi_ifaces: [ { id: 'main_ap', device: 'radio0', mode: 'ap', disabled: false } ]
	},
	runtime: {
		interfaces: [], devices: {}, sys_devices: [],
		wireless: { radio0: { up: false, disabled: false, interfaces: [ { section: 'main_ap', ifname: 'phy0-ap0' } ] } }
	},
	sources: { logical_runtime: true, device_runtime: true, wireless_runtime: true, sysfs_devices: true },
	errors: []
});
equal(candidate(ap_radio_down, 'wifi-aps', 'wifi-iface:main_ap').state, 'down',
	'matching AP follows explicit down radio state');

let ap_radio_unknown = inventory_from_snapshot({
	configured: {
		networks: [], devices: [],
		radios: [ { id: 'radio0', disabled: false } ],
		wifi_ifaces: [ { id: 'main_ap', device: 'radio0', mode: 'ap', disabled: false } ]
	},
	runtime: {
		interfaces: [], devices: {}, sys_devices: [],
		wireless: { radio0: { disabled: false, interfaces: [ { section: 'main_ap', ifname: 'phy0-ap0' } ] } }
	},
	sources: { logical_runtime: true, device_runtime: true, wireless_runtime: true, sysfs_devices: true },
	errors: []
});
equal(candidate(ap_radio_unknown, 'wifi-aps', 'wifi-iface:main_ap').state, null,
	'matching AP without radio state remains unknown');

let device_presence_unknown = inventory_from_snapshot({
	configured: { networks: [], devices: [], radios: [], wifi_ifaces: [] },
	runtime: { interfaces: [], devices: { eth9: { up: false } }, wireless: {}, sys_devices: [] },
	sources: { logical_runtime: true, device_runtime: true, wireless_runtime: true, sysfs_devices: false },
	errors: []
});
equal(candidate(device_presence_unknown, 'devices', 'device:eth9').present, null,
	'device status without presence remains unknown while sysfs is unavailable');

let device_absent = inventory_from_snapshot({
	configured: { networks: [], devices: [], radios: [], wifi_ifaces: [] },
	runtime: { interfaces: [], devices: { eth9: { present: false, up: false } }, wireless: {}, sys_devices: [] },
	sources: { logical_runtime: true, device_runtime: true, wireless_runtime: true, sysfs_devices: false },
	errors: []
});
equal(candidate(device_absent, 'devices', 'device:eth9').state, 'absent',
	'explicit absent device takes precedence over down state');
