# Netwatch Mail, Modal Save, and Logging Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make monitor edits save reliably, make every accepted test-email click produce and accurately report its own delivery attempt, render readable interface diagnostics, and add a global non-flooding log verbosity control.

**Architecture:** Keep the existing asynchronous daemon and LuCI RPC design. Add small, executable-tested helpers at the behavior boundaries: a no-op grid display parser, a phase-aware/retry-bounded LuCI test-mail flow, a centralized daemon log gate, and a plain-text diagnostic formatter. Do all source work and reviews first, then perform one r4 build/sign/publish cycle and one router upgrade/acceptance cycle.

**Tech Stack:** OpenWrt 25.12.5 x86/64 APK packages, ucode daemon, procd, UCI, ubus/rpcd, modern LuCI JavaScript, Node.js view harnesses, shell release tests, pinned OpenWrt SDK, apk-tools 3 signatures.

**Spec:** `docs/superpowers/specs/2026-08-13-netwatch-mail-ui-logging-design.md`

## Global Constraints

- Target OpenWrt `25.12.5`, `x86/64`, APK packaging, package architecture `all`.
- Never expose SMTP passwords, tokens, authorization values, raw exceptions, raw RPC bodies, or HTML in banners, status, syslog, or email diagnostics.
- Never enable `msmtp --debug`; preserve the existing private stderr capture and six-field public failure projection.
- Default global `log_verbosity` is exactly `normal`; missing or invalid values normalize to `normal`.
- Every accepted test button click produces one distinct test-mail attempt or a banner with a fixed, explicit reason why it could not.
- Diagnostics stay fresh, bounded, redacted, email-only, and absent from recovery messages and public status.
- Do not perform a clean SDK package build before Tasks 1–5 and their reviews are green.
- Perform exactly one final r4 build/sign/index/publication cycle; never sign an already signed APK.
- Preserve `luci-app-scheduled-backup-1.0.0-r3.apk` byte-for-byte and preserve the unchanged public feed URL/key.
- Do not preserve or publish `.DS_Store` or private signing-key material.

---

### Task 1: Make monitor modal Save resolve

**Files:**
- Modify: `packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/monitors.js`
- Modify: `tests/luci-monitors_test.js`
- Modify: `tests/static.sh`

**Interfaces:**
- Consumes: LuCI `form.GridSection` modal save, which calls `parse()` on child values.
- Produces: display-only Target option whose `parse(sectionId)` returns a resolved promise and never writes/removes UCI.

- [ ] **Step 1: Extend the monitor harness with executable parse/save behavior**

In `tests/luci-monitors_test.js`, make the fake option parser follow LuCI's relevant behavior: active fields with changed values call `write()`, inactive fields call `remove()`, and the modal save awaits every child parser. Record writes/removes and modal completion. Add assertions equivalent to:

```js
const completion = harness.saveModal('Test3', {
    name: 'Renamed AP monitor',
    type: 'interface',
    interface_selector: 'wifi-iface:default_radio1'
});
await assert.doesNotReject(completion);
assert.equal(harness.modalClosed(), true);
assert.deepEqual(harness.writes(), [
    [ 'netwatch', 'Test3', 'name', 'Renamed AP monitor' ]
]);
assert.equal(harness.writes().some(write => write[2] === '_display_target'), false);
assert.equal(harness.removes().some(remove => remove[2] === '_display_target'), false);
```

Repeat for one ping and one TCP monitor so dependency changes cannot reintroduce the hang.

- [ ] **Step 2: Run the focused RED test**

Run:

```sh
node tests/luci-monitors_test.js
```

Expected: FAIL because `_display_target` has `write`/`remove` set to `null`, causing the modal parse/save promise not to complete successfully.

- [ ] **Step 3: Implement a true no-op display parser**

In `monitors.js`, retain `form.DummyValue` and friendly `textvalue()`, but replace unsafe null methods with an explicit parser:

