const PUBLIC_CONFIG = 'netwatch';
const SECRET_CONFIG = 'netwatch-secrets';
const SMTP_SECTION = 'smtp';
const PASSWORD_OPTION = 'password';

export function valid_smtp_password(value) {
	return type(value) == 'string' && length(value) >= 1 &&
		length(value) <= 1024 && !match(value, /[[:cntrl:]]/);
};

function require_operation(result) {
	if (result !== true)
		die('unable to update SMTP password storage');
};

function ensure_secret_section(cursor) {
	if (cursor.get_all(SECRET_CONFIG, SMTP_SECTION) == null)
		require_operation(cursor.set(SECRET_CONFIG, SMTP_SECTION, 'smtp'));
};

export function replace_smtp_password(cursor, password) {
	if (!valid_smtp_password(password))
		return false;

	ensure_secret_section(cursor);
	require_operation(cursor.set(
		SECRET_CONFIG, SMTP_SECTION, PASSWORD_OPTION, password));
	require_operation(cursor.commit(SECRET_CONFIG));
	return true;
};

export function clear_smtp_password(cursor) {
	let current = cursor.get(SECRET_CONFIG, SMTP_SECTION, PASSWORD_OPTION);

	if (current != null) {
		require_operation(cursor.delete(
			SECRET_CONFIG, SMTP_SECTION, PASSWORD_OPTION));
		require_operation(cursor.commit(SECRET_CONFIG));
	}

	return true;
};

export function migrate_smtp_password(cursor) {
	let secret_raw = cursor.get(SECRET_CONFIG, SMTP_SECTION, PASSWORD_OPTION);
	let legacy_raw = cursor.get(PUBLIC_CONFIG, SMTP_SECTION, PASSWORD_OPTION);
	let password = valid_smtp_password(secret_raw) ? secret_raw : '';

	if (password == '' && valid_smtp_password(legacy_raw)) {
		replace_smtp_password(cursor, legacy_raw);
		password = legacy_raw;
	}

	if (legacy_raw != null) {
		require_operation(cursor.delete(
			PUBLIC_CONFIG, SMTP_SECTION, PASSWORD_OPTION));
		require_operation(cursor.commit(PUBLIC_CONFIG));
	}

	return password;
};
