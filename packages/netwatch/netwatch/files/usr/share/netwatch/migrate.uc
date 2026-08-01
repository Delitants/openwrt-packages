import * as uci from 'uci';
import { migrate_smtp_password } from 'secrets';

migrate_smtp_password(uci.cursor());