```js
o.parse = function() {
    return Promise.resolve();
};
o.write = function() {};
o.remove = function() {};
```

The parser is the primary boundary: the display-only value must never enter the UCI write/remove path.

- [ ] **Step 4: Add static source guards**

In `tests/static.sh`, assert that the monitor view contains the explicit no-op `_display_target` parser and does not contain:

```js
o.write = null;
o.remove = null;
```

- [ ] **Step 5: Run focused GREEN checks**

Run:

```sh
node tests/luci-monitors_test.js
node --check packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/monitors.js
git diff --check
```

Expected: all exit zero; modal completion is observed for interface, ping, and TCP monitors.

- [ ] **Step 6: Commit Task 1**

```sh
git add packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/monitors.js \
  tests/luci-monitors_test.js tests/static.sh
git commit -m "fix: complete netwatch monitor modal saves"
```

---

### Task 2: Make test-email results explanatory and repeatable

**Files:**
- Modify: `packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js`
- Modify: `tests/luci-email_test.js`
- Modify: `packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot`
- Modify: `tests/static.sh`

**Interfaces:**
- Consumes: `test_email` RPC result `{ ok:true, id:int }` or `{ ok:false, error:string, failure:object }`; `status.mail_test` exact terminal state.
- Produces: `requestTestEmail(recipient, deadline)` that retries only the fixed backend busy rejection, returns a distinct accepted test ID, and throws a fixed phase error otherwise.
- Produces: banners `Test email could not be sent: <fixed reason>` and existing validated collapsed backend disclosure.

- [ ] **Step 1: Add client-flow fixtures for the false banner and repeated clicks**

Extend `tests/luci-email_test.js` to record RPC calls, timer activity, button state, and notification text. Add separate cases:

```js
// A successful matching ID must never produce a red notification.
testEmailReplies: [ { ok: true, id: 7 } ],
statusReplies: [ sending(7), sent(7) ]
```

```js
// Two sequential clicks produce two RPC calls and distinct terminal successes.
testEmailReplies: [ { ok: true, id: 7 }, { ok: true, id: 8 } ],
statusReplies: [ sent(7), sent(8) ]
```

```js
// Temporary automatic-alert contention is retained and retried.
testEmailReplies: [
  fixedRejection('process', 'mail delivery already running'),
  { ok: true, id: 9 }
],
statusReplies: [ sent(9) ]
```

Also add save rejection, apply rejection, RPC transport rejection, malformed immediate reply, status RPC rejection, terminal failed object, and terminal timeout cases. Require exact reasons and require raw thrown strings such as passwords/HTML/URLs not to appear.

- [ ] **Step 2: Run the focused RED test**

Run:

```sh
node tests/luci-email_test.js
```

Expected: FAIL because the current catch always emits the generic banner, immediate `busy` is terminal instead of retried, and the second click is not proven to create a new request.

- [ ] **Step 3: Implement fixed client errors and bounded busy retry**

Add an internal fixed-error constructor and a retry helper in `email.js`:

```js
function testMailError(reason) {
    const error = new Error('netwatch test mail failed');
    error.safeReason = reason;
    return error;
}

function isBusyFailure(result) {
    const failure = validMailFailure(result && result.failure);
    return result && result.ok === false && failure &&
        failure.stage === 'process' &&
        failure.summary === 'mail delivery already running';
}

function requestTestEmail(recipient, deadline) {
    return callTestEmail(recipient).then(result => {
        if (isBusyFailure(result) && Date.now() < deadline)
            return delay(1000).then(() => requestTestEmail(recipient, deadline));
        return result;
    });
}
```

The deadline is 30 seconds. Do not retry validation, configuration, render, authentication, network, or generic failures.

- [ ] **Step 4: Split the action pipeline into explicit phases**

Wrap each phase so only fixed translated reasons reach the generic banner:

