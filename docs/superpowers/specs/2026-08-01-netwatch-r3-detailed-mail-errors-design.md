# Netwatch r3 detailed mail errors and monitor display design

Date: 2026-08-01  
Target: OpenWrt 25.12.5, x86/64  
Packages: `netwatch` and `luci-app-netwatch` 1.1.0-r3

## Problem statement

Netwatch 1.1.0-r2 has three confirmed problems:

1. The Monitors grid displays the host `target` column for every monitor. An
   interface monitor has no host target, while its `interface_selector` field
   is modal-only, so the row displays `none` instead of the selected interface
   or AP.
2. Automatic alerts pass a raw recipient string into `render_message()`.
   `message_recipients()` attempts to call an exported-only
   `split_recipients` binding that is not available inside the installed ucode
   module. Rendering fails before msmtp starts, retries every configured mail
   backoff interval, and leaves the successful-email counter at zero. The
   broad render catch incorrectly reports this as `recipient is invalid`.
3. Test-email failures are intentionally reduced to a generic red banner.
   This hides the delivery stage, msmtp exit category, and sanitized transport
   reason needed to diagnose failures.

The router evidence also showed a real msmtp `EX_IOERR` network-read timeout.
The purpose of r3 is not to reinterpret or suppress transport failures; it is
to report their exact sanitized reason to the user.

## Scope

r3 will:

- show a friendly interface/AP target in the Monitors grid;
- repair automatic failure and recovery message rendering for raw recipient
  strings;
- capture, classify, sanitize, persist, and display detailed test-email
  failures;
- retain a concise red summary while putting technical data in a collapsed
  disclosure control;
- rebuild, sign, publish, upgrade, and verify both Netwatch packages.

It will not add SMTP retries to the manual test button, change alert timing or
caps, expose raw logs, enable msmtp debug output, or change the configured TLS
policy.

## Monitor grid

The grid will use a single display-only Target column:

- ping and TCP monitors show their configured host/IP target;
- interface monitors show the friendly inventory label for the saved selector;
- a saved selector missing from live inventory shows `Missing: <selector>`;
- if no label can be resolved, the stable selector is shown instead of `none`.

The editable host target and grouped interface selector remain in the modal
editor with their existing validation and dependencies. The display column
must not create or write a UCI option.

## Recipient rendering correction

Recipient parsing will have one private local parser used by both:

- the exported `split_recipients()` API; and
- `message_recipients()` when `render_message()` receives a string.

This avoids relying on an exported function name as an intra-module binding.
The same address validation, comma splitting, trimming, injection rejection,
and recipient limits remain in force.

Render failures will no longer be unconditionally labeled `recipient is
invalid`. Internal alert status will use a bounded, stage-specific sanitized
summary such as `message rendering failed`. No thrown exception text is made
public without passing through the failure sanitizer.

## Delivery failure data flow

Each msmtp delivery receives private message, result, and stderr files under
`/var/run/netwatch`, all mode `0600` and uniquely named. The existing delivery
serialization remains unchanged.

The normal msmtp stderr stream is captured without `--debug`. At completion:

1. Netwatch reads at most 4096 bytes.
2. The file is closed and unlinked on success, failure, timeout, cancellation,
   shutdown, and setup exceptions.
3. A pure sanitizer converts the exit code and stderr into a bounded public
   failure object.
4. Only the sanitized object reaches volatile status or LuCI.

Message bodies, generated msmtp configuration, passwords, RPC session tokens,
and signing material are never included in diagnostic output.

## Public failure contract

The existing `mail_test` fields remain backward-compatible. On failure it adds
a bounded `failure` object:

```text
mail_test = {
  id,
  state,
  started,
  completed,
  error,       // concise sanitized summary retained for compatibility
  failure: {
    stage,     // config, render, spawn, dns, network, tls, auth, smtp, timeout, process
    summary,   // concise user-facing sentence, maximum 192 bytes
    detail,    // sanitized technical detail, maximum 512 bytes
    exit_code, // integer or null
    exit_name, // bounded symbolic category or null
    smtp_status // integer or null
  }
}
```

