# Netwatch LuCI and SMTP fixes design

## Scope

Release Netwatch `1.1.0-r2` for OpenWrt 25.12 x86/64 with four focused corrections:

- Restore authenticated LuCI access to live status, interface inventory, manual checks, and test email.
- Add an explicit, default-off option to disable SMTP TLS certificate verification.
- Make the stored-password behavior clear without returning the stored SMTP password to the browser.
- Make test-email delivery asynchronous so the request does not exceed LuCI's RPC timeout.

The existing monitor model, interface diagnostics, alert schedules, signed repository URL, and public key remain unchanged.

## Confirmed root causes

LuCI's authenticated ubus controller adds `ubus_rpc_session` to every method argument object after checking the session ACL. Netwatch publishes strict ucode method schemas that do not declare this field. The daemon therefore accepts direct `ubus call` requests but rejects the equivalent LuCI requests with `UBUS_STATUS_INVALID_ARGUMENT` (`2`). This affects all four methods: `status`, `interfaces`, `check`, and `test_email`.

SMTP delivery has two independent configuration requirements on the tested router. Port 465 requires TLS from connection start, while the server certificate is issued by a private CA absent from OpenWrt's system trust store. A credential-preserving diagnostic using implicit TLS and the observed certificate fingerprint received SMTP status `250`, proving that the stored credentials and recipient are valid.

The current password field renders the literal value `********`. The reveal control consequently reveals only that placeholder, not the password. The current synchronous `test_email` method may defer its ubus reply for up to 65 seconds even though LuCI's RPC path times out after approximately 30 seconds.

## Ubus compatibility

Every published Netwatch method schema will declare the optional string argument `ubus_rpc_session`:

- `status`: `ubus_rpc_session`
- `interfaces`: `ubus_rpc_session`
- `check`: `id`, `ubus_rpc_session`
- `test_email`: `recipient`, `ubus_rpc_session`

The daemon will ignore the session value. Authorization remains entirely in rpcd through the existing `luci-app-netwatch` ACL. The value will never be logged, persisted, returned, or passed to subprocesses.

The status view will continue treating status and interface inventory as independent inputs. An unavailable inventory may remove friendly interface labels, but it must not disable host status or manual checks when `status` itself succeeds.

## TLS certificate bypass

The SMTP UCI section gains `tls_insecure`, normalized as a boolean with a default of false. LuCI presents it as:

> Disable TLS certificate verification (insecure)

The help text will warn that this permits man-in-the-middle attacks and is intended only for servers using a certificate that cannot be validated through the router's trust store. The field is shown for STARTTLS and connection-start TLS, and hidden when TLS is disabled.

When TLS is enabled:

- `tls_insecure=0` or an absent option renders `tls_certcheck on` and the system `tls_trust_file`.
- `tls_insecure=1` renders `tls_certcheck off` and omits the trust-file directive.

When TLS is disabled, neither certificate-check nor trust-file directives are rendered. The bypass is never enabled automatically during package installation or configuration migration.

## Password behavior

LuCI will never load the stored SMTP password into the form value. The password input starts empty and uses a contextual placeholder and help text indicating whether a password is already stored. Leaving it empty preserves the stored value; entering text replaces it; the existing clear-password checkbox explicitly removes it.

The reveal control will therefore reveal newly entered text only. No RPC method accepts SMTP credentials, and no stored secret is returned to the browser.

## Asynchronous test email

`test_email` will synchronously reload the committed Netwatch configuration, validate the recipient and mail configuration, start delivery, and immediately return `{ ok: true, id }`. It will not defer the ubus request until msmtp exits.

Public status gains a bounded `mail_test` object:

- `id`: monotonically increasing daemon-local integer
- `state`: `sending`, `sent`, or `failed`
- `started`: Unix timestamp
- `completed`: Unix timestamp or null
- `error`: null or the fixed string `mail delivery failed`

Only one mail delivery may run at a time. A busy or invalid request returns a fixed, secret-free error without changing an active test. The delivery callback updates `mail_test`, the existing `mail_error`, and the volatile public status file. Test state is not persisted across daemon restarts.

After saving and applying the form, LuCI calls `test_email`, keeps the button disabled, and polls `status` for the returned ID until `sent` or `failed`. It shows a success notification for `sent`, a fixed failure notification for `failed`, and a timeout notification if no terminal result appears within a bounded interval. It never displays remote exception text or SMTP credentials.

## Compatibility and migration

Existing UCI files remain valid. An absent `tls_insecure` means certificate verification remains enabled. Existing monitor incidents, alert counters, interface selectors, and SMTP passwords retain their current behavior. All changes are architecture-independent and both package Makefiles advance only `PKG_RELEASE` from `1` to `2`.

For the live router verification only, after installing the signed upgrade, the SMTP mode will be set to connection-start TLS and the user-requested bypass will be enabled. The stored password will not be read, printed, or replaced.

## Test and release requirements

Automated tests will first fail and then cover:

- All four ubus schemas accept LuCI's injected session argument while preserving their existing public arguments.
- `tls_insecure` defaults off and normalizes supported UCI boolean forms safely.
- Verified TLS renders `tls_certcheck on` plus the system CA file.
- Bypassed TLS renders `tls_certcheck off` without a CA file.
- TLS-disabled output contains no certificate directives.
- The password field does not render a secret-shaped placeholder and preserves an existing password on an empty save.
- Test email returns before delivery completion and exposes only bounded asynchronous state.
- LuCI polls the matching test ID and keeps the button busy until a terminal result.
- Status and interface inventory RPC failures remain isolated.

The complete static, ucode unit, rpcd, LuCI, package-content, and SDK build suites must pass. Both APKs will be signed once with the existing project key, verified against the public key, published into the existing nested x86_64 feed, downloaded from raw GitHub, compared byte-for-byte, and indexed in a fresh APK database.

Live verification on `10.10.11.10` must demonstrate through the authenticated HTTP ubus path that status, interface inventory, and `check` succeed; the LuCI interface picker contains the router's networks, devices, radios, and custom-named APs; and a test email reaches terminal state `sent` under implicit TLS with the explicitly enabled bypass.
