#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
activation=${NETWATCH_ACTIVATION_SCRIPT:-$root/packages/netwatch/netwatch/files/usr/libexec/netwatch-upgrade}
init_source=${NETWATCH_INIT_SCRIPT:-$root/packages/netwatch/netwatch/files/etc/init.d/netwatch}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/netwatch-upgrade-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

[ -x "$activation" ] || {
	echo "missing executable Netwatch upgrade activation: $activation" >&2
	exit 1
}

init_events=$tmp/init-events
(
	. "$init_source"
	netwatch_service_enabled() {
		printf 'enabled-check\n' >> "$init_events"
		return 1
	}
	mkdir() { printf 'unexpected-mkdir\n' >> "$init_events"; return 90; }
	PKG_UPGRADE=1
	export PKG_UPGRADE
	start_service
)
printf 'enabled-check\n' > "$tmp/init-events.expected"
diff -u "$tmp/init-events.expected" "$init_events"

make_fakes() {
	case_dir=$1
	mkdir -p "$case_dir/bin" "$case_dir/state"
	: > "$case_dir/events"

	cat > "$case_dir/bin/ucode" <<'SH'
#!/bin/sh
set -eu
[ "$1" = -L ]
[ "$2" = /usr/share/netwatch ]
[ "$3" = /usr/share/netwatch/migrate.uc ] || {
	echo 'migration entry point was not invoked' >&2
	exit 80
}

state=$NETWATCH_TEST_STATE
events=$NETWATCH_TEST_EVENTS
if [ -f "$state/public-password" ]; then
	legacy=$(cat "$state/public-password")
	if [ -f "$state/private-password" ]; then
		private=$(cat "$state/private-password")
		[ "$private" = "$legacy" ] || exit 81
		printf 'private-preserved\n' >> "$events"
	else
		printf '%s' "$legacy" > "$state/private-password"
		printf 'private-committed\n' >> "$events"
	fi
	rm "$state/public-password"
	printf 'public-removed\n' >> "$events"
fi
printf 'migrate-complete\n' >> "$events"
SH

	cat > "$case_dir/bin/init" <<'SH'
#!/bin/sh
set -eu
state=$NETWATCH_TEST_STATE
events=$NETWATCH_TEST_EVENTS
case "$1" in
	enabled)
		printf 'enabled-check\n' >> "$events"
		[ -f "$state/enabled" ]
		;;
	restart)
		printf 'restart\n' >> "$events"
		[ ! -f "$state/public-password" ]
		[ -f "$state/private-password" ]
		printf 'r2-process\n' > "$state/process"
		printf '%s\n' status interfaces check test_email set_password > "$state/rpcs"
		;;
	start)
		echo 'upgrade must force restart, not start' >&2
		exit 82
		;;
	*) exit 83 ;;
esac
SH

	cat > "$case_dir/bin/ubus" <<'SH'
#!/bin/sh
set -eu
state=$NETWATCH_TEST_STATE
events=$NETWATCH_TEST_EVENTS
[ "$1" = -t ] && [ "$2" = 1 ] && [ "$3" = -v ] &&
	[ "$4" = list ] && [ "$5" = netwatch ]
printf 'ubus-probe\n' >> "$events"
[ -f "$state/never-ready" ] && exit 1
attempt=0
[ ! -f "$state/attempt" ] || attempt=$(cat "$state/attempt")
[ "$attempt" -ge 2 ] || exit 1
[ "$(cat "$state/process")" = r2-process ]
for method in status interfaces check test_email set_password; do
	grep -Fxq "$method" "$state/rpcs"
done
sed 's/.*/\t"&":{}/' "$state/rpcs"
SH

	cat > "$case_dir/bin/sleep" <<'SH'
#!/bin/sh
set -eu
[ "$1" = 1 ]
state=$NETWATCH_TEST_STATE
events=$NETWATCH_TEST_EVENTS
attempt=0
[ ! -f "$state/attempt" ] || attempt=$(cat "$state/attempt")
attempt=$((attempt + 1))
printf '%s\n' "$attempt" > "$state/attempt"
printf 'sleep\n' >> "$events"
SH

	chmod +x "$case_dir/bin/ucode" "$case_dir/bin/init" \
		"$case_dir/bin/ubus" "$case_dir/bin/sleep"
}

run_activation() {
	case_dir=$1
	shift
	env NETWATCH_TEST_STATE="$case_dir/state" \
		NETWATCH_TEST_EVENTS="$case_dir/events" "$@" \
		"$activation" "$case_dir/bin/ucode" "$case_dir/bin/init" \
		"$case_dir/bin/ubus" "$case_dir/bin/sleep"
}

offline=$tmp/offline
make_fakes "$offline"
run_activation "$offline" env IPKG_INSTROOT=/offline-image
[ ! -s "$offline/events" ] || {
	echo 'offline image install performed a live-system action' >&2
	exit 1
}

disabled=$tmp/disabled
make_fakes "$disabled"
printf 'existing-private' > "$disabled/state/private-password"
printf 'existing-private' > "$disabled/state/public-password"
run_activation "$disabled" env
[ ! -e "$disabled/state/public-password" ]
[ "$(cat "$disabled/state/private-password")" = existing-private ]
printf '%s\n' \
	'private-preserved' \
	'public-removed' \
	'migrate-complete' \
	'enabled-check' > "$disabled/expected-events"
diff -u "$disabled/expected-events" "$disabled/events"
[ ! -e "$disabled/state/process" ]

enabled=$tmp/enabled
make_fakes "$enabled"
printf 'legacy-password' > "$enabled/state/public-password"
: > "$enabled/state/enabled"
printf 'r1-process' > "$enabled/state/process"
run_activation "$enabled" env
[ ! -e "$enabled/state/public-password" ]
[ "$(cat "$enabled/state/private-password")" = legacy-password ]
[ "$(cat "$enabled/state/process")" = r2-process ]
printf '%s\n' status interfaces check test_email set_password > "$enabled/expected-rpcs"
diff -u "$enabled/expected-rpcs" "$enabled/state/rpcs"
printf '%s\n' \
	'private-committed' \
	'public-removed' \
	'migrate-complete' \
	'enabled-check' \
	'restart' \
	'ubus-probe' \
	'sleep' \
	'ubus-probe' \
	'sleep' \
	'ubus-probe' > "$enabled/expected-events"
diff -u "$enabled/expected-events" "$enabled/events"

timeout=$tmp/timeout
make_fakes "$timeout"
printf 'legacy-password' > "$timeout/state/public-password"
: > "$timeout/state/enabled"
: > "$timeout/state/never-ready"
if run_activation "$timeout" env >/dev/null 2>&1; then
	echo 'upgrade activation succeeded without a ready Netwatch ubus object' >&2
	exit 1
fi
[ "$(grep -c '^ubus-probe$' "$timeout/events")" -eq 30 ]
[ "$(grep -c '^sleep$' "$timeout/events")" -eq 29 ]

echo 'upgrade activation tests passed'
