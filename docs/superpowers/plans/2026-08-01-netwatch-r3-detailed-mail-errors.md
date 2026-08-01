# Netwatch r3 Detailed Mail Errors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish and install Netwatch 1.1.0-r3 with a friendly interface target in the monitor grid, reliable automatic alert rendering, and collapsed, detailed, secret-safe mail failure diagnostics.

**Architecture:** Keep probing, alert scheduling, and delivery serialization unchanged. Add a small pure mail-failure module for classification/redaction, a focused delivery-resource module for private stderr/result descriptors, and extend the bounded async mail-test contract with an exact failure object. LuCI renders only that trusted contract through DOM text nodes inside a collapsed native `<details>` element.

**Tech Stack:** OpenWrt 25.12.5 x86/64 SDK, ucode, procd/uloop, UCI, ubus/rpcd, LuCI JavaScript, msmtp, Node.js behavior harnesses, APK v3 signing/index tools.

## Global Constraints

- Runtime and LuCI package versions are exactly `1.1.0-r3`; `PKG_VERSION` remains `1.1.0` and both `PKG_RELEASE` values become `3`.
- The existing nested feed URL and `keys/netwatch-local.pem` remain unchanged.
- msmtp debug mode is forbidden. Capture at most 4096 bytes of normal stderr in immediately unlinked mode-0600 temporary files.
- Public failure summaries are at most 192 bytes; public details are at most 512 bytes.
- Never expose message bodies, generated msmtp configuration, passwords, account usernames, envelope addresses, RPC session tokens, private keys, or raw exception text.
- The configured SMTP hostname and numeric port may appear in authenticated diagnostics; email addresses and account usernames must be redacted.
- Every public `failure` object contains exactly `stage`, `summary`, `detail`, `exit_code`, `exit_name`, and `smtp_status`.
- Successful and sending mail tests expose `failure: null`.
- Alert delays, retry backoff, repeat intervals, maximum counts, recovery behavior, TLS mode, and TLS certificate-bypass setting remain unchanged.
- Prefer executable behavior tests over source-text assertions whenever production code can execute in the pinned SDK or Node harness.
- Preserve no `.DS_Store` files and never print or copy the signing key into tracked files or logs.
- This checkout stores Git metadata in `work/git-metadata`; when executing in this checkout, replace each displayed `git ...` command with `git --git-dir=work/git-metadata --work-tree=. ...`. A normal isolated worktree uses the displayed commands unchanged.

---

### Task 1: Repair raw recipient-string rendering

**Files:**
- Create: `tests/unit/message_string_test.uc`
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/message.uc:175-214`
- Modify: `tests/static.sh`

**Interfaces:**
- Consumes: existing address validation in `valid_address()`.
- Produces: private `parse_recipients(value) -> string[]`; exported `split_recipients(value) -> string[]`; `render_message()` accepts either a recipient string or array without caller import side effects.

- [ ] **Step 1: Write the failing isolated-module test**

Create a test that imports only `render_message`, passes a raw valid recipient string, and asserts a rendered `To` header. Do not import `split_recipients`; that omission reproduces the installed failure.

```ucode
import { truthy } from 'test';
import { render_message } from 'message';

let output = render_message('failure', {
  smtp: { from: 'router@example.test', from_name: '' },
  recipients: 'ops@example.test',
  monitor: { id: 'wifi', name: 'Wi-Fi', type: 'interface',
    interface_selector: 'wifi-iface:office', max_alerts: 1 },
  state: { incident_started: 1700000000, failure_emails: 0,
    last_check: 1700000001, last_result: {
      ok: false, reason: 'administratively_disabled',
      summary: 'wireless AP is disabled', selector: 'wifi-iface:office',
      kind: 'wifi-iface', configured_name: 'office', label: 'AP: Office',
      evidence: { present: false }
    } },
  router_hostname: 'router', timestamp: 1700000002,
  diagnostic: { text: '', incomplete: false, errors: [], truncated: false }
});
truthy(match(output, /\nTo: ops@example\.test\n/),
  'raw recipient string renders without importing parser');
