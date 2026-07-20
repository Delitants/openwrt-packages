#!/bin/sh
set -eu

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/backups" "$tmp/tmp"

cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
key=${3:-}
case "$key" in
	scheduled-backup.main.enabled) printf '%s\n' 1 ;;
	scheduled-backup.main.local_enabled) printf '%s\n' "${TEST_LOCAL_ENABLED:-1}" ;;
	scheduled-backup.main.local_path) printf '%s\n' "${TEST_LOCAL_PATH:-$TEST_BACKUPS}" ;;
	scheduled-backup.main.local_keep) printf '%s\n' "${TEST_LOCAL_KEEP:-7}" ;;
	scheduled-backup.main.sftp_enabled) printf '%s\n' "${TEST_SFTP_ENABLED:-0}" ;;
	scheduled-backup.main.sftp_host) printf '%s\n' "${TEST_SFTP_HOST:-backup.example}" ;;
	scheduled-backup.main.sftp_port) printf '%s\n' "${TEST_SFTP_PORT:-22}" ;;
	scheduled-backup.main.sftp_user) printf '%s\n' "${TEST_SFTP_USER:-backup}" ;;
	scheduled-backup.main.sftp_path) printf '%s\n' "${TEST_SFTP_PATH:-/remote/backups}" ;;
	scheduled-backup.main.sftp_auth) printf '%s\n' "${TEST_SFTP_AUTH:-password}" ;;
	scheduled-backup.main.sftp_keep) printf '%s\n' "${TEST_SFTP_KEEP:-7}" ;;
	scheduled-backup.main.connect_timeout) printf '%s\n' "${TEST_CONNECT_TIMEOUT:-15}" ;;
	scheduled-backup.main.transfer_timeout) printf '%s\n' "${TEST_TRANSFER_TIMEOUT:-300}" ;;
	'system.@system[0].hostname') printf '%s\n' 'Test Router' ;;
	*) exit 1 ;;
esac
EOF

cat >"$tmp/bin/sysupgrade" <<'EOF'
#!/bin/sh
[ "$1" = -k ] && [ "$2" = -b ] && [ "$#" -eq 3 ] || exit 64
printf '%s\n' "$$" >>"$TEST_SYSUPGRADE_LOG"
[ "${TEST_SYSUPGRADE_FAIL:-0}" = 0 ] || exit 1
[ "${TEST_INVALID_ARCHIVE:-0}" = 0 ] || { printf '%s\n' not-a-tar >"$3"; exit 0; }
[ "${TEST_SYSUPGRADE_WAIT:-0}" = 0 ] || {
	: >"$TEST_SYSUPGRADE_STARTED"
	trap 'exit 143' TERM INT HUP
	while :; do sleep 1; done
}
work=${3}.contents
mkdir "$work"
printf '%s\n' test-config >"$work/config.txt"
tar -czf "$3" -C "$work" config.txt
rm -rf "$work"
EOF

cat >"$tmp/bin/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_LOGGER_LOG"
EOF

cat >"$tmp/bin/lftp" <<'EOF'
#!/bin/sh
printf 'argv:' >>"$TEST_LFTP_LOG"
printf ' <%s>' "$@" >>"$TEST_LFTP_LOG"
printf '\n' >>"$TEST_LFTP_LOG"
[ "$1" = -f ] && [ "$#" -eq 2 ] || exit 64
printf '%s\n' 'batch-begin' >>"$TEST_LFTP_LOG"
sed '/^set sftp:connect-program /s/.*/connect-program [redacted]/; /^open /s/.*/open [redacted]/' "$2" >>"$TEST_LFTP_LOG"
printf '%s\n' 'batch-end' >>"$TEST_LFTP_LOG"
cp "$2" "$TEST_LFTP_BATCH"
[ "${TEST_LFTP_FAIL:-0}" = 0 ] || exit 1
if grep -q '^cls -1 -- ' "$2"; then
	printf '%s\n' ${TEST_LFTP_LISTING:-}
fi
EOF

cat >"$tmp/bin/ssh-keyscan" <<'EOF'
#!/bin/sh
printf '%s\n' "${TEST_KEYSCAN_OUTPUT:-backup.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILfv9C8uapQbMWzHhO7O89scQjLT4JQ5xQ3ZmxhmVpR9}"
EOF