```js
m.save(null, true).catch(() => { throw testMailError(_('configuration could not be saved')); })
uci.apply().catch(() => { throw testMailError(_('configuration could not be applied')); })
requestTestEmail(recipient, Date.now() + 30000)
```

Map malformed/rejected RPC to `the router rejected the test request`, polling rejection to `the delivery result could not be read`, busy deadline to `SMTP delivery remained busy`, and terminal timeout to `timed out waiting for the delivery result`.

For a validated backend failure, call `showMailTestFailure()` so the first red line is still:

```text
Test email failed: <sanitized summary>
```

For client failures, render:

```js
_('Test email could not be sent: %s').format(error.safeReason)
```

Never interpolate `error.message` or RPC response text.

- [ ] **Step 5: Guarantee in-flight cleanup and matching-ID success**

Keep `testEmailInFlight` as a double-click guard, but require `.finally()` to restore it and the button after every path. Only a terminal state with the accepted ID may display success. A subsequent click must call `test_email` again and receive a new ID.

- [ ] **Step 6: Regenerate the translation template**

Run the repository's existing LuCI POT generation command used by `tests/static.sh`, then restore the valid POT header format. Ensure each new fixed reason and the full banner format is present once.

- [ ] **Step 7: Run focused GREEN checks**

Run:

```sh
node tests/luci-email_test.js
node --check packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js
msgfmt --check --check-header packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot
git diff --check
```

Expected: all cases pass; two sequential clicks yield two accepted IDs and two success notifications; busy is retried once without duplicate concurrent requests.

- [ ] **Step 8: Commit Task 2**

```sh
git add packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js \
  packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot \
  tests/luci-email_test.js tests/static.sh
git commit -m "fix: report repeatable netwatch test mail results"
```

---

### Task 3: Add global syslog verbosity without flooding

**Files:**
- Create: `packages/netwatch/netwatch/files/usr/share/netwatch/logger.uc`
- Create: `tests/unit/logger_test.uc`
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/config.uc`
- Modify: `tests/unit/config_test.uc`
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc`
- Modify: `packages/netwatch/netwatch/files/etc/config/netwatch`
- Modify: `packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js`
- Modify: `packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot`
- Modify: `tests/static.sh`

**Interfaces:**
- Produces: `normalize_global(raw).log_verbosity: 'errors'|'normal'|'verbose'`.
- Produces: `new_logger(log_module, level_provider)` with `error()`, `normal()`, and `verbose()` methods that preserve syslog priority and formatting arguments.
- Consumes: live `global_config.log_verbosity` after each configuration reload.

- [ ] **Step 1: Add failing configuration normalization tests**

In `tests/unit/config_test.uc`, require:

```ucode
equal(normalize_global({}).log_verbosity, 'normal', 'missing verbosity defaults normal');
equal(normalize_global({ log_verbosity: 'errors' }).log_verbosity, 'errors', 'errors accepted');
equal(normalize_global({ log_verbosity: 'verbose' }).log_verbosity, 'verbose', 'verbose accepted');
equal(normalize_global({ log_verbosity: 'debug' }).log_verbosity, 'normal', 'invalid verbosity defaults normal');
equal(normalize_global({ log_verbosity: 'verbose\nsecret' }).log_verbosity, 'normal', 'line break rejected');
```

- [ ] **Step 2: Add failing logger behavior tests**

Create `tests/unit/logger_test.uc` with a fake module recording `syslog()` calls. Require this matrix:

| Setting | error | normal | verbose |
|---|---:|---:|---:|
| errors | emit | suppress | suppress |
| normal | emit | emit | suppress |
| verbose | emit | emit | emit |

Also change the provider after construction and prove the next call uses the new value.

- [ ] **Step 3: Run focused RED tests**

Run:

```sh
./tests/run-unit.sh tests/unit/config_test.uc tests/unit/logger_test.uc
```

Expected: FAIL because `log_verbosity` and `logger.uc` do not exist.

