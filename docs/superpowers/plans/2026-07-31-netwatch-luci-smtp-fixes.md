# Netwatch LuCI and SMTP Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish signed Netwatch `1.1.0-r2` packages that restore every authenticated LuCI RPC operation, provide an explicit SMTP certificate-verification bypass, clarify stored-password handling, and report test-email completion asynchronously.

**Architecture:** Keep rpcd as the authorization boundary and make the strict ucode ubus schemas compatible with LuCI's injected session argument. Normalize the new SMTP flag in `config.uc`, render it in `message.uc`, isolate test-delivery state in a small `mail_test.uc` module, and expose bounded state through the existing status method. LuCI continues using the existing ACL and polls status for test completion.

**Tech Stack:** OpenWrt 25.12.5 x86/64 SDK, ucode, ubus/rpcd, UCI, LuCI JavaScript, msmtp 1.8.32, POSIX shell, apk-tools 3, Docker, Git, GitHub raw hosting.

## Global Constraints

- Release `netwatch` and `luci-app-netwatch` as `1.1.0-r2`; do not change `PKG_VERSION`.
- `tls_insecure` is absent/false by default and must never be enabled by package installation or migration.
- The stored SMTP password must never be returned through UCI form values, ubus responses, logs, tests, or artifacts.
- `ubus_rpc_session` is accepted only for LuCI/rpcd compatibility and is ignored by Netwatch.
- RPC and UI error strings remain fixed and secret-free.
- Existing monitor configuration, incident behavior, interface diagnostics, feed URL, and public key remain compatible.
- Use test-first red/green cycles for every production behavior change.
- Test observable behavior with executable ucode or JavaScript harnesses; reserve source-text assertions for package layout and security-boundary contracts that cannot execute on the build host.
- Use `git --git-dir=work/git-metadata --work-tree=.` for repository operations from the primary checkout.

## File responsibility map

- `packages/netwatch/netwatch/files/usr/share/netwatch/config.uc`: normalize UCI booleans and SMTP configuration.
- `packages/netwatch/netwatch/files/usr/share/netwatch/message.uc`: render safe msmtp configuration.
- `packages/netwatch/netwatch/files/usr/share/netwatch/rpc.uc`: construct the published ubus method table with LuCI-compatible schemas.
- `packages/netwatch/netwatch/files/usr/share/netwatch/mail_test.uc`: own the bounded test-email lifecycle state.
- `packages/netwatch/netwatch/files/usr/share/netwatch/store.uc`: expose bounded public daemon status.
- `packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc`: publish ubus methods and orchestrate delivery.
- `packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js`: render SMTP controls and poll test status.
- `packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/status.js`: keep status usable when inventory is unavailable.
- `tests/unit/*.uc` and `tests/luci-email_test.js`: executable runtime and LuCI behavior contracts.
- `tests/static.sh`: package layout, source security boundaries, syntax, and release metadata contracts.
- `scripts/package-output.sh`, `scripts/verify-artifacts.sh`, `tests/package-output_test.sh`, and `tests/feed_test.sh`: exact `r2` artifact/feed contracts.

---

### Task 1: LuCI-compatible ubus method schemas

**Files:**
- Create: `tests/unit/rpc_test.uc`
- Create: `packages/netwatch/netwatch/files/usr/share/netwatch/rpc.uc`
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc`

**Interfaces:**
- Consumes: LuCI's authenticated controller behavior, which adds string `ubus_rpc_session` to the method argument table.
- Produces: `status`, `interfaces`, `check`, and `test_email` schemas that accept and ignore that field.

- [ ] **Step 1: Add the failing executable schema regression test**

Create `tests/unit/rpc_test.uc`. Pass four sentinel handler functions to a wished-for `service_methods()` factory, inspect the returned real method table, and invoke each `call` function to prove the factory preserves the supplied handlers:

```ucode
import { deep_equal, equal } from 'test';
import { service_methods } from 'rpc';

