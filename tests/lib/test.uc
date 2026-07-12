export function equal(actual, expected, label) {
	if (actual != expected)
		die(`${label}: expected ${expected}, got ${actual}\n`);
};

export function truthy(value, label) {
	if (!value)
		die(`${label}: expected a truthy value\n`);
};

function same_value(actual, expected) {
	if (type(actual) != type(expected))
		return false;

	if (type(actual) == 'array') {
		if (length(actual) != length(expected))
			return false;

		for (let i = 0; i < length(actual); i++)
			if (!same_value(actual[i], expected[i]))
				return false;

		return true;
	}

	if (type(actual) == 'object') {
		let actual_count = 0;
		let expected_count = 0;

		for (let key, value in actual) {
			actual_count++;

			if (!(key in expected) || !same_value(value, expected[key]))
				return false;
		}

		for (let key in expected)
			expected_count++;

		return actual_count == expected_count;
	}

	return actual == expected;
};

export function deep_equal(actual, expected, label) {
	if (!same_value(actual, expected))
		die(`${label}: expected ${sprintf('%J', expected)}, got ${sprintf('%J', actual)}\n`);
};
