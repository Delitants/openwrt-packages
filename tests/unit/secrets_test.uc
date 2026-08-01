import { deep_equal, equal, truthy } from 'test';
import {
	migrate_smtp_password, replace_smtp_password, clear_smtp_password,
	valid_smtp_password
} from 'secrets';

function fake_cursor(secret, legacy) {
	let values = {
		'netwatch-secrets.smtp.password': secret,
		'netwatch.smtp.password': legacy
	};
	let sections = { 'netwatch-secrets.smtp': true, 'netwatch.smtp': true };
	let events = [];
	let cursor = {
		get: (config, section, option) => values[`${config}.${section}.${option}`],
		get_all: (config, section) => sections[`${config}.${section}`] ? {} : null,
		set: (config, section, option, value) => {
			if (value == null) {
				push(events, [ 'set-section', config, section, option ]);
				sections[`${config}.${section}`] = true;
			}
			else {
				push(events, [ 'set', config, section, option, value ]);
				values[`${config}.${section}.${option}`] = value;
			}
			return true;
		},
		delete: (config, section, option) => {
			push(events, [ 'delete', config, section, option ]);
			delete values[`${config}.${section}.${option}`];
			return true;
		},
		commit: (config) => {
			push(events, [ 'commit', config ]);
			return true;
		}
	};

	return { cursor, values, events, sections };
};

let legacy_only = fake_cursor(null, 'legacy-migration-value');
equal(migrate_smtp_password(legacy_only.cursor), 'legacy-migration-value',
	'legacy password remains available after migration');
deep_equal(legacy_only.events, [
	[ 'set', 'netwatch-secrets', 'smtp', 'password', 'legacy-migration-value' ],
	[ 'commit', 'netwatch-secrets' ],
	[ 'delete', 'netwatch', 'smtp', 'password' ],
	[ 'commit', 'netwatch' ]
], 'secret is committed before the browser-readable legacy option is deleted');
equal(legacy_only.values['netwatch.smtp.password'], null,
	'legacy public password is removed');

let long_legacy_value = '';
for (let index = 0; index < 1500; index++)
	long_legacy_value += 'p';
let long_legacy = fake_cursor(null, long_legacy_value);
equal(valid_smtp_password(long_legacy_value), false,
	'new password input remains bounded independently of migration');
equal(migrate_smtp_password(long_legacy.cursor), long_legacy_value,
	'previously usable long legacy password remains exact');
deep_equal(long_legacy.events, [
	[ 'set', 'netwatch-secrets', 'smtp', 'password', long_legacy_value ],
	[ 'commit', 'netwatch-secrets' ],
	[ 'delete', 'netwatch', 'smtp', 'password' ],
	[ 'commit', 'netwatch' ]
], 'long legacy password is committed exactly before public deletion');

let empty_legacy = fake_cursor(null, '');
equal(migrate_smtp_password(empty_legacy.cursor), '',
	'explicit empty legacy value retains anonymous SMTP behavior');
deep_equal(empty_legacy.events, [
	[ 'set', 'netwatch-secrets', 'smtp', 'password', '' ],
	[ 'commit', 'netwatch-secrets' ],
	[ 'delete', 'netwatch', 'smtp', 'password' ],
	[ 'commit', 'netwatch' ]
], 'empty legacy value is also committed exactly before public cleanup');

let invalid_legacy = fake_cursor(null, 'legacy\nnot-usable');
let invalid_failed = false;
try { migrate_smtp_password(invalid_legacy.cursor); }
catch (error) { invalid_failed = true; }
truthy(invalid_failed, 'invalid legacy migration aborts');
deep_equal(invalid_legacy.events, [],
	'invalid legacy value is never deleted without a private commit');
equal(invalid_legacy.values['netwatch.smtp.password'], 'legacy\nnot-usable',
	'aborted migration preserves legacy data');

let conflicting = fake_cursor('private-current-value', 'different-public-value');
let conflict_failed = false;
try { migrate_smtp_password(conflicting.cursor); }
catch (error) { conflict_failed = true; }
truthy(conflict_failed, 'conflicting private and legacy values abort migration');
deep_equal(conflicting.events, [], 'conflict does not delete either value');
equal(conflicting.values['netwatch.smtp.password'], 'different-public-value',
	'conflicting legacy value is preserved');

let already_migrated = fake_cursor('private-current-value', 'private-current-value');
equal(migrate_smtp_password(already_migrated.cursor), 'private-current-value',
	'exact previously committed private password is reused');
deep_equal(already_migrated.events, [
	[ 'delete', 'netwatch', 'smtp', 'password' ],
	[ 'commit', 'netwatch' ]
], 'existing private value is never overwritten during legacy cleanup');

let missing_secret_section = fake_cursor(null, null);
missing_secret_section.sections['netwatch-secrets.smtp'] = false;
truthy(replace_smtp_password(missing_secret_section.cursor, 'replacement-value'),
	'replacement is persisted');
deep_equal(missing_secret_section.events, [
	[ 'set-section', 'netwatch-secrets', 'smtp', 'smtp' ],
	[ 'set', 'netwatch-secrets', 'smtp', 'password', 'replacement-value' ],
	[ 'commit', 'netwatch-secrets' ]
], 'missing private section is created before replacement');

let clear = fake_cursor('private-current-value', null);
truthy(clear_smtp_password(clear.cursor), 'stored password is cleared');
deep_equal(clear.events, [
	[ 'delete', 'netwatch-secrets', 'smtp', 'password' ],
	[ 'commit', 'netwatch-secrets' ]
], 'clear affects and commits only the private package');

truthy(valid_smtp_password('visible replacement'), 'ordinary password accepted');
equal(valid_smtp_password(''), false, 'empty replacement rejected');
equal(valid_smtp_password('unsafe\nvalue'), false, 'control characters rejected');
