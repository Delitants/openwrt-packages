#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VIEW=$ROOT/htdocs/luci-static/resources/view/scheduled-backup.js

[ -f "$VIEW" ] || { echo 'LuCI view is missing' >&2; exit 1; }

for import in view form uci rpc ui; do
	grep -Fq "'require $import';" "$VIEW"
done

for method in status run test_sftp trust_host set_password clear_password set_key clear_key; do
	grep -Fq "method: '$method'" "$VIEW"
done

for option in enabled schedule_mode hour minute weekday local_enabled local_path local_keep \
	sftp_enabled sftp_host sftp_port sftp_user sftp_path sftp_auth sftp_keep \
	connect_timeout transfer_timeout; do
	grep -Fq "'$option'" "$VIEW"
done

for token in callRun callTestSftp callTrustHost callSetPassword callClearPassword \
	callSetKey callClearKey validateDestination absolute nonnegative uinteger \
	ui.showModal poll.add 'Run Now' 'Test SFTP' 'Trust Host' 'Clear Password' \
	'Clear Private Key' 'write-only'; do
	grep -Fq "$token" "$VIEW"
done
grep -Fq "result.result === 'verified'" "$VIEW"
grep -Fq "_('SFTP authentication and remote path verified.')" "$VIEW"

grep -Eq "\.depends\('schedule_mode', *'weekly'\)" "$VIEW"
grep -Eq "\.depends\('local_enabled', *'1'\)" "$VIEW"
grep -Eq "\.depends\('sftp_enabled', *'1'\)" "$VIEW"
grep -Fq "datatype = 'range(0,23)'" "$VIEW"
grep -Fq "datatype = 'range(0,59)'" "$VIEW"
grep -Fq "datatype = 'range(1,65535)'" "$VIEW"
[ "$(grep -Fc "datatype = 'range(1,2147483647)'" "$VIEW")" -eq 2 ]
password_dependencies=$(grep -Fc 'depends({ sftp_enabled: '\''1'\'', sftp_auth: '\''password'\'' })' "$VIEW")
key_dependencies=$(grep -Fc 'depends({ sftp_enabled: '\''1'\'', sftp_auth: '\''key'\'' })' "$VIEW")
[ "$password_dependencies" -eq 2 ]
[ "$key_dependencies" -eq 2 ]

! grep -Eq "(password|private_key|key).*uci\.get|uci\.get.*(password|private_key|key)" "$VIEW"

echo 'LuCI static contracts passed'