cat >"$tmp/bin/ssh-keygen" <<'EOF'
#!/bin/sh
[ "$1" = -lf ] && [ "$#" -eq 2 ] || exit 64
while IFS= read -r line; do
	case "$line" in
		*KEY-A*) fp=SHA256:key-a ;;
		*KEY-B*) fp=SHA256:key-b ;;
		*KEY-DUP-1*|*KEY-DUP-2*) fp=SHA256:duplicate ;;
		*) fp=SHA256:default-key ;;
	esac
	set -- $line
	printf '256 %s %s (ED25519)\n' "$fp" "$1"
done <"$2"
EOF

chmod +x "$tmp/bin/uci" "$tmp/bin/sysupgrade" "$tmp/bin/logger" "$tmp/bin/lftp" "$tmp/bin/ssh-keyscan" "$tmp/bin/ssh-keygen"

run_backend() {
	TEST_BACKUPS="$tmp/backups" TEST_LOGGER_LOG="$tmp/logger.log" \
	TEST_SYSUPGRADE_LOG="$tmp/sysupgrade.log" \
	SB_UCI="$tmp/bin/uci" SB_SYSUPGRADE="$tmp/bin/sysupgrade" \
	SB_TAR=tar SB_LOGGER="$tmp/bin/logger" SB_STATUS="${TEST_STATUS:-$tmp/status}" \
	SB_LOCKDIR="$tmp/lock" SB_TMPBASE="$tmp/tmp" SB_DATE=20260711-030405 \
	SB_LFTP="$tmp/bin/lftp" SB_SSH_KEYSCAN="$tmp/bin/ssh-keyscan" \
	SB_SSH_KEYGEN="$tmp/bin/ssh-keygen" \
	SB_SECRET_DIR="$tmp/secrets" TEST_LFTP_LOG="$tmp/lftp.log" \
	TEST_LFTP_BATCH="$tmp/lftp.batch" \
	TEST_LFTP_LISTING="${TEST_LFTP_LISTING:-}" TEST_LFTP_FAIL="${TEST_LFTP_FAIL:-0}" \
	sh "$ROOT/root/usr/sbin/scheduled-backup" run
}

run_backend
set -- "$tmp/backups"/openwrt-test-router-*.tar.gz
[ "$#" -eq 1 ] && [ -f "$1" ]
tar -tzf "$1" >/dev/null
grep -qx 'state=success' "$tmp/status"
grep -qx 'local_result=success' "$tmp/status"
grep -qx 'sftp_result=disabled' "$tmp/status"
grep -qx 'sftp_message=not_run' "$tmp/status"
[ ! -e "$tmp/backups/.openwrt-test-router-20260711-030405.tar.gz.part" ]