let calls = [];
let handlers = {
  status: (request) => push(calls, [ 'status', request.args ]),
  interfaces: (request) => push(calls, [ 'interfaces', request.args ]),
  check: (request) => push(calls, [ 'check', request.args ]),
  test_email: (request) => push(calls, [ 'test_email', request.args ])
};
let methods = service_methods(handlers);

deep_equal(methods.status.args, { ubus_rpc_session: '' },
  'status accepts LuCI session argument');
deep_equal(methods.interfaces.args, { ubus_rpc_session: '' },
  'interfaces accepts LuCI session argument');
deep_equal(methods.check.args, { id: '', ubus_rpc_session: '' },
  'check accepts ID and LuCI session argument');
deep_equal(methods.test_email.args,
  { recipient: '', ubus_rpc_session: '' },
  'test email accepts recipient and LuCI session argument');

for (let name in [ 'status', 'interfaces', 'check', 'test_email' ])
  methods[name].call({ args: { ubus_rpc_session: 'session-only' } });
equal(length(calls), 4, 'all published handlers remain callable');
```

- [ ] **Step 2: Run the static suite and verify RED**

Run:

```sh
./tests/run-unit.sh tests/unit/rpc_test.uc
```

Expected: FAIL because module `rpc` does not exist.

- [ ] **Step 3: Make the minimal schema change**

Create `rpc.uc` as a focused method-table factory:

```ucode
export function service_methods(handlers) {
  return {
    status: {
      args: { ubus_rpc_session: '' }, call: handlers.status
    },
    interfaces: {
      args: { ubus_rpc_session: '' }, call: handlers.interfaces
    },
    check: {
      args: { id: '', ubus_rpc_session: '' }, call: handlers.check
    },
    test_email: {
      args: { recipient: '', ubus_rpc_session: '' }, call: handlers.test_email
    }
  };
};
```

Import `service_methods` in `netwatchd.uc`, build the table with the existing four callbacks, and publish that returned table. Use the pre-existing `public_status` signature until Task 3; add `mail_test` to the status callback in Task 3.

- [ ] **Step 4: Verify GREEN and syntax**

Run:

```sh
./tests/run-unit.sh tests/unit/rpc_test.uc
./scripts/in-sdk.sh ucode -c packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc
```

Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  tests/unit/rpc_test.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/rpc.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc
git --git-dir=work/git-metadata --work-tree=. commit -m "fix: accept luci session argument in netwatch rpc"
```

---

### Task 2: TLS certificate-verification bypass

**Files:**
- Modify: `tests/unit/config_test.uc`
- Modify: `tests/unit/message_test.uc`
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/config.uc`
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/message.uc`
- Modify: `packages/netwatch/netwatch/files/etc/config/netwatch`

**Interfaces:**
- Consumes: UCI option `netwatch.smtp.tls_insecure` in ordinary OpenWrt boolean forms.
- Produces: normalized SMTP property `tls_insecure: bool` and explicit safe msmtp certificate directives.

- [ ] **Step 1: Add failing normalization tests**

Add to `tests/unit/config_test.uc`:

```ucode
equal(normalize_smtp({}).tls_insecure, false,
  'SMTP certificate bypass defaults off');
equal(normalize_smtp({ tls_insecure: '1' }).tls_insecure, true,
  'SMTP certificate bypass accepts enabled UCI flag');
equal(normalize_smtp({ tls_insecure: '0' }).tls_insecure, false,
  'SMTP certificate bypass accepts disabled UCI flag');
equal(normalize_smtp({ tls_insecure: '1\n0' }).tls_insecure, false,
  'SMTP certificate bypass rejects malformed value safely');
```

- [ ] **Step 2: Add failing msmtp rendering tests**

Extend the verified, implicit, bypassed, and no-TLS cases in `tests/unit/message_test.uc`:

