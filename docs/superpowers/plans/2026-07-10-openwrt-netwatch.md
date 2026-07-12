# OpenWrt Netwatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify installable `netwatch` and `luci-app-netwatch` APK packages for OpenWrt 25.12.5 x86/64, with ping and TCP monitoring, incident-aware email alerts, and a complete LuCI interface.

**Architecture:** A procd-supervised ucode daemon owns scheduling, probes, state transitions, SMTP delivery, and a restricted ubus API. Pure ucode modules contain validation, parsing, state, scheduling, and message logic so they can be tested independently; JavaScript LuCI views use UCI and RPC to configure and display the service.

**Tech Stack:** OpenWrt 25.12.5 APK SDK, ucode, procd, UCI, ubus/rpcd, BusyBox ping, ucode socket/uloop modules, msmtp with GnuTLS, JavaScript LuCI forms and polling, POSIX shell, Docker `linux/amd64` build container.

## Global Constraints

- Target `DISTRIB_RELEASE='25.12.5'`, `DISTRIB_TARGET='x86/64'`, and `DISTRIB_ARCH='x86_64'`.
- Produce APK packages, not legacy IPK packages.
- Runtime and LuCI packages are script/resource-only and declare architecture `all`.
- DHCP leases are the only automatic target source; manual IPv4, IPv6, and hostname targets remain supported.
- Port monitoring is TCP connect only.
- Ping health may include packet-loss and average-RTT thresholds.
- Default check interval is 60 seconds and default failure confirmation is 3 consecutive failures.
- Failure email limits reset after recovery; recovery notification is one-time and does not consume the failure limit.
- Recipients use global defaults with per-monitor override.
- Active state is RAM-backed and does not persist across router reboot.
- SMTP certificate verification remains enabled; no insecure verification toggle is exposed.
- No generic command execution is reachable through ubus or LuCI.
- The current workspace uses `work/git-metadata` as its Git directory. Commit with `git --git-dir=work/git-metadata --work-tree=.`.

## File Structure

```text
LICENSE                                      GPL-2.0-only license
README.md                                    Build, install, configure, troubleshoot, uninstall
netwatch/Makefile                            Runtime OpenWrt package recipe
netwatch/files/etc/config/netwatch           Default UCI configuration
netwatch/files/etc/init.d/netwatch            procd service and reload trigger
netwatch/files/usr/share/netwatch/config.uc   UCI normalization and validation
netwatch/files/usr/share/netwatch/ping.uc     BusyBox ping command construction and parsing
netwatch/files/usr/share/netwatch/state.uc    Incident state machine
netwatch/files/usr/share/netwatch/alerts.uc   Alert timing and counters
netwatch/files/usr/share/netwatch/message.uc  SMTP config and RFC 5322 message rendering
netwatch/files/usr/share/netwatch/probe.uc    Async ping/TCP execution
netwatch/files/usr/share/netwatch/store.uc    Atomic runtime-state persistence and public status
netwatch/files/usr/share/netwatch/netwatchd.uc Scheduler, UCI reload, ubus, and mail orchestration
luci-app-netwatch/Makefile                    LuCI package recipe
luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/status.js
luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/monitors.js
luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js
luci-app-netwatch/root/usr/share/luci/menu.d/luci-app-netwatch.json
luci-app-netwatch/root/usr/share/rpcd/acl.d/luci-app-netwatch.json
luci-app-netwatch/root/usr/share/ucitrack/luci-app-netwatch.json
luci-app-netwatch/po/templates/netwatch.pot    Translation template
tests/lib/test.uc                             Minimal ucode test helpers
tests/unit/config_test.uc                     Validation and defaults
tests/unit/ping_test.uc                       Ping fixtures and thresholds
tests/unit/state_test.uc                      Incident transitions
tests/unit/alerts_test.uc                     Email timing and caps
tests/unit/message_test.uc                    Header, recipient, and SMTP rendering
tests/fixtures/ping/*.txt                     BusyBox ping output fixtures
tests/run-unit.sh                             Host-ucode test entry point
tests/static.sh                               JSON, JS, shell, permissions, and unsafe-pattern checks
tools/sdk/Dockerfile                          Reproducible Linux x86_64 build environment
scripts/fetch-sdk.sh                          Download and checksum OpenWrt SDK
scripts/in-sdk.sh                             Run commands against mounted SDK in Docker
scripts/build-packages.sh                     Install feed links and build both APKs
scripts/package-output.sh                     Copy APKs/source archive and write SHA256SUMS
```

---

### Task 1: Reproducible SDK and Package Skeleton