```

- [ ] **Step 2: Run the isolated test and verify RED**

Run:

```sh
./tests/run-unit.sh tests/unit/message_string_test.uc
```

Expected: FAIL with `access to undeclared variable split_recipients`.

- [ ] **Step 3: Add one private parser and delegate both call paths to it**

In `message.uc`, move the current `split_recipients()` body into a non-exported `parse_recipients()` function. Keep the public API as a wrapper and make `message_recipients()` call the private function for strings.

```ucode
function parse_recipients(value) {
  safe_text(value, 'recipients', false);
  let recipients = [];
  for (let address in split(value, ',')) {
    address = trim(address);
    if (!valid_address(address)) die('recipient is invalid');
    push(recipients, address);
  }
  if (!length(recipients)) die('recipients must not be empty');
  return recipients;
};

export function split_recipients(value) {
  return parse_recipients(value);
};
```

The string branch of `message_recipients()` must return `parse_recipients(value)`.

- [ ] **Step 4: Verify GREEN and existing validation**

Run:

```sh
./tests/run-unit.sh tests/unit/message_string_test.uc tests/unit/message_test.uc
./tests/static.sh
```

Expected: both recipient tests and the complete static suite pass.

- [ ] **Step 5: Commit**

```sh
git add tests/unit/message_string_test.uc tests/static.sh \
  packages/netwatch/netwatch/files/usr/share/netwatch/message.uc
git commit -m "fix: render netwatch alerts with raw recipients"
```

---

### Task 2: Display the friendly interface target in the Monitors grid

**Files:**
- Create: `tests/luci-monitors_test.js`
- Modify: `packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/monitors.js:52-175`
- Modify: `packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot`
- Modify: `tests/static.sh`

**Interfaces:**
- Consumes: normalized inventory groups `{ id, label, items: [{ selector, label }] }` and saved UCI `type`, `target`, `interface_selector`.
- Produces: `targetDisplayValue(type, target, selector, labels) -> string`; grid-only `_display_target` DummyValue; modal editable fields remain unchanged.

- [ ] **Step 1: Create a real-view Node harness and verify RED**

Evaluate the real `monitors.js` with LuCI form/UCI/RPC stubs. Provide an interface inventory containing:

```js
{ id: 'wifi-aps', items: [ {
  selector: 'wifi-iface:default_radio1',
  label: 'AP: Helium+🎈 — radio1 / default_radio1', state: 'disabled'
} ] }
```

Assert the Test3 grid display returns the friendly label, a ping row returns `192.168.4.108`, and a missing saved selector returns `Missing: wifi-iface:gone`.

Run:

```sh
node tests/luci-monitors_test.js
```

Expected: FAIL because the grid still exposes the empty `target` option and has no `_display_target` field.

- [ ] **Step 2: Add a label map and pure target-display helper**

While normalizing inventory, retain `selector -> friendly label` in a local map. Add:

```js
function targetDisplayValue(type, target, selector, labels) {
  if (type !== 'interface')
    return target || _('none');
  return labels[selector] || (selector ? _('Missing: %s').format(selector) : _('none'));
}
```

- [ ] **Step 3: Replace the grid target with a display-only column**

Set the editable `target` option to `modalonly = true`. Add a `form.DummyValue` named `_display_target`, title it `Target`, disable writes/removes, and implement `textvalue(sectionId)` from the saved UCI values and label map. Keep `interface_selector` modal-only.

- [ ] **Step 4: Regenerate translations and verify GREEN**

Run:

```sh
./scripts/in-sdk.sh sh -ec 'cd /sdk/feeds/luci && ./build/i18n-scan.pl /src/packages/netwatch/luci-app-netwatch > /src/packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot'
node tests/luci-monitors_test.js
node --check packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/monitors.js
./tests/static.sh
```

Restore the project/version header in the generated POT exactly as in r2. Expected: all checks pass.

- [ ] **Step 5: Commit**

```sh
git add tests/luci-monitors_test.js tests/static.sh \
  packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/monitors.js \
  packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot
