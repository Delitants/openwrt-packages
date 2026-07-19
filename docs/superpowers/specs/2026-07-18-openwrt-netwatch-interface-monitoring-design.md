# OpenWrt Netwatch Interface Monitoring Design

## Summary

Extend Netwatch with a third monitor type, `interface`, for OpenWrt logical networks, Linux network devices, Wi-Fi radios, and individual Wi-Fi AP/SSID interfaces. The LuCI monitor form presents these objects in a grouped dropdown, including configured objects that are disabled or currently absent. Interface failures use the existing incident thresholds and email schedule. Every due failure email receives a freshly collected, extensive but bounded diagnostic report that explains the failure without exposing Wi-Fi keys, SMTP credentials, or other secrets.

The feature is an additive update to the existing OpenWrt 25.12.5 x86/64 packages. Existing ping and TCP monitors, SMTP settings, notification timing, and recovery behavior remain compatible. The release will be published as signed `netwatch` and `luci-app-netwatch` version `1.1.0-r1` packages in the existing nested GitHub APK feed.

## Goals

- Let a user monitor logical OpenWrt network interfaces and physical or virtual Linux network devices.
- Let a user monitor a complete Wi-Fi radio or one configured AP/SSID interface independently.
- List both live runtime objects and configured objects that are absent, down, or disabled.
- Display configured SSIDs and custom AP names in the selector, while disambiguating duplicate SSIDs.
- Detect administrative disablement, runtime absence, link or carrier loss, and wireless startup failures with specific reasons.
- Apply the existing check interval, consecutive-failure threshold, initial email delay, repeat interval, maximum-email cap, recipient override, and recovery-email setting without adding a second scheduler.
- Collect fresh diagnostics immediately before each due failure email, including repeat emails during the same incident.
- Send a useful failure email even when part or all of diagnostic collection fails or times out.
- Keep diagnostics bounded, redact secrets, and avoid arbitrary command execution through LuCI or ubus.
- Show the selected interface identity, current health, failure reason, and compact interface state on the LuCI status page.
- Preserve all existing ping, TCP, SMTP, and incident behavior.

## Non-goals

- Monitoring throughput thresholds, traffic quotas, packet error rates, signal-strength thresholds, associated client counts, DHCP success, Internet reachability, or routing correctness.
- Automatically changing interface state, restarting Wi-Fi, reloading the network, rebooting the router, or running user-defined remediation commands.
- Event-driven monitoring through netifd hotplug scripts. Interface state is sampled on the monitor's existing interval.
- Arbitrary user-entered interface selectors. Interface monitors select an inventory item through LuCI; syntactically valid saved selectors remain monitorable if the underlying object is later removed.
- Saving full diagnostic reports or long-term interface history to flash.
- Attaching binary files or unbounded system logs to email.
- Exposing wireless credentials, private keys, SMTP passwords, RADIUS secrets, or unrelated configuration and logs.

## Architecture

The existing ucode daemon remains the only scheduler and incident owner. Interface monitoring adds four focused runtime responsibilities:

1. An inventory module merges UCI configuration and current ubus/kernel state into normalized selectable objects.
2. An interface probe module evaluates one stable selector and returns a structured health result.
3. A diagnostic module collects a fresh, bounded report when a failure email is actually due.
4. The existing message module renders interface failure and recovery content from the probe result and optional diagnostic report.

The daemon exposes one new read-only `netwatch.interfaces` ubus method for LuCI. The method accepts no command, path, or selector supplied by the caller. It returns the normalized inventory and does not return secret UCI values. Existing `status`, `check`, and `test_email` operations remain unchanged except that `check` can schedule an interface probe.

Interface probes run through the existing isolated task boundary and one-probe-per-monitor rule. Normal checks perform only bounded state queries and small sysfs reads. Expensive logs and command output are collected only when an email is due, not on every polling interval.

## Configuration model

The existing UCI `monitor` section gains `interface` as an allowed `type` value and one type-specific option:

- `interface_selector`: the stable selector of the chosen logical network, Linux device, Wi-Fi radio, or Wi-Fi AP interface.

For `interface` monitors, `interface_selector` is required and `target`, ping thresholds, packet count, and TCP port are ignored. For `ping` and `tcp` monitors, the existing `target` and type-specific validation remain unchanged. A syntactically valid selector is not rejected merely because its object is absent at reload time; absence is a monitorable failure condition.

All existing common monitor options apply unchanged:

- `enabled`
- `name`
- `interval`
- `timeout`
- `failures`
- `initial_delay`
- `repeat_interval`
- `max_alerts`
- `recovery_email`
- `recipients`