**Files:**
- Create: `LICENSE`
- Create: `tools/sdk/Dockerfile`
- Create: `scripts/fetch-sdk.sh`
- Create: `scripts/in-sdk.sh`
- Create: `netwatch/Makefile`
- Create: `netwatch/files/etc/config/netwatch`
- Create: `netwatch/files/etc/init.d/netwatch`
- Create: `luci-app-netwatch/Makefile`
- Create: `tests/static.sh`

**Interfaces:**
- Consumes: Official SDK URL and SHA-256 from the 25.12.5 x86/64 download index.
- Produces: `scripts/in-sdk.sh COMMAND [ARGUMENTS]`, an extracted SDK at `work/sdk`, and two discoverable package recipes.

- [ ] **Step 1: Write the failing skeleton checks**

Create `tests/static.sh` with executable mode and these initial assertions:

```sh
#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail=0

require_file() {
	if [ ! -f "$root/$1" ]; then
		echo "missing: $1" >&2
		fail=1
	fi
}

require_file netwatch/Makefile
require_file netwatch/files/etc/config/netwatch
require_file netwatch/files/etc/init.d/netwatch
require_file luci-app-netwatch/Makefile
require_file tools/sdk/Dockerfile
require_file scripts/fetch-sdk.sh
require_file scripts/in-sdk.sh

exit "$fail"
```

- [ ] **Step 2: Run the check and verify it fails**

Run: `chmod +x tests/static.sh && ./tests/static.sh`

Expected: nonzero exit with one `missing:` line for every package and SDK file.

- [ ] **Step 3: Add the SDK bootstrap and package recipes**

Create `tools/sdk/Dockerfile`:

```dockerfile
FROM --platform=linux/amd64 debian:bookworm-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential ca-certificates file flex bison gawk gettext git libncurses-dev \
    libssl-dev python3 python3-distutils python3-pyelftools rsync unzip wget xz-utils zstd \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
```

Create `scripts/fetch-sdk.sh` using these exact constants:

```sh
#!/bin/sh
set -eu
version=25.12.5
archive=openwrt-sdk-25.12.5-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
sha256=0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c
url=https://downloads.openwrt.org/releases/$version/targets/x86/64/$archive
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$root/work/downloads" "$root/work/sdk"
test -f "$root/work/downloads/$archive" || curl -fL "$url" -o "$root/work/downloads/$archive"
printf '%s  %s\n' "$sha256" "$root/work/downloads/$archive" | shasum -a 256 -c -
rm -rf "$root/work/sdk"/*
tar --zstd -xf "$root/work/downloads/$archive" -C "$root/work/sdk" --strip-components=1
```

Create `scripts/in-sdk.sh`:

```sh
#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
docker image inspect netwatch-openwrt-sdk:25.12.5 >/dev/null 2>&1 || \
	docker build --platform linux/amd64 -t netwatch-openwrt-sdk:25.12.5 "$root/tools/sdk"
exec docker run --rm --platform linux/amd64 \
	-v "$root:/src" -v "$root/work/sdk:/sdk" \
	-w /src netwatch-openwrt-sdk:25.12.5 "$@"
```

Create the runtime Makefile with `PKGARCH:=all`, empty compile phase, conffile declaration, and dependencies `+ucode +ucode-mod-fs +ucode-mod-log +ucode-mod-socket +ucode-mod-ubus +ucode-mod-uci +ucode-mod-uloop +msmtp +ca-bundle`. Install `/etc/config/netwatch`, `/etc/init.d/netwatch`, and all `.uc` files from `/usr/share/netwatch`.

Create the LuCI Makefile with:

```make
include $(TOPDIR)/rules.mk
LUCI_TITLE:=LuCI support for Netwatch
LUCI_DEPENDS:=+luci-base +rpcd-mod-luci +netwatch
LUCI_PKGARCH:=all
PKG_LICENSE:=GPL-2.0-only
include $(TOPDIR)/feeds/luci/luci.mk
```

The default UCI file must contain named `main` and `smtp` sections with `startup_grace '60'`, `mail_retry_backoff '300'`, SMTP port `587`, and TLS mode `starttls`. Do not include an enabled sample monitor.

The init script must use `USE_PROCD=1`, `START=95`, start `/usr/bin/ucode -L '/usr/share/netwatch/*.uc' /usr/share/netwatch/netwatchd.uc`, enable respawn, declare `/etc/config/netwatch` as a watched file, and send `HUP` from `reload_service()`.

- [ ] **Step 4: Verify the skeleton and SDK**

Run:

```sh
chmod +x scripts/fetch-sdk.sh scripts/in-sdk.sh netwatch/files/etc/init.d/netwatch
./tests/static.sh
./scripts/fetch-sdk.sh
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk --version
```

