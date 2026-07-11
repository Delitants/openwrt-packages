# OpenWrt Netwatch Design

## Summary

Build a lightweight host and service monitor for OpenWrt 25.12.5 on x86/64. The deliverable consists of an architecture-independent `netwatch` package and a `luci-app-netwatch` package. Users configure ping or TCP-connect checks in LuCI, select targets from active DHCP leases or enter them manually, and receive rate-limited SMTP alerts for failures and recoveries.

The package targets the OpenWrt 25.12 APK workflow and modern JavaScript LuCI APIs. It uses an OpenWrt-native ucode daemon supervised by procd, UCI for configuration, rpcd for restricted UI operations, and TLS-enabled `msmtp` for email delivery.

## Goals

- Monitor IPv4 addresses, IPv6 addresses, or hostnames.
- Populate target choices from active DHCP leases while keeping the target field editable.
- Run ICMP echo and TCP-connect checks.
- Treat excessive ping packet loss or average round-trip delay as failures when the corresponding threshold is enabled.
- Confirm a failure only after a configurable number of consecutive failed checks.
- Send immediate or delayed email notifications, repeat them on a defined schedule, and enforce a per-incident maximum.
- Send one recovery email after an alerted incident recovers, unless disabled for that monitor.
- Expose current status and useful error information in LuCI.
- Avoid unnecessary flash writes and remain lightweight enough for normal OpenWrt installations.
- Produce reproducible `.apk` packages with the official OpenWrt 25.12.5 x86/64 SDK.

## Non-goals

- UDP service monitoring.
- HTTP response, content, TLS-certificate, DNS, or protocol-specific probes.
- Neighbor discovery through ARP or NDP; only DHCP leases populate the picker.
- SMS, webhook, chat, or command-execution actions.
- Multiple SMTP server profiles.
- Long-term metrics, graphs, or persistent incident history.
- Persistence of active incidents across router reboots.

## Package layout

The repository is an OpenWrt-compatible custom feed containing two source packages.

### `netwatch`

The runtime package installs:

- `/usr/sbin/netwatchd`, the ucode daemon.
- Focused ucode modules for configuration, probe parsing, state transitions, scheduling, status serialization, and email composition.
- `/etc/init.d/netwatch`, a procd init script with respawn and configuration reload support.
- `/etc/config/netwatch`, the default UCI configuration.
- A restricted `netwatch` ubus object providing status, check-now, and test-email methods.
- rpcd ACL definitions limiting LuCI access to required UCI, netwatch, and DHCP-lease methods.

Runtime dependencies include ucode, `ucode-mod-fs`, `ucode-mod-uloop`, `ucode-mod-ubus`, `ucode-mod-uci`, `ucode-mod-socket`, BusyBox ping support, `msmtp` with TLS, and CA certificates. TCP checks use the ucode socket module directly and do not invoke an external port-check utility.

The package contains scripts and resources only and is marked architecture-independent.

### `luci-app-netwatch`

The LuCI package installs JavaScript views, menu declarations, ACLs, and translations metadata. It depends on `netwatch`, LuCI base components, and UCI integration.

## Configuration model

All configuration lives in `/etc/config/netwatch`. The file is installed with root-only write access because it can contain an SMTP password. The status API never returns that password.

### Global section

The global section contains:

- Service enabled state.
- Optional startup grace period before failure incidents can be opened.
- Default email recipients.
- Mail retry backoff used after an SMTP delivery failure.

### SMTP section

The single SMTP profile contains:

- Server hostname or address.
- Port.
- Security mode: none, STARTTLS, or implicit TLS.
- Optional username and password authentication.
- Sender address and optional display name.
- Optional EHLO domain.
- Certificate verification enabled by default. Disabling verification is not exposed in the initial UI.

The daemon generates a root-readable temporary `msmtp` configuration at `/var/run/netwatch/msmtprc` and invokes `msmtp` without placing credentials on the command line.

### Monitor sections

Each monitor has a stable UCI section ID and the following common options:

- `enabled`: whether checks run.
- `name`: human-readable label.
- `target`: IPv4 address, IPv6 address, or hostname.
- `type`: `ping` or `tcp`.
- `interval`: seconds between completed checks; default 60.
- `timeout`: maximum probe duration in seconds.
- `failures`: consecutive failed checks required to open an incident; default 3.
- `initial_delay`: seconds between incident opening and the first failure email; zero means immediate.
- `repeat_interval`: zero for one failure email, otherwise 600, 1800, or 3600 seconds.
- `max_alerts`: maximum successfully sent failure emails in one incident; minimum 1.
- `recovery_email`: whether to send a recovery message.
- `recipients`: optional per-monitor recipient override.