Allowed selectors have exactly one of these forms:

- `network:<uci-network-section>`
- `device:<linux-interface-name>`
- `wifi-radio:<uci-radio-section>`
- `wifi-iface:<uci-wireless-iface-section>`

The prefix must be one of the four literals. The suffix must be non-empty and pass a conservative identifier grammar suitable for an OpenWrt UCI section or Linux interface name. Whitespace, control characters, path separators, shell metacharacters, and option-like leading hyphens are rejected. Selector strings are data keys only and are never interpolated into an unrestricted shell command.

No migration is required for existing configuration. Existing ping and TCP sections parse exactly as before. An invalid interface monitor is disabled individually and its validation error is shown in status without preventing other monitors from running.

## Interface inventory

### Data sources

The inventory merges these sources:

- `/etc/config/network` for configured logical networks and named devices.
- `/etc/config/wireless` for configured radios and `wifi-iface` AP/SSID sections.
- netifd ubus status for logical-network, device, radio, and wireless-interface runtime state.
- `/sys/class/net` for live Linux device presence and basic link attributes.

Configuration supplies stable identity and friendly naming. Runtime sources supply current device names and state. An unavailable source does not make the entire inventory call fail; returned entries include available information and the response includes sanitized source-error metadata.

### Candidate groups

The RPC result contains four ordered groups:

1. OpenWrt networks
2. Linux devices
3. Wi-Fi radios
4. Wi-Fi APs / SSIDs

Configured entries are emitted even when disabled, absent, or not initialized. Live-only Linux devices are also emitted. A configured object and its matching live object are merged under one stable selector. Entries are deduplicated by selector, not display label.

Each candidate contains only normalized fields needed by LuCI:

- `selector`
- `kind`
- `label`
- `configured_name`
- `live_device`
- `configured`
- `present`
- `enabled`
- `state`
- `detail`

Missing or unknown facts use `null` rather than invented healthy values. The inventory does not contain raw UCI sections or credentials.

### Friendly labels and custom AP names

Logical networks use their UCI section and any available description. Linux devices use their current device name. Radios show the radio section and available hardware/band detail.

An individual Wi-Fi AP entry uses its configured SSID as the primary friendly name. Its radio section and UCI `wifi-iface` section are always included to make identity stable and to disambiguate duplicate SSIDs. If a live Linux device is known, it is appended as additional context. Representative labels are:

- `AP: Office WiFi — radio0 / default_radio0`
- `AP: Office WiFi — radio1 / guest_5g (phy1-ap1)`
- `AP: unnamed — radio0 / wifinet3`

The `wifi-iface:` suffix is the UCI cursor's section identifier: an explicit section name when present, or UCI's generated `cfg...` identifier for an anonymous section. The inventory never substitutes a list position such as `@wifi-iface[0]`. If configuration restructuring changes an anonymous section's generated identifier, the old selector becomes missing and fails visibly instead of silently binding the monitor to a different AP.

Custom SSIDs are never replaced by generic `phy` device names. If the selected object later disappears from both configuration and runtime inventory, LuCI preserves the saved selector as a synthetic `Missing: <selector>` choice so viewing or saving an unrelated field does not silently change the monitor.

## Interface health evaluation

Every interface probe returns a normalized result with:

- `ok`
- `reason`
- `summary`
- `selector`
- `kind`
- `configured_name`
- `live_device`
- `observed_at`
- a bounded `evidence` object containing only structured, non-secret state

The probe distinguishes confirmed negative state from unavailable evidence. It never reports success merely because a query failed.

### Failure reasons

The public reason vocabulary is:

- `administratively_disabled`: the selected configured object or a required parent radio is explicitly disabled or prevented from autostarting.
- `interface_absent`: the selected logical network or Linux device cannot be found in its required runtime source.
- `unavailable`: the logical network exists but netifd reports it unavailable.
- `link_down`: the device exists but is not operationally up.
- `carrier_lost`: carrier is explicitly reported as absent on a device for which carrier applies.
- `wireless_radio_down`: a configured radio exists but is not running.
- `wireless_ap_down`: a configured AP/SSID interface or its expected BSS is not running.
- `wireless_initialization_failed`: netifd or wireless runtime state identifies a setup or initialization failure.
- `status_unavailable`: required state could not be obtained reliably because a source failed, timed out, or returned malformed data.

The `summary` adds safe human-readable detail but does not create new scheduler semantics. Incident tracking continues to treat any `ok: false` result as a failure even if the reason changes during the incident.

### Logical OpenWrt networks

