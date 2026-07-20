import { equal, truthy } from 'test';
import { evaluate_interface, run_interface_with } from 'interface_probe';

function result(selector, snapshot) {
	return evaluate_interface(selector, snapshot, 1700000000);
};

let base = {
	configured: {
		networks: [ { id: 'wan', disabled: false, auto: true } ],
		devices: [ { name: 'eth0', disabled: false } ],
		radios: [ { id: 'radio0', disabled: false } ],
		wifi_ifaces: [ { id: 'office', device: 'radio0', mode: 'ap', ssid: 'Office', disabled: false } ]
	},
	runtime: {
		interfaces: [ { interface: 'wan', up: true, available: true, device: 'eth0' } ],
		devices: {
			eth0: { present: true, up: true, carrier: true, operstate: 'up' },
			'phy0-ap0': { present: true, up: true, carrier: true, operstate: 'up' }
		},
		wireless: { radio0: { up: true, pending: false, disabled: false,
			retry_setup_failed: false,
			interfaces: [ { section: 'office', ifname: 'phy0-ap0', config: { mode: 'ap', ssid: 'Office' } } ] } },
		sys_devices: [ 'eth0', 'phy0-ap0' ]
	},
	sources: {
		network_interfaces: true, network_devices: true,
		wireless_radios: true, wireless_aps: true,
		logical_runtime: true, device_runtime: true,
		wireless_runtime: true, sysfs_devices: true
	},
	errors: []
};

truthy(result('network:wan', base).ok, 'logical network healthy');
truthy(result('device:eth0', base).ok, 'Linux device healthy');
truthy(result('wifi-radio:radio0', base).ok, 'radio healthy');
truthy(result('wifi-iface:office', base).ok, 'AP healthy');

equal(result('network:wan', { ...base, configured: { ...base.configured,
	networks: [ { id: 'wan', disabled: true, auto: false } ] },
	sources: { ...base.sources, logical_runtime: false } }).reason,
	'administratively_disabled', 'administrative state has precedence');
equal(result('network:missing', base).reason, 'interface_absent',
	'missing logical interface');
equal(result('network:wan', { ...base, runtime: { ...base.runtime,
	interfaces: [ { interface: 'wan', up: false, available: false } ] } }).reason,
	'unavailable', 'logical network unavailable');
equal(result('device:eth0', { ...base, runtime: { ...base.runtime,
	devices: { eth0: { present: true, up: false, carrier: false, operstate: 'down' } } } }).reason,
	'link_down', 'device link down takes precedence over carrier loss');
equal(result('device:eth0', { ...base, runtime: { ...base.runtime,
	devices: { eth0: { present: true, up: true, carrier: false, operstate: 'up' } } } }).reason,
	'carrier_lost', 'carrier loss detected');
equal(result('device:eth0', { ...base, runtime: { ...base.runtime,
	devices: { eth0: { present: true, up: true, carrier: true, operstate: 'dormant' } } } }).reason,
	'link_down', 'dormant device is not operationally up');
equal(result('wifi-radio:radio0', { ...base, runtime: { ...base.runtime,
	wireless: { radio0: { up: false, pending: false, disabled: false,
		retry_setup_failed: false, interfaces: [] } } } }).reason,
	'wireless_radio_down', 'radio down detected');
equal(result('wifi-iface:office', { ...base, runtime: { ...base.runtime,
	wireless: { radio0: { up: true, pending: false, disabled: false,
		retry_setup_failed: false, interfaces: [] } } } }).reason,
	'wireless_ap_down', 'AP down detected');
equal(result('wifi-iface:office', { ...base, runtime: { ...base.runtime,
	devices: { ...base.runtime.devices,
		'phy0-ap0': { present: true, up: true, carrier: true, operstate: 'testing' } } } }).reason,
	'wireless_ap_down', 'testing AP device is not operationally up');
equal(result('wifi-radio:radio0', { ...base, runtime: { ...base.runtime,
	wireless: { radio0: { up: false, pending: false, disabled: false,
		retry_setup_failed: true, interfaces: [] } } } }).reason,
	'wireless_initialization_failed', 'wireless initialization failure precedes down');
equal(result('device:eth0', { ...base, runtime: { ...base.runtime,
	devices: {}, sys_devices: [] }, sources: { ...base.sources,
		device_runtime: false, sysfs_devices: false } }).reason,
	'status_unavailable', 'indeterminate source failure is not absence');
equal(result('device:eth0', { ...base, sources: { ...base.sources,
	device_runtime: false, sysfs_devices: false } }).reason,
	'status_unavailable', 'partial device data from failed sources is not trusted');
