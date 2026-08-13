# Netwatch mail result, readable diagnostics, and log verbosity design

## Goals

Fix three related user-visible problems without broad refactoring:

1. `Save, apply, and send test` must never show an unexplained generic red
   notification, especially when some other Netwatch alert email was delivered.
2. Interface alert email diagnostics must be readable plain text rather than
   raw JSON and command usage noise.
3. A global LuCI option must control daemon syslog verbosity, with `normal` as
   the default so routine checks do not flood the log.

## Test-email result flow

The LuCI action remains asynchronous: save UCI, apply it, request a test mail,
then poll the matching test ID until `sent`, `failed`, or timeout. Each phase
will have a fixed safe failure reason. The error banner will always use:

`Test email could not be sent: <reason>`

Known backend failures continue to use their validated six-field failure object
and collapsed technical disclosure. Client-side save, apply, RPC, polling, and
timeout failures use fixed translated explanations and never render raw
exceptions, configuration values, credentials, response bodies, or HTML.
Only the matching terminal `sent` state produces the success notification.

This distinction also prevents an automatic monitor alert triggered near a
configuration apply from being mistaken for the requested test email.

## Global log verbosity

Add `log_verbosity` to the global `netwatch.main` UCI section and Email page:

- `errors`: configuration, persistence, probe-start, and mail-delivery errors.
- `normal` (default): errors plus service lifecycle/config reloads, monitor state
  transitions, and final mail outcomes.
- `verbose`: normal plus every probe result and diagnostic start/completion.

All daemon messages will go through one level-aware helper. Existing syslog
priorities remain meaningful; verbosity only decides whether a message is
emitted. Invalid or absent UCI values normalize to `normal`. This is global and
applies after configuration reload without a separate per-monitor setting.

## Readable interface alert email

Keep standards-compatible plain text. The message body will contain:

- concise monitor/interface identity, selector, reason, times, duration, and
  alert count;
- human-readable evidence lines for radio, SSID, configured/live presence,
  interface name, device state, and other available scalar facts;
- a clearly separated diagnostics section containing only useful command
  output and relevant logs.

Do not emit compact JSON objects, internal wrapper fields, null/unavailable
values, duplicate facts, or tool usage/help output. Diagnostics remain freshly
collected per due failure alert, bounded, redacted, email-only, and omitted from
recovery messages. If a command returns only usage/help text, record a concise
`unavailable` or `command unsupported` line rather than including the usage
dump.

## Security and compatibility

Do not enable `msmtp --debug`, expose SMTP credentials, expose diagnostics via
status/ubus, or weaken existing byte caps/redaction. Preserve OpenWrt 25.12.5,
ucode, LuCI JavaScript, UCI upgrade, and existing r3 configuration compatibility.

## Verification and release efficiency

Use focused RED/GREEN tests for each behavior before implementation, then run
the existing unit, LuCI, static, packaging, and in-SDK source/behavior gates.
Inspect the live router only after source tests pass. Perform one final package
build/sign/index/publication cycle, then upgrade and verify the router. Avoid
repeated clean SDK rebuilds during development.