A `network:` selector is healthy only when the configured or runtime logical interface exists, is not administratively disabled, netifd reports it available, and its operational `up` state is true. Explicit administrative disablement takes precedence, followed by absence, unavailability, and link-down state. Failure to obtain the required netifd status yields `status_unavailable`.

### Linux devices

A `device:` selector is healthy only when the device is present and operationally up. If a carrier value is reported and is applicable, carrier must be present. Administrative down state maps to `link_down`; an explicitly absent carrier maps to `carrier_lost`. Bridges, loopback, tunnels, and other devices for which carrier is not reported are not failed solely because carrier is unknown. If neither runtime state nor sysfs can establish presence, the result is `interface_absent`; source failures that make the answer indeterminate yield `status_unavailable`.

### Wi-Fi radios

A `wifi-radio:` selector is failed as `administratively_disabled` when the radio's UCI configuration explicitly disables it. Otherwise the configured radio must have coherent wireless runtime state and be running. An explicit runtime initialization error maps to `wireless_initialization_failed`; a non-running radio maps to `wireless_radio_down`; an indeterminate query maps to `status_unavailable`.

### Wi-Fi AP/SSID interfaces

A `wifi-iface:` selector follows its UCI section rather than an unstable generated `phy*-ap*` name. It fails as `administratively_disabled` if the AP section or its parent radio is explicitly disabled. Otherwise the AP must be present in wireless runtime state and its BSS/live device must be running. An explicit parent or BSS initialization error maps to `wireless_initialization_failed`; a missing or stopped BSS maps to `wireless_ap_down`; an indeterminate query maps to `status_unavailable`.

## Incident and alert integration

Interface results enter the existing incident state machine without a parallel state model:

1. Failed checks must reach the configured consecutive-failure threshold.
2. The first email is due after the configured `initial_delay`.
3. `repeat_interval` controls one-time, 10-minute, 30-minute, or hourly repeat delivery.
4. `max_alerts` limits successfully sent failure emails per incident.
5. SMTP failures use the existing retry backoff and do not consume the incident cap.
6. Recovery sends one recovery message only when enabled and at least one failure email was successfully sent.

When an interface failure email becomes due, the daemon launches a fresh diagnostic collection for the current selected object. The probe result used by the incident and the fresh report are passed to message rendering. Repeat emails recollect diagnostics rather than reusing the first report. Diagnostic collection time does not count as a successful send and cannot bypass the existing cap or retry rules.

If the interface recovers while a diagnostic task is running, the already-due failure email may still describe the observed failure, and the next completed health check performs the normal recovery transition. Only one email or diagnostic task for a monitor may be active at a time.

## Diagnostic collection

### Collection policy

Diagnostics are collected only for due interface failure emails. Each collection has a 15-second hard deadline and a 64 KiB rendered-report limit. Individual command or data-source sections are truncated before the total limit, and the report identifies every truncated, failed, unavailable, or timed-out section. Log excerpts are limited to the newest 200 relevant lines before final size bounding.

The collector uses fixed operations selected by interface kind. It does not accept a command string from UCI, ubus, or LuCI. It collects available subsets of:

- Friendly identity, stable selector, configured state, live device, failure reason, and current probe evidence.
- A whitelist of relevant `/etc/config/network` and `/etc/config/wireless` values.
- Relevant netifd logical-interface, device, radio, and BSS state obtained through ubus.
- `/sys/class/net/<device>` presence, operstate, carrier where applicable, MTU, MAC address, counters, and driver/module link where available.
- Address and link details from an available fixed system networking utility.
- `iwinfo` status for the selected radio or BSS when `iwinfo` is installed and supports the object.
- Recent matching `netifd`, hostapd, wpa_supplicant, wireless-driver, and kernel messages obtained from fixed log sources.
- Collector environment facts and sanitized errors explaining missing optional tools or unavailable sources.

The collector targets only the selected object, its required parent/child relationship, and closely related logs. It does not dump all UCI configuration or unrelated system logs.

### Secret handling

Structured UCI output is allowlisted rather than dumped and then redacted. Safe fields include identity, mode, network binding, protocol, device, SSID, band/channel, country, HT mode, encryption type, disabled/autostart state, metric, and MTU. Secret-bearing fields are excluded, including names containing `key`, `password`, `passphrase`, `secret`, `private`, `sae`, `radius`, or `credential` where the value could authenticate or decrypt.

Log and command text receives a second redaction pass for common key, password, PSK, SAE, RADIUS, authorization, SMTP, and private-key patterns. Control characters are normalized. Email header values continue to use the existing CR/LF rejection. No SMTP configuration is included in interface diagnostics.

### Degraded diagnostics

