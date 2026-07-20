#!/bin/sh
set -eu

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/secrets"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "${3:-}" in
	scheduled-backup.main.enabled) printf '%s\n' "${TEST_ENABLED:-1}" ;;
	scheduled-backup.main.schedule_mode) printf '%s\n' "${TEST_MODE:-daily}" ;;
	scheduled-backup.main.hour) printf '%s\n' "${TEST_HOUR:-3}" ;;
	scheduled-backup.main.minute) printf '%s\n' "${TEST_MINUTE:-5}" ;;
	scheduled-backup.main.weekday) printf '%s\n' "${TEST_WEEKDAY:-2}" ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
expr=
file=
while [ "$#" -gt 0 ]; do
	case "$1" in -e) expr=$2; shift 2 ;; -i) file=$2; shift 2 ;; *) shift ;; esac
done
expr=${expr#@}
[ -z "$file" ] || exec jq -r "$expr // empty" "$file"
exec jq -r "$expr // empty"
EOF
cat >"$tmp/bin/backend" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_BACKEND_LOG"
case "$1" in
	run) [ "${TEST_BACKEND_BLOCK:-0}" = 0 ] || { printf '%s\n' 'state=running' >"$TEST_ASYNC_STATUS"; sleep 3; }; exit 0 ;;
	test-sftp) printf '%s\n' "${TEST_SFTP_OUTPUT:-result=untrusted
fingerprints=SHA256:abc host ssh-ed25519 KEY}" ;;
	trust-host) exit 0 ;;
	*) exit 64 ;;
esac
EOF
chmod +x "$tmp/bin/uci" "$tmp/bin/jsonfilter" "$tmp/bin/backend"

[ -f "$ROOT/root/etc/uci-defaults/99-scheduled-backup-ucitrack" ]
grep -Fq "config scheduled-backup '/etc/init.d/scheduled-backup reload'" "$ROOT/root/etc/uci-defaults/99-scheduled-backup-ucitrack"

printf '%s\n' 'MAILTO=root' '17 4 * * * /usr/bin/unrelated --flag' >"$tmp/crontab"
cp "$tmp/crontab" "$tmp/unrelated"
SB_UCI="$tmp/bin/uci" SB_CRONTAB="$tmp/crontab" SB_CRON_INIT=/bin/true \
	SB_CORE="$ROOT/root/usr/lib/scheduled-backup/core.sh" sh -c '. "$1"; reload' sh "$ROOT/root/etc/init.d/scheduled-backup"
grep -qx '5 3 \* \* \* /usr/sbin/scheduled-backup run # luci-app-scheduled-backup' "$tmp/crontab"
[ "$(grep -c '# luci-app-scheduled-backup$' "$tmp/crontab")" -eq 1 ]
SB_UCI="$tmp/bin/uci" SB_CRONTAB="$tmp/crontab" SB_CRON_INIT=/bin/true \
	SB_CORE="$ROOT/root/usr/lib/scheduled-backup/core.sh" sh -c '. "$1"; reload' sh "$ROOT/root/etc/init.d/scheduled-backup"
[ "$(grep -c '# luci-app-scheduled-backup$' "$tmp/crontab")" -eq 1 ]
grep -v '# luci-app-scheduled-backup$' "$tmp/crontab" >"$tmp/remaining"
cmp "$tmp/unrelated" "$tmp/remaining"

TEST_MODE=weekly SB_UCI="$tmp/bin/uci" SB_CRONTAB="$tmp/crontab" SB_CRON_INIT=/bin/true \
	SB_CORE="$ROOT/root/usr/lib/scheduled-backup/core.sh" sh -c '. "$1"; reload' sh "$ROOT/root/etc/init.d/scheduled-backup"
grep -qx '5 3 \* \* 2 /usr/sbin/scheduled-backup run # luci-app-scheduled-backup' "$tmp/crontab"
TEST_ENABLED=0 SB_UCI="$tmp/bin/uci" SB_CRONTAB="$tmp/crontab" SB_CRON_INIT=/bin/true \
	SB_CORE="$ROOT/root/usr/lib/scheduled-backup/core.sh" sh -c '. "$1"; reload' sh "$ROOT/root/etc/init.d/scheduled-backup"
! grep -q '# luci-app-scheduled-backup$' "$tmp/crontab"
cmp "$tmp/unrelated" "$tmp/crontab"
TEST_ENABLED=1 SB_UCI="$tmp/bin/uci" SB_CRONTAB="$tmp/crontab" SB_CRON_INIT=/bin/true \
	SB_CORE="$ROOT/root/usr/lib/scheduled-backup/core.sh" sh -c '. "$1"; reload; stop' sh "$ROOT/root/etc/init.d/scheduled-backup"
! grep -q '# luci-app-scheduled-backup$' "$tmp/crontab"
cmp "$tmp/unrelated" "$tmp/crontab"