```ucode
truthy(match(msmtp, /(^|\n)tls_certcheck on(\n|$)/),
  'verified TLS explicitly checks certificates');

let insecure = render_msmtp({ ...smtp, tls: 'tls', tls_insecure: true });
truthy(match(insecure, /(^|\n)tls_certcheck off(\n|$)/),
  'explicit bypass disables certificate checking');
equal(match(insecure, /(^|\n)tls_trust_file /), null,
  'bypass does not configure an ignored trust file');

equal(match(no_tls, /(^|\n)tls_certcheck /), null,
  'disabled TLS omits certificate checking');
equal(match(no_tls, /(^|\n)tls_trust_file /), null,
  'disabled TLS omits certificate trust');
```

- [ ] **Step 3: Run focused tests and verify RED**

Run:

```sh
./tests/run-unit.sh tests/unit/config_test.uc tests/unit/message_test.uc
```

Expected: FAIL because `tls_insecure` is absent and msmtp output lacks the new directives.

- [ ] **Step 4: Normalize the new flag**

Add to `normalize_smtp()` in `config.uc`:

```ucode
tls_insecure: uci_bool(
  has_line_break(raw.tls_insecure) ? null : raw.tls_insecure,
  false
),
```

This converts supported UCI values and fails closed for malformed input.

- [ ] **Step 5: Render certificate directives**

Replace the unconditional trust-file line in `render_msmtp()` with:

```ucode
if (smtp.tls != 'none') {
  if (smtp.tls_insecure === true)
    push(lines, 'tls_certcheck off');
  else {
    push(lines, 'tls_certcheck on');
    push(lines, 'tls_trust_file /etc/ssl/certs/ca-certificates.crt');
  }
}
```

Do not add `tls_insecure` to the default UCI file, so upgrades and fresh installs remain verified by default.

- [ ] **Step 6: Verify GREEN**

Run:

```sh
./tests/run-unit.sh tests/unit/config_test.uc tests/unit/message_test.uc
```

Expected: PASS.

- [ ] **Step 7: Commit**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  tests/unit/config_test.uc tests/unit/message_test.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/config.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/message.uc
git --git-dir=work/git-metadata --work-tree=. commit -m "feat: add explicit smtp certificate bypass"
```

---

### Task 3: Bounded asynchronous test-email state

**Files:**
- Create: `tests/unit/mail_test_test.uc`
- Create: `packages/netwatch/netwatch/files/usr/share/netwatch/mail_test.uc`
- Modify: `tests/unit/store_test.uc`
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/store.uc`
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc`

**Interfaces:**
- Produces: `new_mail_test_tracker() -> object`, `begin_mail_test(tracker, now) -> object`, `finish_mail_test(tracker, id, delivered, now) -> bool`, and `public_mail_test(tracker) -> object|null`.
- Produces: public status property `mail_test` with `id`, `state`, `started`, `completed`, and fixed `error`.
- Changes: `test_email` returns `{ ok: true, id }` immediately after starting delivery.

- [ ] **Step 1: Write the lifecycle test first**

Create `tests/unit/mail_test_test.uc`:

```ucode
import { deep_equal, equal, truthy } from 'test';
import {
  new_mail_test_tracker, begin_mail_test,
  finish_mail_test, public_mail_test
} from 'mail_test';

let tracker = new_mail_test_tracker();
equal(public_mail_test(tracker), null, 'fresh tracker has no public test');

let first = begin_mail_test(tracker, 100);
deep_equal(first, {
  id: 1, state: 'sending', started: 100, completed: null, error: null
}, 'test begins with bounded sending state');
equal(finish_mail_test(tracker, 99, true, 101), false,
  'stale completion cannot mutate current test');
truthy(finish_mail_test(tracker, 1, true, 102),
  'matching successful completion accepted');
equal(public_mail_test(tracker).state, 'sent', 'success becomes sent');

let second = begin_mail_test(tracker, 200);
equal(second.id, 2, 'test IDs increase within daemon lifetime');
truthy(finish_mail_test(tracker, 2, false, 205),
  'matching failed completion accepted');
