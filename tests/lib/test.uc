export function equal(actual, expected, label) {
	if (actual != expected)
		die(`${label}: expected ${expected}, got ${actual}\n`);
};

export function truthy(value, label) {
	if (!value)
		die(`${label}: expected a truthy value\n`);
};

export function deep_equal(actual, expected, label) {
	let actual_json = sprintf('%J', actual);
	let expected_json = sprintf('%J', expected);

	if (actual_json != expected_json)
		die(`${label}: expected ${expected_json}, got ${actual_json}\n`);
};
