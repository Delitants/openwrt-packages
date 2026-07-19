// The pinned OpenWrt ucode runtime reports string length in bytes.
const EVIDENCE_LIMIT = 4096;

const RESULT_TYPES = {
	ok: [ 'bool' ],
	reason: [ 'string' ],
	loss: [ 'int', 'double' ],
	avg_rtt: [ 'int', 'double' ],
	detail: [ 'string' ],
	summary: [ 'string' ],
	selector: [ 'string' ],
	kind: [ 'string' ],
	configured_name: [ 'string' ],
	label: [ 'string' ],
	live_device: [ 'string' ],
	observed_at: [ 'int' ],
	evidence: [ 'object' ]
};

const EVIDENCE_FIELDS = {
	up: true,
	available: true,
	auto: true,
	device: true,
	proto: true,
	present: true,
	carrier: true,
	operstate: true,
	mtu: true,
	pending: true,
	disabled: true,
	retry_setup_failed: true,
	radio: true,
	ssid: true,
	radio_up: true,
	ifname: true,
	live_present: true,
	device_up: true,
	device_operstate: true
};

function compact_evidence_value(value) {
	let output = {};

	if (type(value) == 'object') {
		for (let name, field in value) {
			if (!(name in EVIDENCE_FIELDS) ||
				!(field == null || type(field) in [ 'string', 'int', 'double', 'bool' ]))
				continue;

			if (type(field) == 'string') {
				if (length(field) > EVIDENCE_LIMIT || match(field, /[[:cntrl:]]/))
					continue;
			}

			output[name] = field;
		}
	}

	let json = sprintf('%J', output);
	if (length(json) > EVIDENCE_LIMIT)
		return { value: {}, json: '{}' };

	return { value: output, json };
};

export function compact_evidence(value) {
	return compact_evidence_value(value).value;
};

export function compact_evidence_json(value) {
	return compact_evidence_value(value).json;
};

export function compact_result_with_evidence(value) {
	if (type(value) != 'object')
		return { value: null, evidence_json: null };

	let output = {};
	let evidence_json = null;
	for (let name, field in value) {
		let allowed = RESULT_TYPES[name];
		if (!allowed || !(field == null || type(field) in allowed))
			continue;

		if (name == 'evidence') {
			let evidence = compact_evidence_value(field);
			output[name] = evidence.value;
			evidence_json = evidence.json;
		}
		else {
			output[name] = field;
		}
	}

	return { value: output, evidence_json };
};

export function compact_result(value) {
	return compact_result_with_evidence(value).value;
};