deep_equal(public_mail_test(tracker), {
  id: 2, state: 'failed', started: 200, completed: 205,
  error: 'mail delivery failed'
}, 'failure exposes only a fixed error');
```

- [ ] **Step 2: Run the new unit test and verify RED**

Run:

```sh
./tests/run-unit.sh tests/unit/mail_test_test.uc
```

Expected: FAIL because module `mail_test` does not exist.

- [ ] **Step 3: Implement the lifecycle module**

Create `mail_test.uc` with the exact public API:

```ucode
export function new_mail_test_tracker() {
  return { next_id: 1, current: null };
};

export function begin_mail_test(tracker, now) {
  let current = {
    id: tracker.next_id++, state: 'sending', started: now,
    completed: null, error: null
  };
  tracker.current = current;
  return { ...current };
};

export function finish_mail_test(tracker, id, delivered, now) {
  if (tracker?.current?.id !== id || tracker.current.state != 'sending')
    return false;
  tracker.current.state = delivered === true ? 'sent' : 'failed';
  tracker.current.completed = now;
  tracker.current.error = delivered === true ? null : 'mail delivery failed';
  return true;
};

export function public_mail_test(tracker) {
  return tracker?.current ? { ...tracker.current } : null;
};
```

- [ ] **Step 4: Verify lifecycle GREEN**

Run:

```sh
./tests/run-unit.sh tests/unit/mail_test_test.uc
```

Expected: PASS.

- [ ] **Step 5: Add failing public-status assertions**

Update `tests/unit/store_test.uc` to pass a tracker into `public_status()` and assert that only the bounded `mail_test` shape is returned. Add an extra secret property to the tracker fixture and assert it is absent from serialized status.

- [ ] **Step 6: Update the status API minimally**

Import `public_mail_test` in `store.uc` and change both status functions:

```ucode
export function public_status(
  daemon_started, last_reload, mail_error, mail_test, states
) {
  return {
    version: 1,
    daemon_started,
    last_reload,
    mail_error,
    mail_test: public_mail_test(mail_test),
    monitors: map(states, (s) => ({ /* existing bounded fields */ }))
  };
};

export function write_status(
  daemon_started, last_reload, mail_error, mail_test, states
) {
  let output = `${sprintf('%J', public_status(
    daemon_started, last_reload, mail_error, mail_test, states
  ))}\n`;
  /* existing atomic write body */
};
```

Update test call sites and verify `tests/unit/store_test.uc` passes.

- [ ] **Step 7: Extend the lifecycle test for immediate-return orchestration**

Add a `start_mail_test(tracker, now, start_delivery, completed_at, changed)` API to the wished-for module. In `mail_test_test.uc`, supply a fake only for the external delivery process: capture its callback without invoking it, assert that `start_mail_test()` immediately returns `{ ok: true, id: 3 }` while public state remains `sending`, then invoke the captured callback and assert terminal state and one `changed` notification. Add a second starter returning false and assert immediate fixed failure state. This test must fail before production code is changed.

- [ ] **Step 8: Implement immediate-return orchestration**

In `netwatchd.uc`:

```ucode
import {
  new_mail_test_tracker, begin_mail_test, finish_mail_test, start_mail_test
} from 'mail_test';

let mail_test = new_mail_test_tracker();