equal(result('device:eth0', { ...base, runtime: { ...base.runtime,
	devices: { eth0: { present: true, up: true, carrier: true, operstate: 'up' } },
	sys_devices: [] }, sources: { ...base.sources, device_runtime: false } }).reason,
	'interface_absent', 'failed device runtime cannot override confirmed sysfs absence');
equal(result('device:eth0', { ...base, runtime: { ...base.runtime,
	devices: { eth0: { present: true, up: false, carrier: true, operstate: 'up' } } } }).reason,
	'status_unavailable', 'contradictory Linux up state is indeterminate');

equal(result('network:wan', { ...base,
	sources: { ...base.sources, logical_runtime: false } }).reason,
	'status_unavailable', 'failed logical source cannot invent network health');
equal(result('network:wan', { ...base, runtime: { ...base.runtime,
	interfaces: [ { interface: 'wan', up: false } ] } }).reason,
	'status_unavailable', 'malformed logical availability cannot become link down');
equal(result('wifi-radio:radio0', { ...base,
	sources: { ...base.sources, wireless_runtime: false } }).reason,
	'status_unavailable', 'failed wireless source cannot invent radio health');
equal(result('wifi-radio:radio0', { ...base,
	sources: { ...base.sources, wireless_radios: false } }).reason,
	'status_unavailable', 'failed radio configuration source cannot invent health');
equal(result('wifi-radio:radio0', { ...base, runtime: { ...base.runtime,
	wireless: { radio0: { pending: false, disabled: false,
		retry_setup_failed: false, interfaces: [] } } } }).reason,
	'status_unavailable', 'missing required radio state is indeterminate');
equal(result('wifi-radio:radio0', { ...base, configured: { ...base.configured,
	radios: [] }, runtime: { ...base.runtime,
	wireless: { radio0: { up: false, pending: false, disabled: false,
		retry_setup_failed: true, interfaces: [] } } } }).reason,
	'wireless_initialization_failed', 'radio initialization failure precedes missing configuration');
equal(result('wifi-iface:office', { ...base, runtime: { ...base.runtime,
	wireless: { radio0: { up: false, pending: false, disabled: false,
		retry_setup_failed: true, interfaces: [] } } } }).reason,
	'wireless_initialization_failed', 'AP initialization failure precedes missing BSS');
equal(result('wifi-iface:office', { ...base, configured: { ...base.configured,
	radios: [] }, runtime: { ...base.runtime,
	wireless: { radio0: { up: false, pending: false, disabled: false,
		retry_setup_failed: true, interfaces: [] } } } }).reason,
	'wireless_initialization_failed', 'AP initialization failure precedes missing parent configuration');
equal(result('wifi-iface:office', { ...base,
	sources: { ...base.sources, wireless_aps: false } }).reason,
	'status_unavailable', 'failed AP configuration source cannot invent health');
equal(result('wifi-iface:office', { ...base, runtime: { ...base.runtime,
	devices: { eth0: base.runtime.devices.eth0 }, sys_devices: [ 'eth0' ] },
	sources: { ...base.sources, device_runtime: false, sysfs_devices: false } }).reason,
	'status_unavailable', 'failed live-device sources cannot invent AP health');
equal(result('wifi-iface:office', { ...base, sources: { ...base.sources,
	device_runtime: false, sysfs_devices: false } }).reason,
	'status_unavailable', 'partial AP device data from failed sources is not trusted');
equal(result('wifi-iface:office', { ...base, runtime: { ...base.runtime,
	devices: { ...base.runtime.devices,
		'phy0-ap0': { present: true, up: true, carrier: true, operstate: 'up' } },
	sys_devices: [ 'eth0' ] }, sources: { ...base.sources, device_runtime: false } }).reason,
	'wireless_ap_down', 'failed device runtime cannot override confirmed AP sysfs absence');
equal(result('wifi-iface:office', { ...base, runtime: { ...base.runtime,
	devices: { ...base.runtime.devices,
		'phy0-ap0': { present: false, up: true, carrier: true, operstate: 'up' } },
	sys_devices: [ 'eth0', 'phy0-ap0' ] }, sources: { ...base.sources, sysfs_devices: false } }).reason,
	'wireless_ap_down', 'failed sysfs data cannot override confirmed AP runtime absence');
equal(result('wifi-iface:office', { ...base, runtime: { ...base.runtime,
	devices: { eth0: base.runtime.devices.eth0 }, sys_devices: [ 'eth0' ] } }).reason,
	'wireless_ap_down', 'confirmed AP live device disappearance detected');
equal(result('bad selector', base).reason, 'status_unavailable',
	'invalid selector has conservative result');

let called = 0;
let run = run_interface_with({ interface_selector: 'device:eth0' }, {
	snapshot: () => { called++; return base; },
	clock: () => 1700000000
});
equal(called, 1, 'fresh snapshot collected once per probe');
truthy(run.ok, 'synchronous worker probe returns health result');
