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

for class in \
	"'class': 'table cbi-section-table'" \
	"'class': 'tr cbi-section-table-row'" \
	"'class': 'th cbi-section-table-cell left'" \
	"'class': 'td cbi-section-table-cell left'"
do
	grep -Fq "$class" "$VIEW" || {
		echo "missing LuCI layout class: $class" >&2
		exit 1
	}
done

grep -Fq "s.option(form.DummyValue, '_operations', _('Backup actions'))" \
	"$VIEW" || {
	echo 'Operations are not aligned through a titled LuCI form row' >&2
	exit 1
}

if grep -Fq "s = m.section(form.NamedSection, 'main', 'scheduled_backup', _('Credentials'));" \
	"$VIEW"; then
	echo 'Credentials still render as an independent section' >&2
	exit 1
fi

sftp_line=$(grep -n "_('SFTP'));" "$VIEW" | head -1 | cut -d: -f1)
password_line=$(grep -n "'_password'" "$VIEW" | head -1 | cut -d: -f1)
operations_line=$(grep -n "_('Operations'));" "$VIEW" | head -1 | cut -d: -f1)
[ "$sftp_line" -lt "$password_line" ] && [ "$password_line" -lt "$operations_line" ] || {
	echo 'Credential widgets are not contained by the SFTP section' >&2
	exit 1
}

MAKEFILE=$ROOT/Makefile

grep -Fq 'PKG_VERSION:=1.0.0' "$MAKEFILE"
grep -Fq 'PKG_RELEASE:=2' "$MAKEFILE"
grep -Fq 'LUCI_TITLE:=Scheduled configuration backups' "$MAKEFILE"
grep -Fq 'LUCI_PKGARCH:=all' "$MAKEFILE"
grep -Fq 'LUCI_DEPENDS:=' "$MAKEFILE"
grep -Fq '+luci-base' "$MAKEFILE"
grep -Fq '+rpcd-mod-file' "$MAKEFILE"
grep -Fq 'include $(TOPDIR)/feeds/luci/luci.mk' "$MAKEFILE"
grep -Fq 'define Package/luci-app-scheduled-backup/conffiles' "$MAKEFILE"
grep -Fxq '/etc/config/scheduled-backup' "$MAKEFILE"
grep -Fxq '/etc/scheduled-backup/' "$MAKEFILE"

if grep -Fq '$(CP) ./htdocs/* $(1)/' "$MAKEFILE"; then
	echo 'Scheduled Backup still installs htdocs at filesystem root' >&2
	exit 1
fi

echo 'LuCI static contracts passed'