function mail_work_active() {
  if (length(active_deliveries)) return true;
  for (let state in states)
    if (state?.mail_busy) return true;
  return false;
};
```

Pass `mail_test` through `persist_status()`, `public_status()`, and `write_status()`. Make `start_alert()` return false while `mail_work_active()` is true so a test and an alert cannot overlap.

Implement `start_mail_test()` in the module using `begin_mail_test()` and `finish_mail_test()`. It must return before the captured delivery callback runs and invoke `changed(public_mail_test(tracker))` after starting and after completion.

Rewrite `request_test_email()` in this order:

1. Reject shutdown and `mail_work_active()`.
2. Call `load_configuration()` and reject a failed reload.
3. Validate mail configuration and recipient exactly as before.
4. Render the message.
5. Call `start_mail_test()` with the real `start_delivery` adapter, `time`, and a change callback that updates `mail_error` and persists status.
6. Return the helper's `{ ok, id }` result directly without deferring the request.

- [ ] **Step 9: Verify backend GREEN**

Run:

```sh
./tests/run-unit.sh tests/unit/mail_test_test.uc tests/unit/store_test.uc
```

Expected: PASS.

- [ ] **Step 10: Commit**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  tests/unit/mail_test_test.uc tests/unit/store_test.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/mail_test.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/store.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc
git --git-dir=work/git-metadata --work-tree=. commit -m "fix: report test email completion asynchronously"
```

---

### Task 4: LuCI SMTP and test-email UX

**Files:**
- Create: `tests/luci-email_test.js`
- Modify: `packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js`
- Modify: `packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot`

**Interfaces:**
- Consumes: UCI `tls_insecure`; `test_email -> { ok, id }`; `status.mail_test` terminal states.
- Produces: default-off insecure checkbox, secret-safe password input, and bounded status polling.

- [ ] **Step 1: Create a failing LuCI behavior harness**

Create `tests/luci-email_test.js`. Evaluate the real `email.js` inside `new Function()` with small LuCI stubs that record `form.Flag`/`form.Value` options, UCI writes, RPC declarations/calls, notifications, and timer callbacks. The test must assert observable behavior:

1. Rendering with an existing stored password gives the password option an empty `cfgvalue`, a stored-password placeholder, and no write when the submitted value is empty.
2. A newly submitted password is written unchanged and can therefore be revealed by the normal password widget.
3. `tls_insecure` defaults disabled and declares dependencies for `starttls` and `tls`, but not `none`.
4. A test-email click calls save, apply, `test_email`, then `status`; the button remains disabled while status is `sending` and is re-enabled only after matching state `sent`, `failed`, or bounded timeout.
5. Notifications contain only the fixed UI strings supplied by the view, even when RPC stubs reject with a secret-bearing exception.

Use literal expected option names, state values, and notification strings. The harness may fake RPC/timers because those are the external boundaries; it must execute the real view code and option callbacks.

- [ ] **Step 2: Run static tests and verify RED**

Run:

```sh
node tests/luci-email_test.js
```

Expected: FAIL on the missing checkbox, polling helper, and password behavior.

- [ ] **Step 3: Add the insecure checkbox**

After the TLS mode field, add:

```js
o = s.option(form.Flag, 'tls_insecure',
  _('Disable TLS certificate verification (insecure)'),
  _('This permits man-in-the-middle attacks. Use only when the SMTP certificate cannot be validated through the router trust store.'));
o.default = o.disabled;
o.rmempty = true;
o.depends('tls', 'starttls');
o.depends('tls', 'tls');
```

- [ ] **Step 4: Make the password field secret-safe and understandable**

Before creating the field, read only whether a password exists:

```js
const passwordStored = !!uci.get('netwatch', 'smtp', 'password');
```

Configure the field as:

```js
o = s.option(form.Value, 'password', _('Password'), passwordStored
  ? _('A password is stored. Leave this field empty to keep it, or enter a replacement.')
  : _('Enter the SMTP password.'));
o.password = true;
o.placeholder = passwordStored ? _('Stored password unchanged') : '';
o.rmempty = true;
o.cfgvalue = function() { return ''; };
o.write = function(sectionId, value) {
  if (value !== '') uci.set('netwatch', sectionId, 'password', value);
};
o.remove = function() {};
```

Retain the explicit clear-password checkbox.

- [ ] **Step 5: Implement bounded polling**

Declare `callStatus`, then add:

```js
function delay(milliseconds) {
  return new Promise(resolve => window.setTimeout(resolve, milliseconds));
}

function waitForMailTest(id, deadline) {
  return L.resolveDefault(callStatus(), null).then(status => {
    const test = status && status.mail_test;
    if (test && test.id === id && (test.state === 'sent' || test.state === 'failed'))
      return test.state;
    if (Date.now() >= deadline)
      return 'timeout';
    return delay(1000).then(() => waitForMailTest(id, deadline));
  });
}
```

After save/apply, require `{ ok: true, id: integer }`, then call `waitForMailTest(id, Date.now() + 70000)`. Keep the button busy until completion and show fixed notifications for `sent`, `failed`, or `timeout`.

- [ ] **Step 6: Refresh translations**

Run the existing LuCI package preparation/build path so `po/templates/netwatch.pot` contains the new labels, or update the catalog with the SDK's LuCI i18n target if available. Verify no compiled translation or POT is installed in the APK.

- [ ] **Step 7: Verify GREEN and JavaScript syntax**

Run:

```sh
./tests/static.sh
node tests/luci-email_test.js
node --check packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js
```

Expected: PASS.

- [ ] **Step 8: Commit**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  tests/luci-email_test.js \
  packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js \
  packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot
git --git-dir=work/git-metadata --work-tree=. commit -m "fix: make netwatch email testing reliable"
```

---

### Task 5: Release and artifact contracts for `1.1.0-r2`

**Files:**
- Modify: `tests/package-output_test.sh`
- Modify: `tests/static.sh`
- Modify: `tests/feed_test.sh`
- Modify: `scripts/package-output.sh`
- Modify: `scripts/verify-artifacts.sh`
- Modify: `packages/netwatch/netwatch/Makefile`
- Modify: `packages/netwatch/luci-app-netwatch/Makefile`
- Modify: `packages/netwatch/README.md`

**Interfaces:**
- Produces: exact `netwatch-1.1.0-r2` and `luci-app-netwatch-1.1.0-r2` build, output, manifest, documentation, and feed expectations.

- [ ] **Step 1: Advance fixture expectations first**

Change Netwatch-only fixture names in `tests/package-output_test.sh` from `r1` to `r2`, leaving Scheduled Backup `1.0.0-r3` unchanged.

- [ ] **Step 2: Verify RED**

Run:

```sh
./tests/package-output_test.sh
```

Expected: FAIL because `scripts/package-output.sh` still searches for `r1` APKs.

- [ ] **Step 3: Update build and packaging metadata**

Set `PKG_RELEASE:=2` in both Netwatch Makefiles. Replace the Netwatch-only `r1` paths and manifest versions in `scripts/package-output.sh` and `scripts/verify-artifacts.sh` with `r2`.

Add `usr/share/netwatch/mail_test.uc` and `usr/share/netwatch/rpc.uc` to the exact runtime manifest in `scripts/verify-artifacts.sh`.

- [ ] **Step 4: Update documentation and static release assertions**

Update current-release strings and commands in `packages/netwatch/README.md` and `tests/static.sh` to `1.1.0-r2`. Document:

```sh
uci set netwatch.smtp.tls='tls'
uci set netwatch.smtp.tls_insecure='1'
uci commit netwatch
/etc/init.d/netwatch reload
```

Place a warning immediately beside that example stating that bypass disables server-certificate authentication and should be used only when the certificate cannot be validated normally.

- [ ] **Step 5: Verify packaging GREEN**

Run:

```sh
./tests/package-output_test.sh
./tests/static.sh
```

Expected: PASS.

- [ ] **Step 6: Commit source release metadata**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  tests/package-output_test.sh tests/static.sh \
  scripts/package-output.sh scripts/verify-artifacts.sh \
  packages/netwatch/netwatch/Makefile \
  packages/netwatch/luci-app-netwatch/Makefile \
  packages/netwatch/README.md
git --git-dir=work/git-metadata --work-tree=. commit -m "build: prepare netwatch 1.1.0-r2"
```