Ping monitors additionally contain:

- Packet count per check.
- Packet-loss threshold enabled state and maximum permitted loss percentage.
- Latency threshold enabled state and maximum permitted average RTT in milliseconds.

TCP monitors additionally contain:

- TCP port from 1 through 65535.

## Probe behavior

### Ping

The daemon runs an IPv4- or IPv6-capable BusyBox ping command in an isolated uloop task with a fixed packet count and hard timeout. The target must first pass a conservative IP-address or hostname grammar that excludes whitespace, shell syntax, options, and control characters. The daemon parses transmitted packets, received packets, packet-loss percentage, and min/average/max RTT from captured output.

A ping check fails when any of the following is true:

- The probe cannot start or times out.
- No valid summary can be parsed.
- The command reports no reachable response.
- Packet loss exceeds the enabled loss threshold.
- Average RTT exceeds the enabled latency threshold.

The result records a specific reason and the parsed metrics. Partial loss below the configured threshold remains healthy.

### TCP connect

The daemon attempts a TCP connection to the target and port with a hard timeout. A completed connection is healthy. DNS failure, refusal, unreachable routing, and timeout are failures with distinct reasons where the underlying utility provides enough information.

Only one probe may be active for a monitor at a time. A slow probe cannot overlap the next scheduled run.

## Incident state machine

Each enabled monitor moves among these states:

- `unknown`: no completed check since daemon start.
- `healthy`: the latest check succeeded and no incident is active.
- `pending`: checks are failing but have not yet reached the consecutive-failure threshold.
- `failed`: an incident is active.

State transitions are as follows:

1. A successful check moves `unknown`, `healthy`, or `pending` to `healthy` and clears the consecutive-failure count.
2. A failed check increments the consecutive-failure count. Before the configured threshold, the state is `pending`.
3. Reaching the threshold opens an incident, records its start time and reason, resets the successful failure-email count to zero, and moves to `failed`.
4. Further failed checks keep the incident open and update current metrics and reason.
5. A successful check while `failed` closes the incident and moves to `healthy`.

Runtime state is held under `/tmp/netwatch` and written atomically. It is not persisted to flash. A daemon reload retains state for unchanged stable monitor IDs; removed monitors lose their state. A full router reboot starts all monitors at `unknown`, after which the startup grace period and normal failure threshold apply.

## Alert scheduling

When an incident opens, the first failure email becomes due at incident start plus `initial_delay`.

- If `repeat_interval` is zero, no further failure email is due after the first successful send.
- Otherwise, another failure email becomes due after each successful failure email at the chosen 10-, 30-, or 60-minute interval.
- No failure email is sent after `max_alerts` successful failure emails in the incident.
- SMTP failures do not increment the successful-email count. The next attempt is delayed by the global mail retry backoff so a broken mail server is not hammered.
- If the monitor recovers before any failure email is successfully sent, no recovery email is sent.
- If at least one failure email was sent and recovery email is enabled, exactly one recovery message is attempted when the monitor recovers. It does not count against `max_alerts`.
- A later failure after recovery is a new incident with a fresh email allowance.

Email subjects identify the router, monitor, target, and transition. Bodies include the check type, failure reason, relevant ping metrics or TCP port, incident start, current duration, and alert sequence number. Recovery messages include total incident duration.

## LuCI interface

Netwatch appears under the Services menu with three pages.

### Status

The status page polls the restricted rpcd status method and shows:

- Monitor name and target.
- Probe type and TCP port when applicable.
- Current state with a clear visual label.
- Last check time and result.
- Packet loss and average RTT for ping monitors.
- Consecutive failure count.
- Incident start and duration when failed.
- Successfully sent failure-email count and configured cap.
- Current configuration or SMTP error when relevant.

Each row has a `Check now` action. This schedules an immediate check through the daemon rather than executing arbitrary user commands in rpcd.

### Monitors

The monitor form provides add, edit, enable, disable, and delete operations. A DHCP-lease selector is loaded from the router through a restricted rpcd call. Selecting a lease copies its IP into the editable target field. Users may instead enter an IPv4 address, IPv6 address, or hostname manually.

Fields appear conditionally for ping and TCP monitors. Numeric ranges and required values are validated in the browser and again by the runtime.