- [ ] **Step 4: Implement normalization and the logger module**

In `config.uc`, define:

```ucode
const LOG_VERBOSITY = [ 'errors', 'normal', 'verbose' ];
```

Normalize a plain, no-line-break value in that set; otherwise return `normal`.

In `logger.uc`, implement a small gate whose methods accept `(priority, format, ...args)` and call the provided module's `syslog()` only when allowed. Treat an invalid runtime provider value as `normal`.

- [ ] **Step 5: Route daemon logs through semantic levels**

Instantiate the logger once in `netwatchd.uc` with a provider returning `global_config?.log_verbosity ?? 'normal'`. Replace direct calls according to the approved mapping:

- `error`: configuration/persistence failures, probe-start failures, mail failures.
- `normal`: startup/shutdown/reload, state transitions, final mail success/failure.
- `verbose`: every healthy/failed probe result, diagnostic start, diagnostic completion.

Do not downgrade syslog priorities; e.g. an emitted mail failure stays `err`, a transition stays `notice`.

- [ ] **Step 6: Add UCI default and LuCI dropdown**

Add:

```uci
option log_verbosity 'normal'
```

to `netwatch.main`. In the Email page Notifications section add a `form.ListValue` with values `errors`, `normal`, `verbose`, default `normal`, `rmempty = false`, and concise descriptions matching the spec.

- [ ] **Step 7: Add source and upgrade guards**

Update `tests/static.sh` to include `logger` in runtime module manifests, require no remaining direct `log.syslog(` calls outside `logger.uc`, require the UCI/LuCI option, and require default `normal`. Confirm the existing upgrade path preserves an already configured value and missing values use runtime default without destructively writing UCI.

- [ ] **Step 8: Run focused and integration GREEN checks**

Run:

```sh
./tests/run-unit.sh tests/unit/config_test.uc tests/unit/logger_test.uc
./tests/run-unit.sh tests/unit/*.uc
node tests/luci-email_test.js
./tests/in-sdk-source_test.sh
./tests/in-sdk-behavior_test.sh
git diff --check
```

Expected: all exit zero and normal mode emits no per-probe or diagnostic-progress entries.

- [ ] **Step 9: Commit Task 3**

```sh
git add packages/netwatch/netwatch/files/usr/share/netwatch/logger.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/config.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/netwatchd.uc \
  packages/netwatch/netwatch/files/etc/config/netwatch \
  packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js \
  packages/netwatch/luci-app-netwatch/po/templates/netwatch.pot \
  tests/unit/logger_test.uc tests/unit/config_test.uc tests/static.sh
git commit -m "feat: control netwatch syslog verbosity"
```

---

### Task 4: Render readable, useful interface diagnostics

