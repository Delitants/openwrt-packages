function result(ok, reason, loss, avg_rtt, detail) {
	return {
		ok,
		reason,
		loss,
		avg_rtt,
		detail
	};
};

function metric_detail(loss, avg_rtt) {
	return avg_rtt == null
		? sprintf('loss=%d%%', loss)
		: sprintf('loss=%d%% avg_rtt=%.3fms', loss, avg_rtt);
};

export function parse_ping(output, exit_code, monitor) {
	monitor ??= {};

	if (type(output) != 'string')
		return result(false, 'invalid_output', null, null, 'invalid ping output');

	let summary = match(output,
		/([0-9]+) packets transmitted, ([0-9]+) (packets received|received), ([0-9]+)% packet loss/);

	if (!summary)
		return result(false, 'invalid_output', null, null, 'invalid ping output');

	let transmitted = +summary[1];
	let received = +summary[2];
	let loss = +summary[4];
	let lost = transmitted - received;

	if (transmitted < 1 || received > transmitted || loss < 0 || loss > 100 ||
		loss * transmitted > lost * 100 ||
		(loss + 1) * transmitted <= lost * 100)
		return result(false, 'invalid_output', null, null, 'invalid ping output');

	let rtt = match(output,
		/round-trip min\/avg\/max = ([0-9]+[.]?[0-9]*)\/([0-9]+[.]?[0-9]*)\/([0-9]+[.]?[0-9]*) ms/);
	let avg_rtt = rtt ? +rtt[2] : null;

	if (loss < 100 && avg_rtt == null)
		return result(false, 'invalid_output', loss, null, 'invalid ping RTT output');

	let detail = metric_detail(loss, avg_rtt);

	if (loss == 100 || received == 0)
		return result(false, 'unreachable', loss, avg_rtt, detail);

	let check_loss = monitor.loss_enabled ?? monitor.check_loss ?? false;
	let check_rtt = monitor.rtt_enabled ?? monitor.check_rtt ?? false;

	if (check_loss && loss > monitor.max_loss)
		return result(false, 'packet_loss', loss, avg_rtt, detail);

	if (check_rtt && avg_rtt > monitor.max_rtt)
		return result(false, 'high_rtt', loss, avg_rtt, detail);

	if (exit_code != 0)
		return result(false, 'ping_failed', loss, avg_rtt, detail);

	return result(true, null, loss, avg_rtt, detail);
};