rm -f "$tmp/backups"/*
touch "$tmp/backups/openwrt-test-router-20260707-030405.tar.gz" "$tmp/backups/openwrt-test-router-20260708-030405.tar.gz" "$tmp/backups/openwrt-test-router-20260709-030405.tar.gz" "$tmp/backups/openwrt-other-router-20260701-030405.tar.gz" "$tmp/backups/openwrt-test-router-20260701-030405.tar.gz.evil"
TEST_LOCAL_KEEP=2 run_backend
[ ! -e "$tmp/backups/openwrt-test-router-20260707-030405.tar.gz" ]
[ ! -e "$tmp/backups/openwrt-test-router-20260708-030405.tar.gz" ]
[ -e "$tmp/backups/openwrt-test-router-20260709-030405.tar.gz" ]
[ -e "$tmp/backups/openwrt-test-router-20260711-030405.tar.gz" ]
[ -e "$tmp/backups/openwrt-other-router-20260701-030405.tar.gz" ]
[ -e "$tmp/backups/openwrt-test-router-20260701-030405.tar.gz.evil" ]
touch "$tmp/backups/openwrt-test-router-20260706-030405.tar.gz"
TEST_LOCAL_KEEP=0 run_backend
[ -e "$tmp/backups/openwrt-test-router-20260706-030405.tar.gz" ]

before_publish_fail=$(find "$tmp/backups" -type f -print | sort)
ln -s /dev/full "$tmp/backups/.openwrt-test-router-20260711-030405.tar.gz.part"
if run_backend 2>/dev/null; then exit 1; fi
[ "$before_publish_fail" = "$(find "$tmp/backups" -type f -print | sort)" ]

mkdir "$tmp/lock"
calls_before=$(wc -l <"$tmp/sysupgrade.log" | tr -d ' ')
run_backend
grep -qx 'state=skipped' "$tmp/status"
calls_after=$(wc -l <"$tmp/sysupgrade.log" | tr -d ' ')
[ "$calls_before" = "$calls_after" ]
rmdir "$tmp/lock"

rm -f "$tmp/backups"/*.tar.gz
if TEST_SYSUPGRADE_FAIL=1 run_backend; then
	echo 'failed sysupgrade unexpectedly returned success' >&2
	exit 1
fi
set -- "$tmp/backups"/openwrt-test-router-*.tar.gz
[ "$#" -eq 1 ] && [ ! -e "$1" ]
grep -qx 'state=failed' "$tmp/status"
grep -qx 'local_result=failed' "$tmp/status"
grep -qx 'sftp_result=disabled' "$tmp/status"

if TEST_LOCAL_ENABLED=0 TEST_SFTP_ENABLED=1 TEST_SYSUPGRADE_FAIL=1 run_backend; then exit 1; fi
grep -qx 'local_result=disabled' "$tmp/status"
grep -qx 'sftp_result=failed' "$tmp/status"

for failure in command invalid; do
	[ "$failure" = command ] && fail_env=TEST_SYSUPGRADE_FAIL=1 || fail_env=TEST_INVALID_ARCHIVE=1
	for destinations in local sftp both; do
		case "$destinations" in local) le=1; se=0 ;; sftp) le=0; se=1 ;; both) le=1; se=1 ;; esac
		if env "$fail_env" TEST_LOCAL_ENABLED=$le TEST_SFTP_ENABLED=$se TEST_BACKUPS="$tmp/backups" TEST_LOGGER_LOG="$tmp/logger.log" TEST_SYSUPGRADE_LOG="$tmp/sysupgrade.log" SB_UCI="$tmp/bin/uci" SB_SYSUPGRADE="$tmp/bin/sysupgrade" SB_TAR=tar SB_LOGGER="$tmp/bin/logger" SB_STATUS="$tmp/status" SB_LOCKDIR="$tmp/lock" SB_TMPBASE="$tmp/tmp" SB_DATE=20260711-030405 SB_SECRET_DIR="$tmp/secrets" sh "$ROOT/root/usr/sbin/scheduled-backup" run; then exit 1; fi
		[ "$le" = 1 ] && grep -qx 'local_result=failed' "$tmp/status" || grep -qx 'local_result=disabled' "$tmp/status"
		[ "$se" = 1 ] && grep -qx 'sftp_result=failed' "$tmp/status" || grep -qx 'sftp_result=disabled' "$tmp/status"
		! grep -q '=pending$' "$tmp/status"
	done
done

mkdir -p "$tmp/secrets"
printf '%s\n' 'S3cret-marker' >"$tmp/secrets/password"
printf '%s\n' 'backup.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILfv9C8uapQbMWzHhO7O89scQjLT4JQ5xQ3ZmxhmVpR9' >"$tmp/secrets/known_hosts"
chmod 600 "$tmp/secrets/password" "$tmp/secrets/known_hosts"
rm -f "$tmp/lftp.log"
TEST_LOCAL_ENABLED=0 TEST_LOCAL_PATH=relative TEST_LOCAL_KEEP=invalid \
	TEST_SFTP_ENABLED=1 TEST_SFTP_KEEP=0 TEST_SYSUPGRADE_FAIL=0 run_backend
grep -qx 'state=success' "$tmp/status"
grep -qx 'local_result=disabled' "$tmp/status"
grep -qx 'sftp_result=success' "$tmp/status"
grep -q '^put .* -o openwrt-test-router-20260711-030405.tar.gz.part$' "$tmp/lftp.batch"
put_line=$(grep -n '^put ' "$tmp/lftp.batch" | cut -d: -f1)
mv_line=$(grep -n '^mv ' "$tmp/lftp.batch" | cut -d: -f1)
[ "$put_line" -lt "$mv_line" ]
! grep -q '^rm ' "$tmp/lftp.batch"
grep -q 'StrictHostKeyChecking=yes' "$tmp/lftp.batch"
grep -q 'UserKnownHostsFile=' "$tmp/lftp.batch"
! grep -q 'BatchMode=yes' "$tmp/lftp.batch"
grep -q 'ConnectTimeout=15' "$tmp/lftp.batch"
grep -q '^set net:timeout 300$' "$tmp/lftp.batch"

TEST_LFTP_LISTING='openwrt-test-router-20260709-030405.tar.gz openwrt-test-router-20260710-030405.tar.gz openwrt-test-router-20260711-030405.tar.gz ../escape unrelated.txt openwrt-other-router-20260701-030405.tar.gz' \
	TEST_LOCAL_ENABLED=1 TEST_LOCAL_PATH="$tmp/backups" TEST_LOCAL_KEEP=7 \
	TEST_SFTP_ENABLED=1 TEST_SFTP_KEEP=2 run_backend
grep -qx 'state=success' "$tmp/status"
grep -qx 'local_result=success' "$tmp/status"
grep -qx 'sftp_result=success' "$tmp/status"
grep -qx 'rm openwrt-test-router-20260709-030405.tar.gz' "$tmp/lftp.batch"
! grep -q '^rm .*escape\|^rm unrelated\|^rm openwrt-other' "$tmp/lftp.batch"

printf '%s\n' 'PRIVATE KEY MATERIAL' >"$tmp/secrets/id_backup"
chmod 600 "$tmp/secrets/id_backup"
TEST_SFTP_AUTH=key TEST_SFTP_KEEP=0 TEST_LOCAL_ENABLED=0 TEST_SFTP_ENABLED=1 run_backend
grep -q -- '-i .*id_backup' "$tmp/lftp.batch"
grep -q 'BatchMode=yes' "$tmp/lftp.batch"

TEST_CONNECT_TIMEOUT=23 TEST_TRANSFER_TIMEOUT=456 TEST_SFTP_AUTH=password \
	TEST_SFTP_KEEP=0 TEST_LOCAL_ENABLED=0 TEST_SFTP_ENABLED=1 run_backend
grep -q 'ConnectTimeout=23' "$tmp/lftp.batch"
grep -q '^set net:timeout 456$' "$tmp/lftp.batch"

rm -f "$tmp/lftp.log" "$tmp/logger.log"
if TEST_LFTP_FAIL=1 TEST_LOCAL_ENABLED=1 TEST_SFTP_ENABLED=1 run_backend; then
	echo 'partial SFTP failure unexpectedly returned success' >&2
	exit 1
fi
grep -qx 'state=partial' "$tmp/status"
grep -qx 'local_result=success' "$tmp/status"
grep -qx 'sftp_result=failed' "$tmp/status"
! grep -q '^rm ' "$tmp/lftp.batch"

: >"$tmp/not-a-directory"
if TEST_LOCAL_ENABLED=1 TEST_LOCAL_PATH="$tmp/not-a-directory/backups" \
	TEST_SFTP_ENABLED=1 TEST_LFTP_FAIL=0 run_backend 2>"$tmp/local-fail.err"; then
	echo 'partial local failure unexpectedly returned success' >&2
	exit 1
fi
grep -qx 'state=partial' "$tmp/status"
grep -qx 'local_result=failed' "$tmp/status"
grep -qx 'sftp_result=success' "$tmp/status"
grep -q '^put ' "$tmp/lftp.batch"

if grep -R 'S3cret-marker' "$tmp/status" "$tmp/lftp.log" "$tmp/logger.log" 2>/dev/null; then
	echo 'secret leaked' >&2
	exit 1
fi

fingerprint=$(SB_SSH_KEYSCAN="$tmp/bin/ssh-keyscan" SB_SSH_KEYGEN="$tmp/bin/ssh-keygen" SB_SECRET_DIR="$tmp/untrusted-secrets" \
	TEST_SFTP_HOST=backup.example TEST_SFTP_PORT=22 SB_UCI="$tmp/bin/uci" \
	sh "$ROOT/root/usr/sbin/scheduled-backup" test-sftp)
[ -n "$fingerprint" ]
printf '%s\n' "$fingerprint" | grep -qx 'result=untrusted'
fingerprint=$(printf '%s\n' "$fingerprint" | sed -n 's/^fingerprints=\([^[:space:]]*\).*/\1/p')
verified=$(SB_SSH_KEYSCAN="$tmp/bin/ssh-keyscan" SB_SSH_KEYGEN="$tmp/bin/ssh-keygen" SB_SECRET_DIR="$tmp/secrets" \
	SB_LFTP="$tmp/bin/lftp" TEST_LFTP_LOG="$tmp/lftp.log" TEST_LFTP_BATCH="$tmp/lftp.batch" \
	TEST_SFTP_HOST=backup.example TEST_SFTP_PORT=22 SB_UCI="$tmp/bin/uci" sh "$ROOT/root/usr/sbin/scheduled-backup" test-sftp)