A collector failure, missing optional tool, malformed response, or 15-second timeout never suppresses the alert. The email contains the current failure reason, all successfully collected sections, and a clear `Diagnostic collection incomplete` section listing sanitized errors. If no detailed source succeeds, the base failure email is still sent.

Recovery email uses a concise fresh health snapshot with recovered identity, live device, current state, and incident duration. It does not include full logs or the failure diagnostic report.

## Email content

Interface failure subjects identify the router, monitor name, friendly interface/AP name, and failure transition. The body includes:

- Monitor name and stable selector.
- Interface kind, configured name, and current live device.
- Failure reason and human-readable summary.
- Incident start, current duration, last check time, and alert sequence against the configured cap.
- Current compact structured evidence.
- The fresh diagnostic report or its incomplete-collection notice.

Repeat messages use the same structure with a new observed time and newly collected diagnostic data. Recovery subjects identify recovery, and recovery bodies include the concise recovered snapshot and total incident duration.

## LuCI behavior

### Monitors page

The existing test-type list adds `Interface state` alongside Ping and TCP port. Selecting it hides host, DHCP-lease, ping, and TCP-specific fields and shows a required grouped interface dropdown populated by `netwatch.interfaces`.

The dropdown displays OpenWrt networks, Linux devices, Wi-Fi radios, and Wi-Fi APs/SSIDs as distinct groups. Disabled, down, and absent configured objects remain selectable and show concise state hints. Custom SSIDs are primary AP labels; radio, UCI section, and available live device disambiguate duplicates. The saved synthetic missing option is displayed when an object was removed after configuration.

All common timing and notification controls remain visible and retain their existing validation. Browser-side validation rejects an empty selector, while daemon-side validation remains authoritative. If inventory loading fails, LuCI shows the sanitized error and preserves any saved selector instead of replacing it.

### Status page

An interface monitor row shows:

- Friendly network/device/radio/AP name.
- Stable selector and current live device when known.
- Current monitor state and specific failure reason.
- Last check time and last transition time.
- A compact link, carrier, radio, or AP summary appropriate to the selected kind.
- Consecutive-failure count.
- Incident start and duration when failed.
- Successfully sent failure-email count and configured cap.
- Configuration or state-query errors.

The existing `Check now` action schedules an immediate interface probe. It does not collect full diagnostics unless that check leads to an email that is due under the configured incident schedule.

### RPC and access control

The rpcd ACL adds read permission for the exact `netwatch.interfaces` method. The method is available to the same LuCI Netwatch access role as status. It exposes normalized inventory only, requires no caller-supplied command or filesystem path, and returns no raw secret configuration.

## Error handling and observability

Daemon logs identify the monitor ID, friendly identity, selector, transition, normalized reason, diagnostic start/outcome, truncation or timeout, alert attempt, and mail outcome. Logs never contain diagnostic bodies or secret source values.

Failure of one inventory source is recorded and does not crash the daemon. A normal probe returns `status_unavailable` when required evidence is indeterminate. A diagnostic failure is recorded separately from the health result and mail result. The LuCI status response remains bounded and contains only the compact last probe result; full diagnostic reports are not stored in or returned by status.

Runtime state continues to use the existing volatile state directory and atomic update behavior. No new diagnostic data is written to flash. Reload retains incident state for unchanged monitor section IDs, including interface monitors, and validates a changed selector before using it.

## Security and resource limits

- Selectors use strict prefix and suffix validation.
- Inventory and health code perform fixed ubus/sysfs operations; no generic ubus or shell proxy is added.
- Any external diagnostic utility is invoked from a fixed command template with a validated interface identifier and a hard timeout.
- UCI diagnostic fields are allowlisted, text is redacted again before email, and SMTP settings are excluded.
- Diagnostic output is limited to 64 KiB and 200 relevant log lines with a 15-second overall deadline.
- Only one probe, diagnostic collection, or email operation for a monitor is active at a time.
- Full reports exist only in task memory and the outgoing email path; they are not persisted in status files or flash configuration.
- Existing root-only UCI, temporary `msmtp`, email-header, recipient, and credential protections remain in force.

## Testing strategy

Implementation follows test-driven development: each behavior is introduced by a focused failing test before production code.

### Configuration and selector tests

- Accept the four selector kinds and representative valid UCI/device identifiers.
- Reject missing suffixes, unknown prefixes, whitespace, control characters, path syntax, option-like names, and shell metacharacters.
- Require `interface_selector` only for interface monitors.
- Preserve current ping/TCP parsing and defaults.
- Accept a syntactically valid selector even when inventory cannot currently resolve it.

### Inventory tests

