import { deep_equal, equal, truthy } from 'test';
import { valid_target, valid_interface_selector, normalize_global, normalize_smtp, normalize_monitor } from 'config';

truthy(valid_target('192.0.2.1'), 'IPv4 accepted');
truthy(valid_target('2001:db8::1'), 'IPv6 accepted');
truthy(valid_target('router.example'), 'hostname accepted');
equal(valid_target('-c 1;reboot'), false, 'shell syntax rejected');
equal(valid_target('-router'), false, 'leading hyphen rejected');

let ping = normalize_monitor('cfg001', {
	enabled: '1', name: 'Gateway', target: '192.0.2.1', type: 'ping'
});
truthy(ping.ok, 'minimal ping monitor valid');
equal(ping.value.interval, 60, 'default interval');
equal(ping.value.failures, 3, 'default failure count');
equal(ping.value.packet_count, 3, 'default packet count');

let tcp = normalize_monitor('cfg002', {
	target: 'server.example', type: 'tcp', port: '443', repeat_interval: '600', max_alerts: '3'
});
truthy(tcp.ok, 'TCP monitor valid');
equal(tcp.value.port, 443, 'port normalized');

equal(normalize_monitor('bad', { target: 'x', type: 'tcp', port: '0' }).ok, false, 'zero port rejected');
equal(normalize_monitor('bad', { target: 'x', type: 'ping', max_loss: '101' }).ok, false, 'loss over 100 rejected');

let global = normalize_global({ enabled: '0' });
deep_equal(global, {
	enabled: false,
	startup_grace: 60,
	recipients: '',
	mail_retry_backoff: 300
}, 'global defaults normalized');

let ordered = {};
ordered.first = 1;
ordered.second = { nested: [2, 3] };
let reversed = {};
reversed.second = { nested: [2, 3] };
reversed.first = 1;
deep_equal(ordered, reversed, 'deep equality ignores object key order');

let smtp = normalize_smtp({ port: '465', tls: 'tls' });
equal(smtp.port, 465, 'SMTP port normalized');
equal(smtp.tls, 'tls', 'SMTP TLS normalized');

equal(valid_target('router.example\ninvalid'), false, 'target newline rejected');
equal(normalize_monitor('bad', {
	target: 'x', type: 'ping', name: 'unsafe\r\nheader'
}).ok, false, 'monitor newline rejected');

let bad_enabled = normalize_monitor('bad-enabled', {
	target: 'x', type: 'ping', enabled: '1\n0'
});
equal(bad_enabled.ok, false, 'enabled newline rejected');
truthy('enabled must not contain line breaks' in bad_enabled.errors, 'enabled newline error');

let bad_recovery = normalize_monitor('bad-recovery', {
	target: 'x', type: 'ping', recovery_email: '1\r0'
});
equal(bad_recovery.ok, false, 'recovery newline rejected');
truthy('recovery_email must not contain line breaks' in bad_recovery.errors, 'recovery newline error');

let bad_loss = normalize_monitor('bad-loss', {
	target: 'x', type: 'ping', loss_enabled: '1\n0'
});
equal(bad_loss.ok, false, 'loss boolean newline rejected');
truthy('loss_enabled must not contain line breaks' in bad_loss.errors, 'loss boolean newline error');

let bad_rtt = normalize_monitor('bad-rtt', {
	target: 'x', type: 'ping', rtt_enabled: '1\r0'
});
equal(bad_rtt.ok, false, 'RTT boolean newline rejected');
truthy('rtt_enabled must not contain line breaks' in bad_rtt.errors, 'RTT boolean newline error');

equal(normalize_monitor('bad', {
	target: 'x', type: 'ping', repeat_interval: '300'
}).ok, false, 'unsupported repeat rejected');

let normalized_ping = normalize_monitor('cfg003', {
	target: 'router.example', type: 'ping', enabled: '0', recovery_email: '1',
	loss_enabled: '1', rtt_enabled: '0'
});
equal(normalized_ping.value.enabled, false, 'disabled monitor normalized');
equal(normalized_ping.value.recovery_email, true, 'recovery boolean normalized');
equal(normalized_ping.value.loss_enabled, true, 'loss boolean normalized');
equal(normalized_ping.value.rtt_enabled, false, 'RTT boolean normalized');

truthy(valid_interface_selector('network:wan'), 'logical network selector accepted');
truthy(valid_interface_selector('device:br-lan'), 'Linux device selector accepted');
truthy(valid_interface_selector('wifi-radio:radio0'), 'radio selector accepted');
truthy(valid_interface_selector('wifi-iface:guest_5g'), 'AP selector accepted');
equal(valid_interface_selector('device:-eth0'), false, 'option-like device rejected');
equal(valid_interface_selector('device:eth0/reboot'), false, 'path syntax rejected');
equal(valid_interface_selector('wifi-iface:guest\nkey'), false, 'control character rejected');
equal(valid_interface_selector('other:wan'), false, 'unknown selector kind rejected');

let interface_monitor = normalize_monitor('wifi_watch', {
	type: 'interface', interface_selector: 'wifi-iface:guest_5g'
});
truthy(interface_monitor.ok, 'interface monitor does not require host target');
equal(interface_monitor.value.target, '', 'interface monitor has no host target');
equal(interface_monitor.value.interface_selector, 'wifi-iface:guest_5g',
	'interface selector normalized');
equal(normalize_monitor('missing', { type: 'interface' }).ok, false,
	'interface selector required');
equal(normalize_monitor('ping', { type: 'ping', target: 'router.example' }).ok, true,
	'ping compatibility retained');
equal(normalize_monitor('tcp', { type: 'tcp', target: 'router.example', port: '443' }).ok, true,
	'TCP compatibility retained');

let interface_with_nonstring_target = normalize_monitor('wireless', {
	type: 'interface', interface_selector: 'wifi-iface:guest_5g', target: 1
});
truthy(interface_with_nonstring_target.ok, 'interface ignores non-string target');
equal(interface_with_nonstring_target.value.target, '', 'irrelevant interface target normalized');

let interface_with_newline_target = normalize_monitor('wireless-newline', {
	type: 'interface', interface_selector: 'wifi-iface:guest_5g', target: 'unsafe\ntarget'
});
truthy(interface_with_newline_target.ok, 'interface ignores newline target');

let ping_with_nonstring_selector = normalize_monitor('ping-selector', {
	type: 'ping', target: 'router.example', interface_selector: 1
});
truthy(ping_with_nonstring_selector.ok, 'ping ignores non-string interface selector');
equal(ping_with_nonstring_selector.value.interface_selector, '', 'irrelevant ping selector normalized');

let tcp_with_newline_selector = normalize_monitor('tcp-selector', {
	type: 'tcp', target: 'router.example', port: '443', interface_selector: 'unsafe\nselector'
});
truthy(tcp_with_newline_selector.ok, 'TCP ignores newline interface selector');
equal(tcp_with_newline_selector.value.interface_selector, '', 'irrelevant TCP selector normalized');