rpc="$ROOT/root/usr/libexec/rpcd/scheduled-backup"
list=$(SB_JSONFILTER="$tmp/bin/jsonfilter" sh "$rpc" list)
printf '%s' "$list" | jq -e '.status and .set_password and .clear_key' >/dev/null
printf '%s' "$list" | jq -e '.trust_host.fingerprint == "String" and .set_password.password == "String" and .set_key.key == "String"' >/dev/null
! printf '%s' "$list" | grep -q 'S3cret-marker'
cat >"$tmp/status" <<'EOF'
state=success
started=10
finished=20
filename=quote"backslash\value.tar.gz
size=42
local_result=success
local_message=stored
sftp_result=disabled
sftp_message=not_run
summary=success
password=S3cret-marker
EOF
status=$(printf '{}' | SB_JSONFILTER="$tmp/bin/jsonfilter" SB_STATUS="$tmp/status" SB_BACKEND="$tmp/bin/backend" SB_SECRET_DIR="$tmp/secrets" TEST_BACKEND_LOG="$tmp/backend.log" sh "$rpc" call status)
printf '%s' "$status" | jq -e '.state == "success" and .size == "42"' >/dev/null
! printf '%s' "$status" | grep -q 'S3cret-marker\|password'
printf '{}' | SB_JSONFILTER="$tmp/bin/jsonfilter" SB_STATUS="$tmp/status" SB_BACKEND="$tmp/bin/backend" SB_SECRET_DIR="$tmp/secrets" TEST_BACKEND_LOG="$tmp/backend.log" sh "$rpc" call status | jq -e . >/dev/null

printf '{}' | TEST_SFTP_OUTPUT='result=verified' SB_JSONFILTER="$tmp/bin/jsonfilter" SB_BACKEND="$tmp/bin/backend" TEST_BACKEND_LOG="$tmp/backend.log" sh "$rpc" call test_sftp | jq -e '.ok == true and .result == "verified" and (.fingerprints | not)' >/dev/null
printf '{}' | TEST_SFTP_OUTPUT='result=untrusted
fingerprints=SHA256:abc host ssh-ed25519 KEY' SB_JSONFILTER="$tmp/bin/jsonfilter" SB_BACKEND="$tmp/bin/backend" TEST_BACKEND_LOG="$tmp/backend.log" sh "$rpc" call test_sftp | jq -e '.ok == true and .result == "untrusted" and (.fingerprints | startswith("SHA256:abc"))' >/dev/null

rm -f "$tmp/async.status"
start=$(date +%s)
printf '{}' | TEST_BACKEND_BLOCK=1 TEST_ASYNC_STATUS="$tmp/async.status" SB_JSONFILTER="$tmp/bin/jsonfilter" SB_BACKEND="$tmp/bin/backend" TEST_BACKEND_LOG="$tmp/backend.log" sh "$rpc" call run | jq -e '.ok == true' >/dev/null
[ $(( $(date +%s) - start )) -lt 2 ]
i=0
while [ ! -e "$tmp/async.status" ] && [ "$i" -lt 20 ]; do sleep .1; i=$((i + 1)); done
grep -qx 'state=running' "$tmp/async.status"
if printf '{}' | SB_JSONFILTER="$tmp/bin/jsonfilter" SB_BACKEND="$tmp/missing-backend" sh "$rpc" call run >"$tmp/launch-fail"; then exit 1; fi
grep -q 'backup launch failed' "$tmp/launch-fail"

printf '{"password":"S3cret-marker","command":"touch %s/pwned"}' "$tmp" | \
	SB_JSONFILTER="$tmp/bin/jsonfilter" SB_STATUS="$tmp/status" SB_BACKEND="$tmp/bin/backend" SB_SECRET_DIR="$tmp/secrets" TEST_BACKEND_LOG="$tmp/backend.log" sh "$rpc" call set_password | jq -e '.ok == true' >/dev/null
[ "$(cat "$tmp/secrets/password")" = 'S3cret-marker' ]
[ "$(stat -f '%Lp' "$tmp/secrets/password" 2>/dev/null || stat -c '%a' "$tmp/secrets/password")" = 600 ]
[ ! -e "$tmp/pwned" ]
status=$(printf '{}' | SB_JSONFILTER="$tmp/bin/jsonfilter" SB_STATUS="$tmp/status" SB_BACKEND="$tmp/bin/backend" SB_SECRET_DIR="$tmp/secrets" TEST_BACKEND_LOG="$tmp/backend.log" sh "$rpc" call status)
! printf '%s' "$status" | grep -q 'S3cret-marker'

if printf '{}' | SB_JSONFILTER="$tmp/bin/jsonfilter" SB_BACKEND="$tmp/bin/backend" sh "$rpc" call unknown >"$tmp/unknown.out"; then
	echo 'unknown RPC call unexpectedly succeeded' >&2
	exit 1
fi
jq -e '.ok == false' "$tmp/unknown.out" >/dev/null

for json in "$ROOT"/root/usr/share/rpcd/acl.d/*.json "$ROOT"/root/usr/share/luci/menu.d/*.json; do
	jq -e . "$json" >/dev/null
done

echo 'rpcd tests passed'