---

### Task 6: Full verification, build, and signed feed publication

**Files:**
- Generate ignored: `outputs/netwatch_1.1.0-r2_all.apk`
- Generate ignored: `outputs/luci-app-netwatch_1.1.0-r2_all.apk`
- Replace: `feed/x86_64/netwatch-1.1.0-r1.apk` with `feed/x86_64/netwatch-1.1.0-r2.apk`
- Replace: `feed/x86_64/luci-app-netwatch-1.1.0-r1.apk` with `feed/x86_64/luci-app-netwatch-1.1.0-r2.apk`
- Modify: `feed/x86_64/packages.adb`
- Modify: `tests/feed_test.sh`

**Interfaces:**
- Consumes: clean committed source, pinned SDK, ignored private key `work/signing/private-key.pem`, and committed public key.
- Produces: signed APKs and signed combined index at the unchanged feed URL.

- [ ] **Step 1: Run the complete source suite**

```sh
./tests/run-unit.sh \
  tests/unit/config_test.uc \
  tests/unit/interfaces_test.uc \
  tests/unit/interface_probe_test.uc \
  tests/unit/diagnostics_test.uc \
  tests/unit/ping_test.uc \
  tests/unit/probe_test.uc \
  tests/unit/result_test.uc \
  tests/unit/state_test.uc \
  tests/unit/store_test.uc \
  tests/unit/alerts_test.uc \
  tests/unit/message_test.uc \
  tests/unit/mail_test_test.uc \
  tests/unit/rpc_test.uc
node tests/luci-email_test.js
./tests/package-output_test.sh
./tests/static.sh
./tests/repository-layout_test.sh
./tests/in-sdk-source_test.sh
./tests/in-sdk-behavior_test.sh
git --git-dir=work/git-metadata --work-tree=. diff --check
```

Expected: every command passes.

- [ ] **Step 2: Build with the pinned SDK**

```sh
./scripts/in-sdk.sh ./scripts/build-packages.sh
./scripts/package-output.sh
./scripts/verify-artifacts.sh
```

Expected: exactly one `netwatch-1.1.0-r2.apk`, one `luci-app-netwatch-1.1.0-r2.apk`, and unchanged Scheduled Backup `1.0.0-r3`; artifact verification passes.

- [ ] **Step 3: Preserve pristine APKs and sign feed copies once**

```sh
cp outputs/netwatch_1.1.0-r2_all.apk work/netwatch-1.1.0-r2.pristine.apk
cp outputs/luci-app-netwatch_1.1.0-r2_all.apk work/luci-app-netwatch-1.1.0-r2.pristine.apk
cp work/netwatch-1.1.0-r2.pristine.apk feed/x86_64/netwatch-1.1.0-r2.apk
cp work/luci-app-netwatch-1.1.0-r2.pristine.apk feed/x86_64/luci-app-netwatch-1.1.0-r2.apk
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk --allow-untrusted adbsign \
  --reset-signatures --sign-key /src/work/signing/private-key.pem \
  /src/feed/x86_64/netwatch-1.1.0-r2.apk
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk --allow-untrusted adbsign \
  --reset-signatures --sign-key /src/work/signing/private-key.pem \
  /src/feed/x86_64/luci-app-netwatch-1.1.0-r2.apk
```

Remove the two obsolete `r1` feed APKs only after the `r2` signatures verify.

- [ ] **Step 4: Verify signatures and rebuild the nested feed**

```sh
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk verify \
  --keys-dir /src/keys /src/feed/x86_64/netwatch-1.1.0-r2.apk
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk verify \
  --keys-dir /src/keys /src/feed/x86_64/luci-app-netwatch-1.1.0-r2.apk
./scripts/rebuild-feed.sh x86_64 work/signing/private-key.pem
```

Expected: both APKs and `packages.adb` verify with the committed public key.

- [ ] **Step 5: Complete the feed-specific red/green cycle**