[ "$verified" = 'result=verified' ]
grep -q '^cd "/remote/backups"$' "$tmp/lftp.batch"
! grep -q '^put \|^mv \|^rm ' "$tmp/lftp.batch"
SB_SSH_KEYSCAN="$tmp/bin/ssh-keyscan" SB_SSH_KEYGEN="$tmp/bin/ssh-keygen" SB_SECRET_DIR="$tmp/trust-secrets" \
	TEST_SFTP_HOST=backup.example TEST_SFTP_PORT=22 SB_UCI="$tmp/bin/uci" \
	sh "$ROOT/root/usr/sbin/scheduled-backup" trust-host "$fingerprint"
[ "$(stat -f '%Lp' "$tmp/trust-secrets/known_hosts" 2>/dev/null || stat -c '%a' "$tmp/trust-secrets/known_hosts")" = 600 ]
TEST_KEYSCAN_OUTPUT='backup.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILfv9C8uapQbMWzHhO7O89scQjLT4JQ5xQ3ZmxhmVpRA' \
	SB_SSH_KEYSCAN="$tmp/bin/ssh-keyscan" SB_SECRET_DIR="$tmp/trust-secrets" \
	SB_SSH_KEYGEN="$tmp/bin/ssh-keygen" \
	TEST_SFTP_HOST=backup.example TEST_SFTP_PORT=22 SB_UCI="$tmp/bin/uci" \
	sh "$ROOT/root/usr/sbin/scheduled-backup" test-sftp >"$tmp/changed.out" 2>"$tmp/changed.err" && {
	echo 'changed fingerprint unexpectedly accepted' >&2
	exit 1
}
grep -q 'host key changed' "$tmp/changed.err"