git commit -m "fix: show interface targets in netwatch monitors"
```

---

### Task 3: Add bounded mail-failure classification and redaction

**Files:**
- Create: `packages/netwatch/netwatch/files/usr/share/netwatch/mail_failure.uc`
- Create: `tests/unit/mail_failure_test.uc`
- Modify: `tests/static.sh`

**Interfaces:**
- Produces:
  - `fixed_mail_failure(stage, summary, detail) -> failure`
  - `classify_mail_failure(exit_code, stderr, timed_out, smtp_status) -> failure`
  - `public_mail_failure(value) -> failure|null`
- `failure` is exactly `{ stage, summary, detail, exit_code, exit_name, smtp_status }`.

- [ ] **Step 1: Write sanitizer/classifier tests and verify RED**

Cover at least:

```ucode
deep_equal(classify_mail_failure(74,
  'msmtp: network read error: the operation timed out', false, null), {
  stage: 'network', summary: 'SMTP network I/O failed.',
  detail: 'network read error: the operation timed out',
  exit_code: 74, exit_name: 'EX_IOERR', smtp_status: null
}, 'network error classified');
```

Add one assertion for each of timeout, DNS, TLS, authentication, SMTP 550,
configuration, and unknown process errors. Inject `user=alice`, email addresses,
`password=secret`, `token=secret`, CR/LF controls, HTML, and 4097 bytes; assert
all sensitive values disappear, the summary is no more than 192 bytes, and the
detail is no more than 512 bytes. Inject an `internal_secret` property into an
internal failure and assert `public_mail_failure()` returns only the six allowed
fields.

Run:

```sh
./tests/run-unit.sh tests/unit/mail_failure_test.uc
```

Expected: FAIL because module `mail_failure` does not exist.

- [ ] **Step 2: Implement the pure failure module**

Use fixed allowlists for stages and symbolic sysexits. Sanitize before
classification text is stored. Treat stderr as untrusted; never concatenate an
exception object directly. Map exit 69/74/75/77/78 to bounded symbolic names,
and use null for unknown names/status.

- [ ] **Step 3: Verify GREEN and ucode compilation**

Run:

```sh
./tests/run-unit.sh tests/unit/mail_failure_test.uc
./scripts/in-sdk.sh /usr/bin/ucode -c \
  /src/packages/netwatch/netwatch/files/usr/share/netwatch/mail_failure.uc
./tests/static.sh
```

Expected: all checks pass.

- [ ] **Step 4: Commit**

```sh
git add packages/netwatch/netwatch/files/usr/share/netwatch/mail_failure.uc \
  tests/unit/mail_failure_test.uc tests/static.sh
git commit -m "feat: classify sanitized netwatch mail failures"
```

---

### Task 4: Capture private msmtp stderr and return structured outcomes

**Files:**
- Create: `packages/netwatch/netwatch/files/usr/share/netwatch/mail_delivery.uc`
- Create: `tests/unit/mail_delivery_test.uc`
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc:24-36,208-247,344-460`
- Modify: `tests/static.sh`

**Interfaces:**
- Consumes: `classify_mail_failure()` and `fixed_mail_failure()` from Task 3.
- Produces:
  - `prepare_delivery(message, deps) -> resources|null`
  - `finish_delivery(resources, exit_code, timed_out) -> { ok, failure }`
  - `close_delivery(resources) -> bool` (idempotent)
  - daemon `start_delivery(message, callback)` invokes `callback({ ok, failure })`.

- [ ] **Step 1: Write resource/outcome lifecycle tests and verify RED**

Use fake immediately-unlinked 0600 file handles. Assert:

- three descriptors are prepared for message, success marker, and stderr;
- stderr reads are capped at 4096 bytes;
- success requires exit zero plus `ok` marker and returns `{ ok: true, failure: null }`;
- nonzero exit returns classifier output;
- timeout ignores hostile stderr and returns `stage=timeout`;
- every success, failure, setup error, double-close, timeout, cancellation, and
  shutdown path closes all opened handles exactly once.