Update `tests/feed_test.sh` to require only Netwatch `r2` APKs, reject obsolete Netwatch revisions, and keep Scheduled Backup `r3`. Run:

```sh
./tests/feed_test.sh
./scripts/verify-artifacts.sh
```

Expected: PASS.

- [ ] **Step 6: Commit and push the release**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  tests/feed_test.sh \
  feed/x86_64/netwatch-1.1.0-r2.apk \
  feed/x86_64/luci-app-netwatch-1.1.0-r2.apk \
  feed/x86_64/packages.adb
git --git-dir=work/git-metadata --work-tree=. add -u \
  feed/x86_64/netwatch-1.1.0-r1.apk \
  feed/x86_64/luci-app-netwatch-1.1.0-r1.apk
git --git-dir=work/git-metadata --work-tree=. commit -m "release: publish netwatch 1.1.0-r2"
git --git-dir=work/git-metadata --work-tree=. push origin main
```

---

### Task 7: Live-router and public-feed verification

**Files:**
- No source changes unless verification exposes a defect.
- Generate ignored: `work/public-feed-check/*`

**Interfaces:**
- Consumes: published `packages.adb`, signed `r2` APKs, and SSH access to `root@10.10.11.10`.
- Produces: evidence that the public feed upgrades correctly and every reported router behavior is fixed.

- [ ] **Step 1: Verify raw GitHub artifacts byte-for-byte**

Download the raw `r2` APKs, `packages.adb`, and public key into `work/public-feed-check/`. Compare the APKs and index to the committed files with `cmp`, then verify all three with SDK apk-tools and the downloaded key.

- [ ] **Step 2: Verify trusted resolution in a fresh APK database**

Initialize a disposable root with `apk add --initdb`, install the downloaded public key, configure the one raw `packages.adb` URL, run `apk update`, and simulate installation of:

```text
netwatch=1.1.0-r2
luci-app-netwatch=1.1.0-r2
```

Expected: both exact revisions and their official dependencies resolve without `--allow-untrusted`.

- [ ] **Step 3: Upgrade the live router without exposing credentials**

On `10.10.11.10`, run `apk update` and upgrade both Netwatch packages from the trusted feed. Confirm `/etc/config/netwatch` remains present and its SMTP password remains set by checking only whether it is non-empty; never print it.

- [ ] **Step 4: Configure the explicitly requested SMTP mode**

```sh
uci set netwatch.smtp.tls='tls'
uci set netwatch.smtp.tls_insecure='1'
uci commit netwatch
/etc/init.d/netwatch reload
```

Confirm `/var/run/netwatch/msmtprc` is mode `0600`, contains `tls_starttls off` and `tls_certcheck off`, and does not print its password line during inspection.

- [ ] **Step 5: Exercise the authenticated HTTP ubus path**

Use the active LuCI session token only inside the router shell, without printing it. POST calls through `http://127.0.0.1/ubus` and require result code `0` for:

```text
netwatch.status {}
netwatch.interfaces {}
netwatch.check { "id": "Test1" }
```

Confirm inventory includes `network:`, `device:`, `wifi-radio:`, and custom-named `wifi-iface:` choices.

- [ ] **Step 6: Send and observe an asynchronous test email**

Call `netwatch.test_email` through the same authenticated HTTP ubus path. Require the initial response to return promptly with `{ ok: true, id }`, then poll `netwatch.status` until the matching `mail_test` reaches `sent`. Confirm the msmtp log reports `smtpstatus=250` without printing credentials.

- [ ] **Step 7: Final repository and release checks**

```sh
git --git-dir=work/git-metadata --work-tree=. status --short
git --git-dir=work/git-metadata --work-tree=. log -1 --oneline
gh repo view Delitants/openwrt-packages --json url,defaultBranchRef
```

Expected: clean worktree, release commit on `main`, public feed byte matches, router runs both `1.1.0-r2` packages, and all three user-reported LuCI functions are operational.