### Email

The email page exposes the SMTP profile, sender, global recipients, retry backoff, and TLS mode. The password uses a masked password input. Saving an empty displayed password does not unintentionally erase an existing secret; an explicit clear or replacement operation is required.

`Send test email` asks rpcd to validate the saved SMTP settings and send a fixed test message to an entered address or the global recipients. The UI shows the sanitized delivery result.

## Configuration reload and service management

The procd init script:

- Starts the daemon in the foreground.
- Enables respawn with bounded failure behavior.
- Declares `/etc/config/netwatch` as a reload trigger.
- Creates the runtime directory with restrictive permissions.
- Logs startup and fatal configuration errors through syslog.

On reload, the daemon parses and validates a complete new configuration before replacing the active configuration. Invalid monitor sections are disabled and surfaced in status without preventing valid monitors from running. Invalid global SMTP configuration prevents email delivery but does not stop monitoring.

## Security

- LuCI and rpcd receive only the minimum UCI and custom method permissions required by the application.
- All untrusted configuration is type- and range-validated in both UI and daemon.
- TCP targets are passed directly to the ucode socket API. The only probe command is a fixed BusyBox ping invocation whose target must pass a conservative grammar before shell-safe quoting. Ports, recipients, SMTP fields, and monitor names are never interpolated into shell commands.
- SMTP credentials are stored in a root-readable configuration file and a restricted temporary file, never in process arguments, status output, or syslog.
- Email header values reject CR and LF to prevent header injection.
- Recipient parsing accepts a conservative comma-separated address format and rejects control characters.
- Status JSON is written by atomic replacement and excludes secrets.
- rpcd methods expose fixed operations only; there is no generic command runner.

## Error handling and observability

Syslog messages use `netwatch` as the identity. Logs include monitor ID and name, state transitions, probe result, sanitized error reason, alert attempt, and mail outcome. Passwords and full SMTP command lines are never logged.

The status API reports daemon uptime, last configuration reload, global mail health, and per-monitor state. Missing probe dependencies, invalid sections, parse errors, and SMTP failures are visible in LuCI without crashing the daemon.

## Testing strategy

### Unit tests

Pure or isolated ucode modules are tested for:

- BusyBox IPv4 and IPv6 ping summaries.
- Successful ping, total loss, partial loss, high latency, timeout, and malformed output.
- TCP success, refusal, timeout, and resolution failure result normalization.
- Configuration defaults, ranges, and invalid values.
- State transitions and consecutive-failure handling.
- Immediate and delayed first notifications.
- One-time and repeating notification schedules.
- Per-incident maximum enforcement and reset after recovery.
- Recovery behavior with and without a prior successful failure email.
- SMTP failure retry backoff.
- Email header and body generation.

Fixtures and dependency injection isolate probe execution, clock access, and mail delivery from state and scheduling tests.

### Static and package tests

- Parse all JSON declarations.
- Check JavaScript syntax and LuCI view structure.
- Validate shell/init syntax.
- Verify installed paths, permissions, conffiles, ACL declarations, dependencies, and architecture-independent package metadata.
- Scan for secret exposure and unsafe shell construction.

### Build verification

Use the official OpenWrt 25.12.5 x86/64 SDK to build both packages. Run package checks where supported, inspect generated metadata and file lists, and retain the resulting `.apk` files as user-facing deliverables.

Installation smoke testing verifies that the packages install together into an OpenWrt-compatible environment, the init service is enabled, the LuCI menu and ACL declarations are present, and removal preserves or handles configuration according to OpenWrt conffile conventions.

## Deliverables

- Complete custom-feed source tree.
- `netwatch` and `luci-app-netwatch` source packages.
- Automated unit and static tests.
- Official-SDK-built OpenWrt 25.12.5 x86/64 `.apk` packages.
- README with build, installation, upgrade, configuration, troubleshooting, and uninstall instructions.
- SHA-256 checksums for binary deliverables.

## References

- [OpenWrt package policy](https://openwrt.org/docs/guide-developer/package-policies)
- [OpenWrt package creation guide](https://openwrt.org/docs/guide-developer/packages)
- [OpenWrt 25.12 LuCI applications](https://github.com/openwrt/luci/tree/openwrt-25.12/applications)
- [OpenWrt 25.12 msmtp package](https://raw.githubusercontent.com/openwrt/packages/openwrt-25.12/mail/msmtp/Makefile)