multi_output=$(TEST_KEYSCAN_OUTPUT='backup.example ssh-ed25519 KEY-A
backup.example ssh-rsa KEY-B' SB_SSH_KEYSCAN="$tmp/bin/ssh-keyscan" \
	SB_SSH_KEYGEN="$tmp/bin/ssh-keygen" SB_SECRET_DIR="$tmp/multi-secrets" \
	TEST_SFTP_HOST=backup.example TEST_SFTP_PORT=22 SB_UCI="$tmp/bin/uci" \
	sh "$ROOT/root/usr/sbin/scheduled-backup" test-sftp)
printf '%s\n' "$multi_output" | grep -qx 'fingerprints=SHA256:key-a[[:space:]]backup.example ssh-ed25519 KEY-A'
printf '%s\n' "$multi_output" | grep -qx 'fingerprints=SHA256:key-b[[:space:]]backup.example ssh-rsa KEY-B'
TEST_KEYSCAN_OUTPUT='backup.example ssh-ed25519 KEY-A
backup.example ssh-rsa KEY-B' SB_SSH_KEYSCAN="$tmp/bin/ssh-keyscan" \
	SB_SSH_KEYGEN="$tmp/bin/ssh-keygen" SB_SECRET_DIR="$tmp/multi-secrets" \
	TEST_SFTP_HOST=backup.example TEST_SFTP_PORT=22 SB_UCI="$tmp/bin/uci" \
	sh "$ROOT/root/usr/sbin/scheduled-backup" trust-host SHA256:key-b
grep -qx 'backup.example ssh-rsa KEY-B' "$tmp/multi-secrets/known_hosts"
! grep -q 'KEY-A' "$tmp/multi-secrets/known_hosts"
if TEST_KEYSCAN_OUTPUT='backup.example ssh-ed25519 KEY-A' \
	SB_SSH_KEYSCAN="$tmp/bin/ssh-keyscan" SB_SSH_KEYGEN="$tmp/bin/ssh-keygen" \
	SB_SECRET_DIR="$tmp/no-match-secrets" TEST_SFTP_HOST=backup.example \
	TEST_SFTP_PORT=22 SB_UCI="$tmp/bin/uci" \
	sh "$ROOT/root/usr/sbin/scheduled-backup" trust-host SHA256:not-present 2>"$tmp/no-match.err"; then
	echo 'unknown fingerprint unexpectedly trusted' >&2
	exit 1
fi
[ ! -e "$tmp/no-match-secrets/known_hosts" ]
if TEST_KEYSCAN_OUTPUT='backup.example ssh-ed25519 KEY-DUP-1
backup.example ssh-rsa KEY-DUP-2' SB_SSH_KEYSCAN="$tmp/bin/ssh-keyscan" \
	SB_SSH_KEYGEN="$tmp/bin/ssh-keygen" SB_SECRET_DIR="$tmp/ambiguous-secrets" \
	TEST_SFTP_HOST=backup.example TEST_SFTP_PORT=22 SB_UCI="$tmp/bin/uci" \
	sh "$ROOT/root/usr/sbin/scheduled-backup" trust-host SHA256:duplicate 2>"$tmp/ambiguous.err"; then
	echo 'ambiguous fingerprint unexpectedly trusted' >&2
	exit 1
fi
[ ! -e "$tmp/ambiguous-secrets/known_hosts" ]

grep -q '+lftp +openssh-client +openssh-client-utils +openssh-keygen' "$ROOT/Makefile"
SB_STATUS="$tmp/status" sh "$ROOT/root/usr/sbin/scheduled-backup" status | grep -q '^state='
[ "$(sh -c '. "$1"; sb_redact saved-secret' sh "$ROOT/root/usr/lib/scheduled-backup/core.sh")" = '[redacted]' ]

rm -rf "$tmp/status-parent"
TEST_LOCAL_ENABLED=1 TEST_LOCAL_PATH="$tmp/backups" TEST_LOCAL_KEEP=7 \
	TEST_SFTP_ENABLED=0 TEST_SYSUPGRADE_FAIL=0 \
	TEST_STATUS="$tmp/status-parent/nested/status" run_backend

grep -qx 'state=success' "$tmp/status-parent/nested/status"

rm -f "$tmp/logger.log"
if TEST_LOCAL_ENABLED=1 TEST_LOCAL_PATH="$tmp/backups" TEST_LOCAL_KEEP=7 \
	TEST_SFTP_ENABLED=0 TEST_SYSUPGRADE_FAIL=0 TEST_STATUS=/dev/null/status run_backend; then
	echo 'unwritable status target unexpectedly returned success' >&2
	exit 1
fi
grep -q 'status' "$tmp/logger.log"

rm -f "$tmp/sysupgrade-started"
TEST_LOCAL_ENABLED=1 TEST_LOCAL_PATH="$tmp/backups" TEST_LOCAL_KEEP=7 \
	TEST_SFTP_ENABLED=0 TEST_SYSUPGRADE_FAIL=0 \
	TEST_SYSUPGRADE_STARTED="$tmp/sysupgrade-started" TEST_SYSUPGRADE_WAIT=1 \
	TEST_BACKUPS="$tmp/backups" TEST_LOGGER_LOG="$tmp/logger.log" \
	TEST_SYSUPGRADE_LOG="$tmp/sysupgrade.log" \
	SB_UCI="$tmp/bin/uci" SB_SYSUPGRADE="$tmp/bin/sysupgrade" \
	SB_TAR=tar SB_LOGGER="$tmp/bin/logger" SB_STATUS="$tmp/status" \
	SB_LOCKDIR="$tmp/lock" SB_TMPBASE="$tmp/tmp" SB_DATE=20260711-030405 \
	sh "$ROOT/root/usr/sbin/scheduled-backup" run &
backend_pid=$!
i=0
while [ ! -e "$tmp/sysupgrade-started" ] && [ "$i" -lt 50 ]; do
	sleep 0.1
	i=$((i + 1))
done
[ -e "$tmp/sysupgrade-started" ]
sysupgrade_pid=$(tail -n 1 "$tmp/sysupgrade.log")
kill -TERM "$backend_pid"
kill -TERM "$sysupgrade_pid" 2>/dev/null || :
if wait "$backend_pid"; then
	echo 'terminated backend unexpectedly returned success' >&2
	exit 1
fi
[ ! -d "$tmp/lock" ]

echo 'backend tests passed'