Run:

```sh
./tests/run-unit.sh tests/unit/mail_delivery_test.uc
```

Expected: FAIL because module `mail_delivery` does not exist.

- [ ] **Step 2: Implement descriptor ownership in `mail_delivery.uc`**

The module creates each private temporary file below `/var/run/netwatch` with
mode 0600, opens it, immediately unlinks its pathname, owns the resulting file
handle, and exposes only `/proc/self/fd/<n>` paths. It never returns message or
stderr contents. `finish_delivery()` seeks and reads only the result marker and
bounded stderr, closes resources, then returns the structured outcome.

- [ ] **Step 3: Capture normal msmtp stderr without debug output**

Change the fixed shell command to accept message, result, and stderr descriptor
paths. Redirect only normal stderr:

```sh
/usr/bin/msmtp --file=/var/run/netwatch/msmtprc --timeout=60 \
  --read-envelope-from --read-recipients < "$1" > /dev/null 2> "$3" &
```

Keep fixed arguments, child tracking, TERM/INT trap, success marker, and
65-second outer timeout. Do not use `--debug`.

- [ ] **Step 4: Integrate structured outcomes into `start_delivery()`**

Replace local message/result handle logic with `prepare_delivery()` and
`finish_delivery()`. All early returns must call `close_delivery()`. The
process callback passes `{ ok, failure }`; the timeout callback passes the
timeout outcome; shutdown cancellation closes resources without publishing a
late result.

- [ ] **Step 5: Verify GREEN and integration contracts**

Run:

```sh
./tests/run-unit.sh tests/unit/mail_delivery_test.uc tests/unit/mail_failure_test.uc
./tests/static.sh
git diff --check
```

Expected: tests and static contracts pass with no descriptor leak.

- [ ] **Step 6: Commit**

```sh
git add packages/netwatch/netwatch/files/usr/share/netwatch/mail_delivery.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc \
  tests/unit/mail_delivery_test.uc tests/static.sh
git commit -m "feat: capture netwatch smtp delivery failures"
```

---

### Task 5: Extend bounded async mail-test and alert state

**Files:**
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/mail_test.uc`
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/store.uc`
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc:475-535,747-798`
- Modify: `tests/unit/mail_test_test.uc`
- Modify: `tests/unit/store_test.uc`
- Modify: `tests/unit/alerts_test.uc`

**Interfaces:**
- Consumes: delivery outcome `{ ok: bool, failure: failure|null }`.
- Produces: `mail_test` exact public shape `{ id, state, started, completed, error, failure }`; immediate `test_email` rejection `{ ok: false, error, failure }`.

- [ ] **Step 1: Update lifecycle tests and verify RED**

Change delivery callbacks from booleans to outcome objects. Assert sending and
success expose `failure:null`; failure stores the sanitized summary in `error`
and exact six-field object in `failure`; stale IDs cannot mutate current state;
injected secret/extra properties are not serialized.

Add immediate start-failure assertions:

```ucode
deep_equal(result, {
  ok: false,
  error: 'Unable to start SMTP delivery.',
  failure: fixed_mail_failure('spawn', 'Unable to start SMTP delivery.', '')
}, 'spawn failure returned immediately');
```

Run:

```sh
./tests/run-unit.sh tests/unit/mail_test_test.uc tests/unit/store_test.uc tests/unit/alerts_test.uc
```

Expected: FAIL on the missing `failure` field and boolean callback API.

- [ ] **Step 2: Implement exact public serialization**

Add `failure:null` in `begin_mail_test()`. Make `finish_mail_test()` accept a
structured outcome and assign only `public_mail_failure(outcome.failure)`.
`public_mail_test()` must explicitly name all six lifecycle fields and never
spread mutable tracker state.

- [ ] **Step 3: Use stage-specific failures in the daemon**

Map configuration and recipient parsing failures to `stage=config`, message
rendering failures to `stage=render`, an already-running test to
`stage=process`, process creation failures to `stage=spawn`, and transport
outcomes to their classified stage. Preserve raw exception secrecy. Alert
rendering failure sets the global summary to `message rendering failed`, not
`recipient is invalid`; delivery failure uses the classified summary. Successful
alert/test delivery clears the global mail error and increments counters only
through existing `mail_succeeded()`.

- [ ] **Step 4: Verify GREEN**

Run:

```sh
./tests/run-unit.sh tests/unit/mail_test_test.uc tests/unit/store_test.uc \
  tests/unit/alerts_test.uc tests/unit/message_string_test.uc
