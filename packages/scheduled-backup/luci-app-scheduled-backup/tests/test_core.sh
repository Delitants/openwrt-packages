#!/bin/sh
set -eu
ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
. "$ROOT/root/usr/lib/scheduled-backup/core.sh"
fail=0
eq() { [ "$1" = "$2" ] || { echo "not equal: [$1] [$2]" >&2; fail=1; }; }
ok() { "$@" || { echo "expected success: $*" >&2; fail=1; }; }
bad() { if "$@"; then echo "expected failure: $*" >&2; fail=1; fi; }
ok sb_validate_uint hour 23 0 23
bad sb_validate_uint hour 24 0 23
bad sb_validate_uint hour '2;id' 0 23
ok sb_validate_path /mnt/backups
bad sb_validate_path relative/path
bad sb_validate_path '/mnt/a
b'
eq "$(sb_sanitize_hostname 'Router One!')" 'router-one'
eq "$(SB_DATE='20260711-030405' sb_filename 'router-one' 0)" 'openwrt-router-one-20260711-030405.tar.gz'
eq "$(sb_cron_line daily 3 5 0)" '5 3 * * * /usr/sbin/scheduled-backup run'
eq "$(sb_cron_line weekly 3 5 2)" '5 3 * * 2 /usr/sbin/scheduled-backup run'
eq "$(sb_select_expired 2 openwrt-r-20260709-000000.tar.gz openwrt-r-20260711-000000.tar.gz openwrt-r-20260710-000000.tar.gz)" 'openwrt-r-20260709-000000.tar.gz'
eq "$(sb_select_expired 0 openwrt-r-20260709-000000.tar.gz)" ''
eq "$(sb_redact '')" ''
eq "$(sb_redact 'super-secret')" '[redacted]'
grep -Fq '[ ! -d ./htdocs ] || $(CP) ./htdocs/* $(1)/' "$ROOT/Makefile" || {
	echo 'missing absent-directory-safe htdocs install recipe' >&2
	fail=1
}
[ "$fail" -eq 0 ]