Expected: static check exits 0, SDK checksum reports `OK`, and the final command prints the APK Tools version.

- [ ] **Step 5: Commit**

```sh
git --git-dir=work/git-metadata --work-tree=. add LICENSE tools scripts netwatch luci-app-netwatch tests/static.sh
git --git-dir=work/git-metadata --work-tree=. commit -m "build: scaffold OpenWrt netwatch packages"
```

---

### Task 2: UCI Validation and Normalization

**Files:**
- Create: `tests/lib/test.uc`
- Create: `tests/run-unit.sh`
- Create: `tests/unit/config_test.uc`
- Create: `netwatch/files/usr/share/netwatch/config.uc`

**Interfaces:**
- Consumes: Raw UCI dictionaries and section IDs.
- Produces: `valid_target(string) -> bool`, `normalize_global(object) -> object`, `normalize_smtp(object) -> object`, and `normalize_monitor(id, object) -> { ok, value, errors }`.

- [ ] **Step 1: Add test helpers and failing validation tests**

`tests/lib/test.uc` must export `equal(actual, expected, label)`, `truthy(value, label)`, and `deep_equal(actual, expected, label)`; each failure throws a message containing the label.

`tests/unit/config_test.uc` must assert:

```javascript
import { equal, truthy } from 'test';
import { valid_target, normalize_monitor } from 'config';

truthy(valid_target('192.0.2.1'), 'IPv4 accepted');
truthy(valid_target('2001:db8::1'), 'IPv6 accepted');
truthy(valid_target('router.example'), 'hostname accepted');
equal(valid_target('-c 1;reboot'), false, 'shell syntax rejected');

let ping = normalize_monitor('cfg001', {
	enabled: '1', name: 'Gateway', target: '192.0.2.1', type: 'ping'
});
truthy(ping.ok, 'minimal ping monitor valid');
equal(ping.value.interval, 60, 'default interval');
equal(ping.value.failures, 3, 'default failure count');
equal(ping.value.packet_count, 3, 'default packet count');

let tcp = normalize_monitor('cfg002', {
	target: 'server.example', type: 'tcp', port: '443', repeat_interval: '600', max_alerts: '3'
});
truthy(tcp.ok, 'TCP monitor valid');
equal(tcp.value.port, 443, 'port normalized');

equal(normalize_monitor('bad', { target: 'x', type: 'tcp', port: '0' }).ok, false, 'zero port rejected');
equal(normalize_monitor('bad', { target: 'x', type: 'ping', max_loss: '101' }).ok, false, 'loss over 100 rejected');
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `./tests/run-unit.sh tests/unit/config_test.uc`

Expected: FAIL because module `config` does not exist.

- [ ] **Step 3: Implement normalization**

Implement conservative targets with `substr(value, 0, 1) != '-' && match(value, /^[A-Za-z0-9_.:%-]+$/)`, reject CR/LF everywhere, and normalize numeric fields with these ranges:

```javascript
const LIMITS = {
	interval: [5, 86400, 60], timeout: [1, 60, 5], failures: [1, 100, 3],
	packet_count: [1, 20, 3], max_loss: [0, 100, 0], max_rtt: [1, 60000, 500],
	initial_delay: [0, 604800, 0], max_alerts: [1, 1000, 1]
};
const REPEAT = [0, 600, 1800, 3600];
const TLS = ['none', 'starttls', 'tls'];
```

`normalize_monitor()` must return all common fields plus ping-only or TCP-only fields, convert UCI booleans to real booleans, accept only the four repeat values, and preserve errors as user-readable strings without secrets.

- [ ] **Step 4: Run validation tests**

Run: `./tests/run-unit.sh tests/unit/config_test.uc`

Expected: all assertions pass and exit 0.

- [ ] **Step 5: Commit**

```sh
git --git-dir=work/git-metadata --work-tree=. add tests/lib tests/run-unit.sh tests/unit/config_test.uc netwatch/files/usr/share/netwatch/config.uc
git --git-dir=work/git-metadata --work-tree=. commit -m "feat: validate netwatch configuration"
```

---

### Task 3: Ping Parsing and Probe Execution

**Files:**
- Create: `tests/fixtures/ping/ipv4-ok.txt`
- Create: `tests/fixtures/ping/ipv6-loss.txt`
- Create: `tests/fixtures/ping/total-loss.txt`
- Create: `tests/unit/ping_test.uc`
- Create: `netwatch/files/usr/share/netwatch/ping.uc`
- Create: `netwatch/files/usr/share/netwatch/probe.uc`

**Interfaces:**
- Consumes: Validated normalized monitors.
- Produces: `parse_ping(output, exit_code, monitor) -> ProbeResult` and `start_probe(monitor, callback) -> bool`, where `ProbeResult` has `{ ok, reason, loss, avg_rtt, detail }`.

- [ ] **Step 1: Write ping fixtures and failing parser tests**

Use authentic BusyBox-style summary lines, including:

```text
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 9.100/12.500/18.000 ms
```

and:

```text
3 packets transmitted, 2 packets received, 33% packet loss
round-trip min/avg/max = 22.000/44.000/66.000 ms
```

Tests must cover healthy, loss-threshold exceeded, RTT-threshold exceeded, total loss, malformed output, and nonzero exit with usable partial statistics.

```javascript
let result = parse_ping(ok_text, 0, { check_loss: true, max_loss: 10, check_rtt: true, max_rtt: 100 });
equal(result.ok, true, 'healthy ping');
equal(result.loss, 0, 'zero loss');
equal(result.avg_rtt, 12.5, 'average RTT');