**Files:**
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/diagnostics.uc`
- Modify: `tests/unit/diagnostics_test.uc`
- Modify: `packages/netwatch/netwatch/files/usr/share/netwatch/message.uc`
- Modify: `tests/unit/message_test.uc`
- Modify: `packages/netwatch/README.md`
- Modify: `tests/static.sh`

**Interfaces:**
- Produces: `render_interface_facts(snapshot, parsed, result, collected_at): string` with ordered readable scalar lines and no JSON wrapper.
- Produces: `useful_command_output(name, value): { text:string, useful:bool, reason:string|null }` that rejects help/usage-only output.
- Preserves: `render_diagnostic_report(sections, errors)` bounds/redaction contract and `context.diagnostic.text` email-only integration.

- [ ] **Step 1: Add readable-facts RED tests**

In `tests/unit/diagnostics_test.uc`, build the same Wi-Fi AP fixture seen on the router and require ordered text resembling:

```text
Selector: wifi-iface:default_radio1
Interface: AP: Helium+🎈 — radio1 / default_radio1
Reason: wireless AP or parent radio is disabled
Radio: radio1
SSID: Helium+🎈
Configured disabled: yes
Radio up: yes
Live AP present: no
Collected at: 1786647934
```

Assert absence of `{`, `"result"`, `"sources"`, `null`, duplicate selector/reason lines, and internal collection booleans that do not help diagnose the incident.

- [ ] **Step 2: Add command-usage suppression RED tests**

Feed the collector:

```text
Usage: iwinfo <device> info
iwinfo <device> scan
iwinfo <device> txpowerlist
```

Require the report to contain one concise `Wireless status: command unsupported for selected interface` or `iwinfo unavailable` line and not the usage dump. Add a real useful `iwinfo` output fixture and prove it remains. Add empty log output and prove the empty `Recent relevant logs` section is omitted.

- [ ] **Step 3: Add final email-layout RED tests**

In `tests/unit/message_test.uc`, render a failed interface alert and require:

- compact summary fields first;
- exactly one `Diagnostics` separator;
- readable fact lines and useful log lines;
- no raw JSON braces/wrapper keys;
- no `Usage:`/command list;
- no diagnostic block in recovery email;
- existing secret/redaction and 65,536-byte limits remain enforced.

- [ ] **Step 4: Run focused RED tests**

Run:

```sh
./tests/run-unit.sh tests/unit/diagnostics_test.uc tests/unit/message_test.uc
```

Expected: FAIL because current diagnostics serialize selected state as `%J` and preserve failed command usage output.

- [ ] **Step 5: Implement ordered human-readable facts**

Replace the JSON section construction with a helper that adds a line only when the scalar exists and is useful. Use fixed labels and `yes`/`no` for booleans. Keep configured and observed facts distinct. Never stringify nested objects into the email.

The selected fact helper must remain bounded by the existing section/report truncation and must pass all text through `redact_diagnostic_text()` in `render_diagnostic_report()`.

- [ ] **Step 6: Suppress help-only and empty command sections**

Classify command output after redaction/cleanup. Treat output as usage-only when nonempty lines are dominated by `Usage:`, `iwinfo <device>`, or command-name lists and the command exit status is false. For such output, add the fixed collection error and omit the raw section. Omit empty relevant-log sections without marking the collection incomplete.

- [ ] **Step 7: Give the email a clean diagnostics separator**

In `message.uc`, insert a fixed `Diagnostics:` line before the already safe diagnostic body. Avoid Markdown heading syntax in the final email body; section titles should be plain text with underline or colon, readable in simple mail clients.

- [ ] **Step 8: Update documentation and static contracts**

Document readable scalar facts, usage suppression, fresh/bounded/redacted behavior, and email-only scope in `packages/netwatch/README.md`. Update static assertions without weakening existing command-template, redaction, timeout, or non-persistence guards.

- [ ] **Step 9: Run focused and full source GREEN checks**

Run:

```sh
./tests/run-unit.sh tests/unit/diagnostics_test.uc tests/unit/message_test.uc
./tests/run-unit.sh tests/unit/*.uc
node tests/luci-email_test.js
node tests/luci-monitors_test.js
./tests/static.sh
./tests/repository-layout_test.sh
./tests/in-sdk-source_test.sh
./tests/in-sdk-behavior_test.sh
git diff --check
```

Expected: all exit zero; no SDK package compile is run yet.

- [ ] **Step 10: Commit Task 4**

```sh
git add packages/netwatch/netwatch/files/usr/share/netwatch/diagnostics.uc \
  packages/netwatch/netwatch/files/usr/share/netwatch/message.uc \
  packages/netwatch/README.md tests/unit/diagnostics_test.uc \
  tests/unit/message_test.uc tests/static.sh
git commit -m "fix: format readable netwatch interface diagnostics"
```

---

### Task 5: Cross-feature integration and review gate

**Files:**
- Modify only if a failing integration test proves a defect in Tasks 1–4.
- Test: all existing unit, LuCI, static, repository, and in-SDK source/behavior suites.

**Interfaces:**
- Consumes: completed Tasks 1–4.
- Produces: reviewed, source-green tree authorized for the one final build.

- [ ] **Step 1: Run the complete source suite once from a clean tree**

```sh
./tests/run-unit.sh tests/unit/*.uc
node tests/luci-email_test.js
node tests/luci-monitors_test.js
node --check packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/email.js
node --check packages/netwatch/luci-app-netwatch/htdocs/luci-static/resources/view/netwatch/monitors.js
./tests/package-output_test.sh
./tests/static.sh
./tests/repository-layout_test.sh
./tests/in-sdk-source_test.sh
./tests/in-sdk-behavior_test.sh
git diff --check
```

Expected: all exit zero. Docker/pinned SDK source tests may use the already cached image; do not run `build-packages.sh`.

- [ ] **Step 2: Perform scoped reviews**

Review each task commit against the spec, then review the aggregate range. Critical and Important findings require focused RED/GREEN fixes and one scoped re-review. Do not build packages while review findings remain.

- [ ] **Step 3: Commit only evidence-backed review fixes**

Use a specific commit message describing the proven issue, for example:

```sh
git commit -m "fix: preserve netwatch test request identity"
```

Do not bundle release-number or feed changes into review-fix commits.

- [ ] **Step 4: Re-run the affected focused tests and complete source suite**

Expected: all source gates exit zero and tracked status is clean. This is the authorization point for Task 6's single build.

---

### Task 6: Build, sign, publish, upgrade, and verify r4 once

**Files:**
- Modify: `packages/netwatch/netwatch/Makefile`
- Modify: `packages/netwatch/luci-app-netwatch/Makefile`
- Modify: release-name contracts in `scripts/package-output.sh`, `scripts/verify-artifacts.sh`, `tests/package-output_test.sh`, `tests/feed_test.sh`, `tests/static.sh`, `tests/repository-layout_test.sh`, and `packages/netwatch/README.md`
- Replace: `feed/x86_64/netwatch-1.1.0-r3.apk` with `feed/x86_64/netwatch-1.1.0-r4.apk`
- Replace: `feed/x86_64/luci-app-netwatch-1.1.0-r3.apk` with `feed/x86_64/luci-app-netwatch-1.1.0-r4.apk`
- Modify: `feed/x86_64/packages.adb`
- Generate ignored: `outputs/netwatch_1.1.0-r4_all.apk`
- Generate ignored: `outputs/luci-app-netwatch_1.1.0-r4_all.apk`
- Preserve: `feed/x86_64/luci-app-scheduled-backup-1.0.0-r3.apk`

**Interfaces:**
- Consumes: clean reviewed source tip, pinned SDK, ignored signing key, unchanged public key/feed URL.
- Produces: public signed r4 packages, exact three-package index, router installed r4, and live evidence for all four fixes.

- [ ] **Step 1: Update release contracts to r4 before building**

Set `PKG_RELEASE:=4` in both Netwatch Makefiles. Mechanically update only Netwatch runtime/LuCI r3 output/feed names to r4 across scripts/tests/docs. Keep version `1.1.0`, package architecture `all`, Scheduled Backup `1.0.0-r3`, public key, and feed URL unchanged.

- [ ] **Step 2: Run release-contract RED then GREEN**

First update the expected tests/fixtures and run:

```sh
./tests/package-output_test.sh
./tests/static.sh
./tests/repository-layout_test.sh
```

Record the RED failure against r3 source declarations, then update the Makefiles/scripts/docs minimally and require GREEN.

- [ ] **Step 3: Commit r4 source contracts**

```sh
git add packages/netwatch scripts tests
git commit -m "build: prepare netwatch 1.1.0-r4"
```

Require a clean tracked tree before the build.

- [ ] **Step 4: Perform the single clean pinned-SDK build**

Run exactly once after source review:

```sh
./scripts/in-sdk.sh ./scripts/build-packages.sh
./scripts/package-output.sh
./scripts/verify-artifacts.sh
```

Expected: exactly runtime r4, LuCI r4, and Scheduled Backup r3; manifests, modes, conffiles, dependencies, credential scans, JS payload equality, runtime source equality, and source archive equivalence pass.

- [ ] **Step 5: Sign fresh Netwatch feed copies exactly once**

Preserve pristine ignored copies and compare hashes before signing. Sign each fresh r4 feed copy once with pinned `adbsign --reset-signatures`. Strictly verify both before removing r3. Never retry after possible mutation without first restoring a byte-identical pristine copy.

- [ ] **Step 6: Rebuild and verify the exact index**

Run:

```sh
./scripts/rebuild-feed.sh x86_64 work/signing/private-key.pem
./tests/feed_test.sh
./scripts/verify-artifacts.sh
```

Require exactly:

- `netwatch 1.1.0-r4`
- `luci-app-netwatch 1.1.0-r4`
- `luci-app-scheduled-backup 1.0.0-r3`

Require Scheduled Backup's signed hash to remain byte-identical.

- [ ] **Step 7: Run trusted local resolution and final artifact suite**

Use the exact eight official OpenWrt 25.12.5 x86/64 repositories plus the local signed index, with no `--allow-untrusted`, and simulate exact installation of all three revisions. Re-run the full source/feed/artifact/checksum suite and verify no `.DS_Store` or tracked private key.

- [ ] **Step 8: Commit signed artifacts, merge, and push non-force**

```sh
git add feed/x86_64/netwatch-1.1.0-r4.apk \
  feed/x86_64/luci-app-netwatch-1.1.0-r4.apk feed/x86_64/packages.adb
git add -u feed/x86_64/netwatch-1.1.0-r3.apk \
  feed/x86_64/luci-app-netwatch-1.1.0-r3.apk
git commit -m "release: publish netwatch 1.1.0-r4"
```

Merge to `main`, rerun merged-main source/feed gates, fetch and assert remote ancestry, then `git push origin main` without force.

- [ ] **Step 9: Verify public bytes and trusted public resolution**

Download public key, two r4 APKs, unchanged Scheduled Backup r3, and `packages.adb`. Require byte equality with tracked main and strict signatures with the downloaded key. Require old Netwatch r3 URLs to return 404. Perform a fresh public-feed dependency simulation without `--allow-untrusted`.

- [ ] **Step 10: Upgrade the router and verify all four fixes**

On `root@10.10.11.10`, trusted-upgrade both Netwatch packages to exact r4. Preserve SMTP password/config and interface state. Verify:

1. editing and saving interface, ping, and TCP monitor modals completes without endless spinner;
2. two deliberate sequential `Save, apply, and send test` clicks yield two distinct accepted IDs, two terminal `sent` states, and two delivered test emails;
3. any red banner contains a fixed explicit reason or validated backend summary/disclosure;
4. `normal` verbosity emits transitions/mail outcomes but no per-probe or diagnostic-progress flood; `verbose` enables those entries; `errors` suppresses normal entries; restore `normal`;
5. one bounded interface failure alert has clean plain text, no raw JSON or iwinfo usage dump, and useful sanitized facts/logs;
6. service is enabled/running, exact r4 installed, five RPC methods present, config modes remain `0600`, `tls=tls` and `tls_insecure=1` remain, no UCI changes or task temp files remain.

External test emails require the user's direct approval immediately before the live two-email acceptance step. Do not send recovery or duplicate alert emails beyond the approved count.

- [ ] **Step 11: Record final evidence**

Write a release/acceptance report under `.superpowers/sdd/2026-08-25-netwatch-mail-ui-logging-fixes/` containing commit IDs, public hashes, package/index signature results, installed versions, sanitized RPC states, log-level observations, and UI outcomes. Do not include credentials, recipient addresses, or raw diagnostic secrets.