The object contains exactly these fields. Unknown or malformed internal data
falls back to `stage=process`, a fixed summary, empty detail, and null numeric
fields. Successful and sending tests expose `failure=null`.

Immediate pre-delivery rejection from `test_email` uses the same failure shape
in its RPC response, so configuration, recipient, render, busy, and spawn
failures can be displayed without waiting for polling.

## Classification and sanitization

Classification uses trusted local facts first: setup stage, process timeout,
numeric exit code, and parsed SMTP status. Sanitized stderr is supplemental.
Recognized categories include DNS resolution, network I/O/timeout, TLS,
authentication, SMTP rejection, configuration, and process failure.

Before public exposure, the sanitizer:

- strips control characters and collapses whitespace;
- removes the leading msmtp program prefix;
- redacts email addresses, usernames, authentication values, passwords,
  tokens, and credential-like key/value pairs;
- never includes the message body or command line;
- bounds every field independently;
- treats all server-provided text as untrusted text rendered through LuCI DOM
  nodes, never HTML.

The configured SMTP hostname and numeric port may remain visible because they
are already displayed on the same authenticated configuration page. Envelope
addresses and account usernames remain redacted.

## LuCI presentation

The existing top notification remains red and begins with a concise summary,
for example:

```text
Test email failed: SMTP network I/O timed out.
```

The notification contains a native collapsed `<details>` element:

```text
Show technical details
  Stage: network
  Detail: network read error: the operation timed out
  Exit: EX_IOERR (74)
  SMTP status: unavailable
  Test ID: 4
```

The user explicitly expands the spoiler to view details. Success notifications
remain concise and contain no disclosure. The test button remains busy until a
matching terminal state or the existing bounded UI timeout. RPC exceptions
that did not originate from Netwatch's sanitized failure contract continue to
show a fixed local error and never expose exception text.

## Alert behavior

Failure and recovery alerts continue to obey per-monitor initial delay, repeat
interval, maximum count, recovery option, and global retry backoff. A rendering
or transport failure does not increment the email counter. A successful retry
increments it exactly once. Status retains the most recent sanitized global
mail summary; no secret-bearing detail is persisted.

## Testing

Tests must be executable and test real production code.

Runtime tests will prove:

- `render_message()` accepts a raw valid recipient string without the caller
  importing `split_recipients`;
- invalid recipients and header injection remain rejected;
- msmtp success, nonzero exit, timeout, spawn failure, and cleanup paths close
  and unlink every private file;
- exit/stderr classification produces the intended public failure shape;
- passwords, usernames, email addresses, tokens, controls, oversized text, and
  hostile SMTP text are redacted or bounded;
- alert retry counters advance only after successful delivery.

The real-view LuCI harness will prove:

- the Monitors grid renders a friendly AP/interface target rather than `none`;
- the failure banner shows the concise sanitized summary;
- technical details are collapsed by default and expand through a `<details>`
  element;
- all fields are inserted as text nodes;
- malformed or secret-bearing RPC exceptions still produce only fixed local
  text;
- success, matching-ID polling, stale-ID rejection, busy state, and timeout
  behavior remain intact.

Artifact verification will cover the exact package manifests, modes,
conffiles, dependencies, source archive, signatures, and credential scan.

## Release and live acceptance

Both packages become 1.1.0-r3. Pristine APKs are built with the pinned OpenWrt
25.12.5 x86/64 SDK, feed copies are signed exactly once, and the unchanged
nested `packages.adb` URL is rebuilt and strictly verified with the existing
public key.

After trusted router upgrade:

- the Monitors page shows the configured friendly AP/interface target;
- a controlled test failure displays a concise red summary with collapsed,
  sanitized technical details and no secrets;
- a subsequent successful test reaches `sent` and SMTP status 250;
- an interface incident successfully sends its permitted alert and changes the
  counter from `0/1` to `1/1`;
- public GitHub bytes, signatures, fresh-repository resolution, installed
  versions, service state, and absence of `.DS_Store` are verified.