result = parse_ping(loss_text, 1, { check_loss: true, max_loss: 20, check_rtt: false });
equal(result.ok, false, 'partial loss threshold');
equal(result.reason, 'packet_loss', 'loss reason');
```

- [ ] **Step 2: Verify parser tests fail**

Run: `./tests/run-unit.sh tests/unit/ping_test.uc`

Expected: FAIL because module `ping` does not exist.

- [ ] **Step 3: Implement parser and asynchronous probes**

`parse_ping()` must accept both `packets received` and `received` variants, parse decimal RTTs, prefer threshold reasons over generic exit-code failure when metrics exist, and return `reason: 'unreachable'` for 100% loss.

`probe.uc` must:

- Run ping inside `uloop.task()` so the daemon event loop stays responsive.
- Select `/bin/ping` or `/bin/ping6` using `:` in the validated target.
- Build only fixed numeric flags and a shell-quoted validated target.
- Use `socket.connect(target, port, { socktype: socket.SOCK_STREAM }, timeout_ms)` for TCP inside a task.
- Return normalized reasons `dns`, `refused`, `timeout`, or `connect_failed` without exposing raw unbounded stderr.
- Send exactly one result to the parent callback and track a task timeout.

- [ ] **Step 4: Run unit and syntax checks**

Run:

```sh
./tests/run-unit.sh tests/unit/ping_test.uc
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/ucode -c netwatch/files/usr/share/netwatch/ping.uc
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/ucode -c netwatch/files/usr/share/netwatch/probe.uc
```

Expected: tests pass and both ucode files compile without diagnostics.

- [ ] **Step 5: Commit**

```sh
git --git-dir=work/git-metadata --work-tree=. add tests/fixtures tests/unit/ping_test.uc netwatch/files/usr/share/netwatch/ping.uc netwatch/files/usr/share/netwatch/probe.uc
git --git-dir=work/git-metadata --work-tree=. commit -m "feat: add ping and TCP probes"
```

---

### Task 4: Incident State Machine and Alert Schedule

**Files:**
- Create: `tests/unit/state_test.uc`
- Create: `tests/unit/alerts_test.uc`
- Create: `netwatch/files/usr/share/netwatch/state.uc`
- Create: `netwatch/files/usr/share/netwatch/alerts.uc`

**Interfaces:**
- Consumes: `ProbeResult`, normalized monitor, and integer Unix timestamps.
- Produces: `new_state(id)`, `apply_result(state, monitor, result, now) -> transition`, `due_alert(state, monitor, now) -> string|null`, `mail_succeeded(state, kind, now)`, and `mail_failed(state, now, retry_backoff)`.

- [ ] **Step 1: Write failing state tests**

Test this exact sequence for a monitor with `failures: 3`:

```javascript
let s = new_state('cfg001');
equal(apply_result(s, monitor, good, 100), 'became_healthy', 'initial success');
equal(apply_result(s, monitor, bad, 200), 'pending', 'first failure');
equal(apply_result(s, monitor, bad, 260), 'pending', 'second failure');
equal(apply_result(s, monitor, bad, 320), 'opened', 'third failure opens');
equal(s.incident_started, 320, 'incident timestamp');
equal(apply_result(s, monitor, good, 380), 'recovered', 'recovery transition');
equal(s.failure_emails, 0, 'new healthy state clears incident count');
```

Also test that a pending success clears consecutive failures, disabled monitors remain `disabled`, and an unchanged failure does not reopen an incident.

- [ ] **Step 2: Write failing scheduling tests**

Cover first alert at `incident_started + initial_delay`, one-time mode, 10/30/60-minute repeats, `max_alerts`, failed-send backoff, recovery eligibility only after one successful failure email, and reset on the next incident.

- [ ] **Step 3: Verify both tests fail**

Run: `./tests/run-unit.sh tests/unit/state_test.uc tests/unit/alerts_test.uc`

Expected: FAIL because `state` and `alerts` modules do not exist.

- [ ] **Step 4: Implement pure state and scheduling functions**

The state object must contain these stable keys:

```javascript
{
	id: id, status: 'unknown', consecutive_failures: 0,
	last_check: null, last_result: null, incident_started: null,
	failure_emails: 0, last_email: null, next_mail_attempt: null,
	recovery_eligible: false, recovery_pending: null,
	busy: false, config_error: null
}
```

On recovery, `apply_result()` stores `{ incident_started, recovered_at, failure_emails, last_result }` in `recovery_pending` only when `recovery_eligible` is true, then clears active-incident counters. `due_alert()` returns `failure` only while failed and below the cap, and returns `recovery` only while `recovery_pending` exists. `mail_succeeded(state, 'recovery', now)` clears `recovery_pending`; `mail_failed()` preserves counters and advances `next_mail_attempt` by the retry backoff.

- [ ] **Step 5: Run tests and commit**

Run: `./tests/run-unit.sh tests/unit/state_test.uc tests/unit/alerts_test.uc`

Expected: all state and schedule assertions pass.

```sh
git --git-dir=work/git-metadata --work-tree=. add tests/unit/state_test.uc tests/unit/alerts_test.uc netwatch/files/usr/share/netwatch/state.uc netwatch/files/usr/share/netwatch/alerts.uc
git --git-dir=work/git-metadata --work-tree=. commit -m "feat: track incidents and alert schedules"
```

---

### Task 5: SMTP Configuration and Message Rendering

**Files:**
- Create: `tests/unit/message_test.uc`
- Create: `netwatch/files/usr/share/netwatch/message.uc`

**Interfaces:**
- Consumes: Normalized SMTP/global/monitor configuration, state, router hostname, kind, timestamp.
- Produces: `split_recipients(string) -> string[]`, `render_msmtp(smtp) -> string`, and `render_message(kind, context) -> string`.

- [ ] **Step 1: Write failing security and rendering tests**

Tests must assert that:

- `a@example.test, b@example.test` becomes two recipients.
- CR, LF, and an empty address are rejected.
- STARTTLS renders `tls on` and `tls_starttls on`.
- Implicit TLS renders `tls on` and `tls_starttls off`.
- Authentication lines appear only when both username and password exist.
- The password is present only in the restricted msmtp config, not the message.
- Failure subjects start `[Netwatch DOWN]` and recovery subjects start `[Netwatch RECOVERED]`.
- Failure bodies include target, reason, incident time, duration, and `Alert 2 of 3`.

- [ ] **Step 2: Verify tests fail**

Run: `./tests/run-unit.sh tests/unit/message_test.uc`

Expected: FAIL because module `message` does not exist.

- [ ] **Step 3: Implement renderers**

Use RFC 5322 headers `From`, `To`, `Date`, `Message-ID`, `Subject`, `MIME-Version`, `Content-Type: text/plain; charset=UTF-8`, and `Content-Transfer-Encoding: 8bit`. Strip or reject control characters before rendering. Generate msmtp settings with `tls_trust_file /etc/ssl/certs/ca-certificates.crt`, `syslog LOG_MAIL`, and no credential command-line arguments.

- [ ] **Step 4: Run tests and secret scan**

Run:

```sh
./tests/run-unit.sh tests/unit/message_test.uc
! rg -n "password.*(print|warn|log)|status.*password" netwatch/files/usr/share/netwatch
```

Expected: tests pass and the scan prints nothing.

- [ ] **Step 5: Commit**

```sh
git --git-dir=work/git-metadata --work-tree=. add tests/unit/message_test.uc netwatch/files/usr/share/netwatch/message.uc
git --git-dir=work/git-metadata --work-tree=. commit -m "feat: render secure SMTP notifications"
```

---

### Task 6: Runtime Store, Daemon, ubus, procd, and msmtp

**Files:**
- Create: `netwatch/files/usr/share/netwatch/store.uc`
- Create: `netwatch/files/usr/share/netwatch/netwatchd.uc`
- Modify: `netwatch/files/etc/init.d/netwatch`
- Modify: `tests/static.sh`

**Interfaces:**
- Consumes: All pure modules from Tasks 2-5 and actual UCI/ubus/uloop/fs/log facilities.
- Produces: ubus object `netwatch` with `status {}`, `check { id: string }`, and `test_email { recipient?: string }`.

- [ ] **Step 1: Extend static tests with daemon contracts**

Add checks that compile every `.uc`, ensure init script passes `sh -n`, and require these literal declarations in `netwatchd.uc`:

```text
conn.publish('netwatch'
status:
check:
test_email:
uloop.signal('HUP'
```

Also reject `system(`, `eval(`, generic ubus command parameters, and password fields in public-status construction.

- [ ] **Step 2: Verify daemon contract check fails**

Run: `./tests/static.sh`

Expected: nonzero exit because `store.uc` and `netwatchd.uc` are absent.

- [ ] **Step 3: Implement atomic store and daemon orchestration**

`store.uc` must write `/var/run/netwatch/status.json.tmp`, `fsync`/close it, rename it to `status.json`, and expose only:

```javascript
{
	version: 1, daemon_started, last_reload, mail_error,
	monitors: states.map((s) => ({
		id: s.id, status: s.status, last_check: s.last_check,
		last_result: s.last_result, consecutive_failures: s.consecutive_failures,
		incident_started: s.incident_started, failure_emails: s.failure_emails,
		config_error: s.config_error
	}))
}
```

`netwatchd.uc` must:

- Initialize uloop and connect to ubus.
- Load named global/SMTP sections and every monitor section through `uci.cursor()`.
- Retain state objects by stable section ID on HUP reload.
- Use one scheduler timer to start due, enabled, nonbusy checks.
- Mark a monitor busy until its task callback returns.
- Apply probe results, schedule/send mail, persist public status, and log transitions through `ucode-mod-log`.
- Write `/var/run/netwatch/msmtprc` with mode `0600`.
- Send mail through a fixed `msmtp --file=/var/run/netwatch/msmtprc --read-envelope-from --read-recipients` command, writing the sanitized RFC 5322 message to stdin.
- Increment counters only after exit code zero.
- Publish exact ubus argument schemas: `status` has none, `check` has `{ id: '' }`, and `test_email` has `{ recipient: '' }`.
- Return `{ ok: false, error: 'mail delivery failed' }` for SMTP failures and similarly fixed, secret-free strings for validation failures; never throw a secret-bearing error across ubus.

- [ ] **Step 4: Run all unit and static tests**

Run:

```sh
./tests/run-unit.sh tests/unit/config_test.uc tests/unit/ping_test.uc tests/unit/state_test.uc tests/unit/alerts_test.uc tests/unit/message_test.uc
./tests/static.sh
```

Expected: every unit file passes and static checks exit 0.

- [ ] **Step 5: Commit**

```sh
git --git-dir=work/git-metadata --work-tree=. add netwatch/files/usr/share/netwatch netwatch/files/etc/init.d/netwatch tests/static.sh
git --git-dir=work/git-metadata --work-tree=. commit -m "feat: run netwatch daemon and ubus service"
```

---

### Task 7: LuCI Package Metadata and Configuration Views

**Files:**
- Create: `luci-app-netwatch/root/usr/share/luci/menu.d/luci-app-netwatch.json`
- Create: `luci-app-netwatch/root/usr/share/rpcd/acl.d/luci-app-netwatch.json`
- Create: `luci-app-netwatch/root/usr/share/ucitrack/luci-app-netwatch.json`
- Create: `luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/monitors.js`
- Create: `luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js`
- Modify: `tests/static.sh`

**Interfaces:**
- Consumes: UCI package `netwatch`, `luci-rpc.getDHCPLeases`, and `netwatch.test_email`.
- Produces: Services > Netwatch menu with Monitors and Email pages; least-privilege ACL.

- [ ] **Step 1: Add failing metadata and view checks**

Require three menu children, JSON parse success, ACL read access to `netwatch.status` and `luci-rpc.getDHCPLeases`, ACL write access to `netwatch.check`, `netwatch.test_email`, and UCI `netwatch`, plus `node --check` for each view.

- [ ] **Step 2: Verify checks fail**

Run: `./tests/static.sh`

Expected: failures for missing LuCI JSON and JavaScript files.

- [ ] **Step 3: Implement menu, ACL, and UCI reload tracking**

Menu paths must be:

```json
{
  "admin/services/netwatch": { "title": "Netwatch", "order": 85, "action": { "type": "firstchild" }, "depends": { "acl": [ "luci-app-netwatch" ] } },
  "admin/services/netwatch/status": { "title": "Status", "order": 10, "action": { "type": "view", "path": "netwatch/status" } },
  "admin/services/netwatch/monitors": { "title": "Monitors", "order": 20, "action": { "type": "view", "path": "netwatch/monitors" } },
  "admin/services/netwatch/email": { "title": "Email", "order": 30, "action": { "type": "view", "path": "netwatch/email" } }
}
```

Use `{"config":"netwatch","init":"netwatch"}` for ucitrack.

- [ ] **Step 4: Implement Monitors and Email forms**

`monitors.js` must use `form.GridSection('monitor')`, stable nonanonymous sections, conditional ping/TCP fields, numeric datatypes matching Task 2, recipient override, and recovery checkbox. The initial-delay selector must offer `0` (immediate), `300` (5 minutes), `600` (10 minutes), `900` (15 minutes), `1800` (30 minutes), and `3600` (1 hour). The repeat selector must offer `0` (one time), `600` (every 10 minutes), `1800` (every 30 minutes), and `3600` (every hour). The maximum-email field is required and uses datatype `range(1,1000)`.

Declare DHCP RPC exactly as:

```javascript
const callDHCPLeases = rpc.declare({
	object: 'luci-rpc', method: 'getDHCPLeases', expect: { '': {} }
});
```

Load IPv4 `dhcp_leases` and IPv6 `dhcp6_leases`; add each active lease as a target choice labeled with hostname and address while keeping `form.Value` editable.

`email.js` must edit named `main` and `smtp` sections, mask the password, present TLS modes, and declare:

```javascript
const callTestEmail = rpc.declare({
	object: 'netwatch', method: 'test_email', params: [ 'recipient' ]
});
```

The test button must save/apply first, show a spinner, display a sanitized success/error notification, and never read the existing password through RPC.

- [ ] **Step 5: Run static checks and commit**

Run: `./tests/static.sh`

Expected: all JSON and JS checks pass.

```sh
git --git-dir=work/git-metadata --work-tree=. add luci-app-netwatch tests/static.sh
git --git-dir=work/git-metadata --work-tree=. commit -m "feat: configure netwatch from LuCI"
```

---

### Task 8: Live LuCI Status and Check-Now Actions

**Files:**
- Create: `luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/status.js`
- Modify: `tests/static.sh`

**Interfaces:**
- Consumes: `netwatch.status` and `netwatch.check` ubus methods.
- Produces: Polling status table with per-monitor `Check now`.

- [ ] **Step 1: Add failing status-view checks**

Require RPC declarations for object `netwatch`, methods `status` and `check`, a `poll.add()` call, no save handlers, and labels for unknown, healthy, pending, failed, disabled, and invalid configuration.

- [ ] **Step 2: Verify the check fails**

Run: `./tests/static.sh`

Expected: status-view contract failures.

- [ ] **Step 3: Implement the status view**

The view must declare:

```javascript
const callStatus = rpc.declare({ object: 'netwatch', method: 'status', expect: { '': {} } });
const callCheck = rpc.declare({ object: 'netwatch', method: 'check', params: [ 'id' ] });
```

Render a table with Monitor, Target, Test, State, Last check, Result, Incident, and Emails columns. Ping results show loss percentage and average RTT; TCP results show the port and normalized reason. Use `poll.add()` to replace table rows without reloading the page. `Check now` disables and spins until RPC completion, then refreshes status. Set `handleSave`, `handleSaveApply`, and `handleReset` to `null`.

- [ ] **Step 4: Run static checks and commit**

Run: `./tests/static.sh`

Expected: status view and every earlier static assertion pass.

```sh
git --git-dir=work/git-metadata --work-tree=. add luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/status.js tests/static.sh
git --git-dir=work/git-metadata --work-tree=. commit -m "feat: show live netwatch status in LuCI"
```

---

### Task 9: Documentation, Translations, and Full Source Verification

**Files:**
- Create: `README.md`
- Create: `luci-app-netwatch/po/templates/netwatch.pot`
- Modify: `tests/static.sh`

**Interfaces:**
- Consumes: Complete source tree and final UCI/ubus names.
- Produces: User-operable documentation and a clean source verification run.

- [ ] **Step 1: Add failing documentation checks**

Require README sections `Requirements`, `Build`, `Install`, `Configure`, `Troubleshooting`, `Upgrade`, and `Uninstall`; require commands using `apk add --allow-untrusted`; require the translation template.

- [ ] **Step 2: Verify documentation checks fail**

Run: `./tests/static.sh`

Expected: failures for missing README and POT file.

- [ ] **Step 3: Write documentation and POT template**

README must include:

- Exact OpenWrt target and release.
- APK installation order: `netwatch` then `luci-app-netwatch`.
- Dependency installation behavior and `apk` command examples.
- LuCI path `Services > Netwatch`.
- SMTP examples for port 587 STARTTLS and port 465 implicit TLS.
- Explanation that active incidents reset after reboot.
- Commands for `/etc/init.d/netwatch restart`, `ubus call netwatch status`, and `logread -e netwatch`.
- Config preservation and uninstall commands.

Create a valid gettext POT header and include each literal passed to the LuCI `_()` translation function in the three Netwatch views. Verify coverage by extracting `_()` literals from the JavaScript and comparing the sorted unique list with POT `msgid` entries in `tests/static.sh`.

- [ ] **Step 4: Run complete source verification**

Run:

```sh
./tests/run-unit.sh tests/unit/config_test.uc tests/unit/ping_test.uc tests/unit/state_test.uc tests/unit/alerts_test.uc tests/unit/message_test.uc
./tests/static.sh
git --git-dir=work/git-metadata --work-tree=. diff --check
```

Expected: all commands exit 0 with no whitespace errors.

- [ ] **Step 5: Commit**

```sh
git --git-dir=work/git-metadata --work-tree=. add README.md luci-app-netwatch/po tests/static.sh
git --git-dir=work/git-metadata --work-tree=. commit -m "docs: document netwatch installation and operation"
```

---

### Task 10: SDK Build, APK Inspection, and User Deliverables

**Files:**
- Create: `scripts/build-packages.sh`
- Create: `scripts/package-output.sh`
- Modify: `README.md`
- Generate: `outputs/netwatch_1.0.0-r1_all.apk`
- Generate: `outputs/luci-app-netwatch_1.0.0-r1_all.apk`
- Generate: `outputs/openwrt-netwatch-1.0.0-source.tar.gz`
- Generate: `outputs/SHA256SUMS`

**Interfaces:**
- Consumes: Complete packages and extracted official SDK.
- Produces: Installable APKs, source archive, checksums, and recorded verification evidence.

- [ ] **Step 1: Write build and packaging scripts**

`scripts/build-packages.sh` must run inside the SDK container, create clean symlinks under `/sdk/package/netwatch-feed`, install/update standard feeds, select both packages with `make defconfig`, run package checks where supported, and execute:

```sh
make package/netwatch/clean package/luci-app-netwatch/clean
make package/netwatch/compile package/luci-app-netwatch/compile V=s -j1
```

It must fail if it cannot find exactly one runtime APK and one LuCI APK under `/sdk/bin/packages`.

`scripts/package-output.sh` must copy the two APKs with stable names, create a source archive excluding `.git`, `work`, and `outputs`, then run `shasum -a 256` over all three artifacts into `outputs/SHA256SUMS`.

- [ ] **Step 2: Run the official SDK build**

Run:

```sh
chmod +x scripts/build-packages.sh scripts/package-output.sh
./scripts/in-sdk.sh /src/scripts/build-packages.sh
./scripts/package-output.sh
```

Expected: both package compile targets finish successfully and four files appear in `outputs`.

- [ ] **Step 3: Inspect APK metadata and contents**

Use the SDK `apk` or tar tooling to verify:

- Both package architectures are `all`.
- Runtime dependencies include every ucode module, msmtp, and CA bundle.
- `/etc/config/netwatch` is a conffile.
- Init script is executable.
- LuCI menu, ACL, ucitrack, views, and POT are installed.
- No file is group- or world-writable.
- No SMTP password from test fixtures appears in either APK.

Expected: every assertion succeeds; record the commands and results in a `Build verification` section appended to README.

- [ ] **Step 4: Run final verification from a clean source state**

Run:

```sh
./tests/run-unit.sh tests/unit/config_test.uc tests/unit/ping_test.uc tests/unit/state_test.uc tests/unit/alerts_test.uc tests/unit/message_test.uc
./tests/static.sh
shasum -a 256 -c outputs/SHA256SUMS
git --git-dir=work/git-metadata --work-tree=. diff --check
git --git-dir=work/git-metadata --work-tree=. status --short
```

Expected: tests and checksums pass, diff check is silent, and status lists only intentionally generated ignored outputs.

- [ ] **Step 5: Commit source-side build tooling**

```sh
git --git-dir=work/git-metadata --work-tree=. add scripts/build-packages.sh scripts/package-output.sh README.md
git --git-dir=work/git-metadata --work-tree=. commit -m "build: produce verified OpenWrt APK artifacts"
```

- [ ] **Step 6: Prepare handoff**

Report the two APK paths, source archive, SHA256SUMS, exact test commands and results, SDK version/checksum, and any limitation that could not be exercised without installing on the user’s router. Do not claim live-router validation unless it was actually performed.
