import { equal } from 'test';
import { parse_ping } from 'ping';

// These summaries mirror tests/fixtures/ping. The pinned host interpreter is
// intentionally built without its optional fs module.
let ok_text = `3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 9.100/12.500/18.000 ms`;
let loss_text = `3 packets transmitted, 2 received, 33% packet loss
round-trip min/avg/max = 22.000/44.000/66.000 ms`;
let total_loss_text = '3 packets transmitted, 0 packets received, 100% packet loss';

let result = parse_ping(ok_text, 0, {
	check_loss: true, max_loss: 10, check_rtt: true, max_rtt: 100
});
equal(result.ok, true, 'healthy ping');
equal(result.reason, null, 'healthy reason');
equal(result.loss, 0, 'zero loss');
equal(result.avg_rtt, 12.5, 'average RTT');

result = parse_ping(loss_text, 1, {
	check_loss: true, max_loss: 20, check_rtt: false
});
equal(result.ok, false, 'partial loss threshold');
equal(result.reason, 'packet_loss', 'loss reason');
equal(result.loss, 33, 'partial loss metric');
equal(result.avg_rtt, 44, 'partial loss RTT');

result = parse_ping(ok_text, 0, {
	loss_enabled: false, rtt_enabled: true, max_rtt: 10
});
equal(result.ok, false, 'RTT threshold');
equal(result.reason, 'high_rtt', 'RTT reason');

result = parse_ping(total_loss_text, 1, {
	loss_enabled: true, max_loss: 100, rtt_enabled: false
});
equal(result.ok, false, 'total loss unhealthy');
equal(result.reason, 'unreachable', 'total loss reason');
equal(result.loss, 100, 'total loss metric');
equal(result.avg_rtt, null, 'total loss has no RTT');

result = parse_ping('ping: malformed output\n', 0, {});
equal(result.ok, false, 'malformed output unhealthy');
equal(result.reason, 'invalid_output', 'malformed output reason');
equal(result.loss, null, 'malformed output has no loss');
equal(result.avg_rtt, null, 'malformed output has no RTT');

result = parse_ping(`3 packets transmitted, 3 packets received, 100% packet loss
round-trip min/avg/max = 1.000/2.000/3.000 ms`, 0, {});
equal(result.ok, false, 'inconsistent packet summary unhealthy');
equal(result.reason, 'invalid_output', 'inconsistent packet summary reason');

result = parse_ping(loss_text, 1, {
	loss_enabled: true, max_loss: 40, rtt_enabled: true, max_rtt: 50
});
equal(result.ok, false, 'nonzero exit unhealthy');
equal(result.reason, 'ping_failed', 'nonzero exit reason');
equal(result.loss, 33, 'nonzero exit preserves loss');
equal(result.avg_rtt, 44, 'nonzero exit preserves RTT');