./tests/run-unit.sh tests/unit/*.uc
./tests/static.sh
```

Expected: all unit and static tests pass.

- [ ] **Step 5: Commit**

```sh
git add packages/netwatch/netwatch/files/usr/share/netwatch/mail_test.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/store.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc \
  tests/unit/mail_test_test.uc tests/unit/store_test.uc tests/unit/alerts_test.uc
git commit -m "feat: expose bounded netwatch mail diagnostics"
```

---

### Task 6: Render a collapsed, secret-safe LuCI failure disclosure

**Files:**
- Modify: `packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js`
- Modify: `packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot`
- Modify: `tests/luci-email_test.js`
- Modify: `tests/static.sh`

**Interfaces:**
- Consumes: immediate or polled `failure` exact object from Task 5.
- Produces: red notification with concise summary plus collapsed native `<details>`; generic fixed fallback for malformed/RPC exceptions.

- [ ] **Step 1: Expand the real-view harness and verify RED**

Make the fake `E()` preserve tag, attributes, and child nodes. Add tests for:

- matching failed state with `stage=network`, timeout detail, exit 74/EX_IOERR;
- immediate `{ ok:false, failure }` from `test_email`;
- `<details>` exists and has no `open` attribute;
- summary is `Show technical details`;
- detail rows contain stage, detail, exit, SMTP status, and test ID as text;
- HTML-like server text remains text, never markup;
- injected password, username, address, token, and extra object property are absent;
- malformed failure and rejected RPC retain the fixed local error.

Run:

```sh
node tests/luci-email_test.js
```

Expected: FAIL because failure notifications remain fixed strings.

- [ ] **Step 2: Return terminal mail-test objects from polling**

Change `waitForMailTest()` to return the matching terminal object instead of
only its state. Keep stale-ID rejection, one-second polling, and 70-second
deadline unchanged.

- [ ] **Step 3: Add strict client-side failure validation and DOM rendering**

Accept only the six expected fields with approved stage values and bounded
types. Create all output with `E()` text children. Do not use `innerHTML`,
`insertAdjacentHTML`, or exception text. Render:

```js
E('details', {}, [
  E('summary', {}, _('Show technical details')),
  E('dl', {}, [
    E('dt', {}, _('Stage')),
    E('dd', {}, failure.stage),
    E('dt', {}, _('Detail')),
    E('dd', {}, failure.detail || _('Unavailable')),
    E('dt', {}, _('Exit')),
    E('dd', {}, formatExit(failure.exit_name, failure.exit_code)),
    E('dt', {}, _('SMTP status')),
    E('dd', {}, failure.smtp_status == null ? _('Unavailable') : String(failure.smtp_status)),
    E('dt', {}, _('Test ID')),
    E('dd', {}, String(test.id))
  ])
])
```

The visible summary begins `Test email failed: %s`. Successful results remain
unchanged; timeout gets its existing fixed local wording.

- [ ] **Step 4: Regenerate translations and verify GREEN**

Run:

```sh
./scripts/in-sdk.sh sh -ec 'cd /sdk/feeds/luci && ./build/i18n-scan.pl /src/packages/netwatch/luci-app-netwatch > /src/packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot'
node tests/luci-email_test.js
node --check packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js
./tests/static.sh
```

Restore the established POT header and expect every check to pass.

- [ ] **Step 5: Commit**

```sh
git add packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js \
  packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot \
  tests/luci-email_test.js tests/static.sh
git commit -m "feat: show detailed netwatch mail failures"
```

---

### Task 7: Prepare 1.1.0-r3 release and artifact contracts

**Files:**
- Modify: `packages/netwatch/netwatch/Makefile`
- Modify: `packages/netwatch/luci-app-netwatch/Makefile`
- Modify: `packages/netwatch/README.md`
- Modify: `scripts/package-output.sh`
- Modify: `scripts/verify-artifacts.sh`
- Modify: `tests/package-output_test.sh`
- Modify: `tests/feed_test.sh`
- Modify: `tests/static.sh`

**Interfaces:**
- Consumes: all r3 source files and tests.
- Produces: exact r3 names and exact runtime manifest including `mail_failure.uc` and `mail_delivery.uc`.

- [ ] **Step 1: Change fixture expectations first and verify RED**

Update `tests/package-output_test.sh` to require r3 Netwatch APK names while
the scripts still expect r2. Run:

```sh
./tests/package-output_test.sh
```

Expected: FAIL on obsolete r2 package lookup.

- [ ] **Step 2: Bump both package releases and exact contracts**

Set `PKG_RELEASE:=3` in both Makefiles. Keep `PKG_VERSION:=1.1.0`. Update exact
output names, feed rules, source archive metadata, README instructions, and the
runtime manifest count from 23 to 25 with both new ucode modules. Scheduled
Backup remains `1.0.0-r3`.

- [ ] **Step 3: Document the disclosure and security boundary**

README must explain the collapsed detail control, listed failure fields,
redaction/bounds, private stderr lifecycle, and that msmtp debug mode is never
used. Retain the existing TLS-bypass warning and feed/key URL.

- [ ] **Step 4: Verify GREEN**

Run:

```sh
./tests/package-output_test.sh
./tests/static.sh
./tests/repository-layout_test.sh
git diff --check
```

Expected: all source/release contracts pass and no `.DS_Store` exists.

- [ ] **Step 5: Commit**

```sh
git add packages/netwatch/netwatch/Makefile \
  packages/netwatch/luci-app-netwatch/Makefile packages/netwatch/README.md \
  scripts/package-output.sh scripts/verify-artifacts.sh \
  tests/package-output_test.sh tests/feed_test.sh tests/static.sh
git commit -m "build: prepare netwatch 1.1.0-r3"
```

---

### Task 8: Build, sign, publish, and independently verify r3

**Files:**
- Generate ignored: `outputs/netwatch_1.1.0-r3_all.apk`
- Generate ignored: `outputs/luci-app-netwatch_1.1.0-r3_all.apk`
- Replace: r2 Netwatch APKs with r3 under `feed/x86_64/`
- Modify: `feed/x86_64/packages.adb`

**Interfaces:**
- Consumes: clean reviewed r3 source, pinned SDK, ignored signing key.
- Produces: signed r3 APKs and signed three-package index at the unchanged URL.

- [ ] **Step 1: Run the complete source suite**

```sh
./tests/run-unit.sh tests/unit/*.uc
node tests/luci-email_test.js
node tests/luci-monitors_test.js
./tests/package-output_test.sh
./tests/static.sh
./tests/repository-layout_test.sh
./tests/in-sdk-source_test.sh
./tests/in-sdk-behavior_test.sh
git diff --check
```

Expected: every command exits zero.

- [ ] **Step 2: Build and inspect pristine APKs**

```sh
./scripts/in-sdk.sh ./scripts/build-packages.sh
./scripts/package-output.sh
./scripts/verify-artifacts.sh
```

Expected: exactly Netwatch runtime r3, Netwatch LuCI r3, and unchanged Scheduled
Backup r3; exact manifests/modes/dependencies/conffiles/credential scans pass.

- [ ] **Step 3: Preserve pristine outputs and sign feed copies exactly once**

Copy pristine Netwatch APKs into ignored `work/*.pristine.apk`, copy those into
the feed, and use pinned APK `adbsign --reset-signatures` once per feed copy.
If a command fails before mutation, compare hashes to pristine before retrying.
Never sign an already signed feed file.

- [ ] **Step 4: Strictly verify and rebuild the index**

Verify both r3 APKs against `/src/keys`, remove r2 only after both pass, run:

```sh
./scripts/rebuild-feed.sh x86_64 work/signing/private-key.pem
./tests/feed_test.sh
./scripts/verify-artifacts.sh
```

Strictly verify `packages.adb` and dump its exact three names/versions.

- [ ] **Step 5: Commit reviewed artifacts, integrate, and publish**

Commit source and signed feed as reviewed changes, merge the feature branch to
`main`, rerun static/LuCI/feed tests on merged main, then push without force.

```sh
git add feed/x86_64/netwatch-1.1.0-r3.apk \
  feed/x86_64/luci-app-netwatch-1.1.0-r3.apk feed/x86_64/packages.adb
git add -u feed/x86_64/netwatch-1.1.0-r2.apk \
  feed/x86_64/luci-app-netwatch-1.1.0-r2.apk
git commit -m "release: publish netwatch 1.1.0-r3"
```

- [ ] **Step 6: Verify public bytes and trusted resolution**

Download raw public key, APKs, and index; require byte equality and hashes;
strictly verify them with the downloaded key. Initialize a disposable APK DB
with official 25.12.5 x86/64 repositories plus exactly the unchanged custom
index URL and simulate installation of all three exact custom revisions.

---

### Task 9: Upgrade and verify the real router/UI

**Files:**
- No source changes.

**Interfaces:**
- Consumes: public trusted r3 feed and router `root@10.10.11.10`.
- Produces: sanitized live evidence for grid display, detailed failure spoiler, successful test mail, and automatic interface alert.

- [ ] **Step 1: Trusted upgrade and safety checks**

Confirm OpenWrt 25.12.5 x86/64 and installed r2, update trusted repositories,
upgrade both packages to r3, and verify service activation, five RPC methods,
0600 public/private config, protected-password existence only, and preserved
`tls=tls` plus `tls_insecure=1`.

- [ ] **Step 2: Verify the Monitors grid behavior**

Use an authenticated browser session if available and confirm Test3 displays
the friendly `AP: Helium+🎈` target. Independently verify the real-view harness
and deployed asset hash. Do not query raw wireless status.

- [ ] **Step 3: Produce one controlled, reversible test failure**

Record the public SMTP settings except the password, temporarily set the SMTP
server to `127.0.0.1`, port `1`, TLS `none`, commit/reload, and invoke the test
through the authenticated LuCI path. Verify the red summary identifies the
connection stage and the disclosure is collapsed by default. Expand it and
verify stage/detail/exit/test ID are present while username, addresses,
password, token, and HTML are absent. Restore and commit the exact original
server, port, TLS, and bypass values immediately, then reload and verify the
generated msmtp configuration without printing its password line.

- [ ] **Step 4: Verify successful manual test delivery**

Click `Save, apply, and send test`; require immediate `{ ok:true,id }`, matching
terminal `sent`, one new sanitized SMTP status 250 record, and the concise
success notification.

- [ ] **Step 5: Verify automatic interface incident mail**

Use the existing failed Test3 incident or a controlled disable/re-enable cycle.
Respect its configured alert cap and avoid duplicate mail. Require a successful
failure alert, `Emails` transition `0/1 -> 1/1`, and a sanitized delivery log.
Restore the original interface state and verify recovery behavior only if its
configured recovery email is still pending and the user-approved cap permits
it.

- [ ] **Step 6: Final verification and cleanup**

Confirm local/remote main equality, public hashes/signatures, exact installed
r3 versions, service enabled/running, no pending UCI changes, no private temp
files, no `.DS_Store`, and a clean repository. Remove only task-created
temporary files and sessions.