- Merge configured and live logical networks and devices without duplicates.
- Include configured disabled or absent networks, devices, radios, and AP sections.
- Include live-only Linux devices.
- Map a generated BSS device back to its stable `wifi-iface` selector.
- Prefer custom SSID labels and disambiguate duplicate SSIDs by radio/UCI section/live device.
- Produce an unnamed AP label when no SSID exists.
- Return partial inventory plus sanitized source errors when one source fails.
- Never expose secret UCI values.

### Health-evaluation tests

- Cover healthy and failed logical networks, Linux devices, radios, and APs.
- Cover every public failure reason and its precedence.
- Treat explicit disabled configuration as a failure.
- Treat removed configured APs and missing live devices as failures.
- Do not require carrier when the device kind does not report it.
- Treat malformed, failed, or timed-out required state queries as `status_unavailable`.
- Confirm no overlapping probe for one monitor.

### Diagnostic tests

- Select only data relevant to each selector kind.
- Include safe structured config, ubus state, sysfs/link facts, optional wireless facts, and filtered logs.
- Exclude Wi-Fi keys, passphrases, RADIUS secrets, SMTP credentials, private keys, and unrelated UCI fields.
- Redact representative secret patterns from log and command output.
- Enforce per-section and 64 KiB total bounds plus the 200-line log bound.
- Enforce the 15-second hard deadline.
- Render partial results and sanitized source errors.
- Send the base email when the entire diagnostic collector fails.
- Recollect diagnostics for every repeat email.

### Incident, message, and status tests

- Reuse existing consecutive-failure, initial-delay, repeat, maximum-alert, SMTP-retry, and recovery rules for interface results.
- Render interface failure and recovery subjects and bodies with friendly and stable identities.
- Keep full diagnostic output out of persisted/public status.
- Show current failure reason, compact evidence, incident counters, and live device.
- Confirm recovery email uses a concise fresh snapshot without failure logs.

### LuCI, ACL, and package tests

- Verify conditional monitor fields for ping, TCP, and interface types.
- Verify grouped candidate rendering, custom/duplicate SSID labels, disabled/absent hints, missing saved-selector preservation, and load-error behavior.
- Verify the exact read-only ACL for `netwatch.interfaces`.
- Parse all JavaScript and JSON declarations and validate installed paths and dependencies.
- Scan source and package contents for unsafe command construction and secret exposure.
- Run all existing unit, static, package-output, feed-layout, and installability tests to prevent regression.

## Release and publication

Both packages are released as `1.1.0-r1` for OpenWrt 25.12.5 `x86_64` and signed with the existing Netwatch feed key. The release process will:

1. Build clean artifacts with the existing OpenWrt 25.12.5 x86/64 SDK workflow.
2. Run the complete test suite and package metadata/layout checks.
3. Sign each pristine APK exactly once and strictly verify it with the published public key.
4. Replace obsolete Netwatch package revisions in `feed/x86_64` while preserving unrelated packages in the nested repository feed.
5. Rebuild and sign the single `feed/x86_64/packages.adb` index.
6. Verify that no private key or `.DS_Store` file is tracked or published.
7. Push the source, signed APKs, key, and index to the existing GitHub repository.
8. Download the raw public key, APKs, and index from GitHub and compare them with the local release files.
9. Initialize a disposable APK root, update from the public feed, and confirm that both `1.1.0-r1` packages resolve as upgrade candidates.

The public feed URL remains:

`https://raw.githubusercontent.com/Delitants/openwrt-packages/main/feed/x86_64/packages.adb`

The public signing key remains:

`https://raw.githubusercontent.com/Delitants/openwrt-packages/main/keys/netwatch-local.pem`

## Acceptance criteria

- A user can create an interface monitor by selecting a logical network, Linux device, Wi-Fi radio, or individual AP/SSID from LuCI.
- Configured disabled and absent objects are selectable.
- Custom-named APs show their SSID and remain unambiguous when SSIDs are duplicated.
- Disabling or losing a selected interface produces a specific failed state after the configured consecutive-failure threshold.
- The existing initial delay, repeat schedule, maximum-email cap, recipient override, and recovery option work for interface incidents.
- Every due failure email includes a freshly collected extensive diagnostic report or a clear incomplete-collection notice.
- Diagnostic failures do not suppress email, and diagnostics contain no known secrets and stay within their bounds.
- The status page exposes friendly identity, stable selector, live device, state, reason, timestamps, compact evidence, and incident counters.
- Existing ping and TCP monitors remain behaviorally compatible and all regression tests pass.
- Signed `1.1.0-r1` packages are installable and resolvable through the unchanged public `packages.adb` URL.
