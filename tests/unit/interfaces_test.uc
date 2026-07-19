import { deep_equal, equal, truthy } from 'test';
import {
	parse_interface_selector,
	inventory_from_snapshot,
	collect_interface_snapshot_with
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
