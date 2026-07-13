# OpenWrt Netwatch

Netwatch monitors hosts with ICMP ping or TCP connection tests and sends
rate-limited SMTP failure and recovery notifications. It includes a native
OpenWrt service and a LuCI interface.

## Requirements

- A router running OpenWrt 25.12.5 for the x86/64 target.
- Working official OpenWrt package feeds so `apk` can resolve dependencies.
- For source builds: Docker, `curl`, `tar` with Zstandard support, and
  `shasum` on the build host.

Both packages are architecture-independent (`all`), but this repository pins
and verifies them with the official OpenWrt 25.12.5 x86/64 SDK. The runtime
package depends on ucode and its fs, log, socket, ubus, UCI, and uloop modules,
plus `msmtp` and the CA certificate bundle.

## Build

Fetch and verify the pinned SDK, then build both source packages inside the
SDK container:

```sh
./scripts/fetch-sdk.sh
./scripts/in-sdk.sh sh -ec '
  cd /sdk
  ./scripts/feeds update -a
  ./scripts/feeds install -a
  rm -rf package/netwatch-feed
  mkdir -p package/netwatch-feed
  ln -s /src/netwatch package/netwatch-feed/netwatch
  ln -s /src/luci-app-netwatch package/netwatch-feed/luci-app-netwatch
  printf "%s\n" \
    CONFIG_PACKAGE_netwatch=y \
    CONFIG_PACKAGE_luci-app-netwatch=y >> .config
  make defconfig
  make package/netwatch/clean package/luci-app-netwatch/clean
  make package/netwatch/compile package/luci-app-netwatch/compile V=s -j1
'
```

The SDK writes its native package filenames below `work/sdk/bin/packages/`.
The final packaging step is expected to publish these stable output names
after a successful build; this list does not claim that prebuilt files are
checked into the source tree:

- `outputs/netwatch_1.0.0-r1_all.apk`
- `outputs/luci-app-netwatch_1.0.0-r1_all.apk`

## Install

Copy the two APK files to `/tmp` on the router. Install the runtime first and
the LuCI application second:

```sh
apk update
apk add --allow-untrusted /tmp/netwatch_1.0.0-r1_all.apk
apk add --allow-untrusted /tmp/luci-app-netwatch_1.0.0-r1_all.apk
/etc/init.d/netwatch enable
/etc/init.d/netwatch restart
```

`apk` installs declared dependencies from the router's configured signed
feeds. `--allow-untrusted` is needed for these locally built, unsigned APKs;
only install artifacts you built yourself or verified against the supplied
checksums. The LuCI package depends on the runtime package, but the explicit
order above makes failures easier to diagnose.

After installation, refresh LuCI and open `Services > Netwatch`.

## Configure

Use `Services > Netwatch > Monitors` to add a monitor. The target field lists
active DHCP leases but remains editable, so an IPv4 address, IPv6 address, or
hostname can be entered manually. Choose either a ping test or a TCP port
test. Ping monitors can treat packet loss above a percentage or average delay
above a millisecond threshold as a failure.

For each monitor, set the number of consecutive failures required before it
is down. The first email can be immediate or delayed by 5, 10, 15, 30, or 60
minutes. Repeats can be disabled or sent every 10, 30, or 60 minutes, with a
maximum number of successfully delivered failure emails per incident. A
monitor may override the global comma-separated recipient list and may enable
or disable its recovery email.

Configure the global recipients and SMTP account under
`Services > Netwatch > Email`. For port 587 with STARTTLS, the equivalent UCI
settings are:

```sh
uci set netwatch.main=netwatch
uci set netwatch.main.enabled='1'
uci set netwatch.main.recipients='alerts@example.net'
uci set netwatch.smtp=smtp
uci set netwatch.smtp.server='smtp.example.net'
uci set netwatch.smtp.port='587'
uci set netwatch.smtp.tls='starttls'
uci set netwatch.smtp.username='router@example.net'
uci set netwatch.smtp.password='replace-with-an-app-password'
uci set netwatch.smtp.from='router@example.net'
uci commit netwatch
/etc/init.d/netwatch restart
```

For port 465 with implicit TLS, keep the other SMTP values and change:

```sh
uci set netwatch.smtp.port='465'
uci set netwatch.smtp.tls='tls'
uci commit netwatch
/etc/init.d/netwatch restart
```

Entering the password in LuCI avoids leaving it in shell history. The Email
page preserves an existing password when its placeholder is unchanged and
offers an explicit control to clear it. The test-email action saves and
applies the form before requesting a fixed test message.

Here is a ping monitor with packet-loss and average-delay limits:

```sh
uci set netwatch.gateway=monitor
uci set netwatch.gateway.enabled='1'
uci set netwatch.gateway.name='Internet gateway'
uci set netwatch.gateway.target='192.0.2.1'
uci set netwatch.gateway.type='ping'
uci set netwatch.gateway.interval='60'
uci set netwatch.gateway.timeout='5'
uci set netwatch.gateway.failures='3'
uci set netwatch.gateway.packet_count='3'
uci set netwatch.gateway.loss_enabled='1'
uci set netwatch.gateway.max_loss='20'
uci set netwatch.gateway.rtt_enabled='1'
uci set netwatch.gateway.max_rtt='500'
uci set netwatch.gateway.initial_delay='300'
uci set netwatch.gateway.repeat_interval='1800'
uci set netwatch.gateway.max_alerts='5'
uci set netwatch.gateway.recovery_email='1'
uci commit netwatch
/etc/init.d/netwatch restart
```

For a TCP-only monitor, use a stable named section, `type='tcp'`, and a port:

```sh
uci set netwatch.mail_server=monitor
uci set netwatch.mail_server.enabled='1'
uci set netwatch.mail_server.name='Mail server'
uci set netwatch.mail_server.target='192.0.2.25'
uci set netwatch.mail_server.type='tcp'
uci set netwatch.mail_server.port='25'
uci set netwatch.mail_server.interval='60'
uci set netwatch.mail_server.timeout='5'
uci set netwatch.mail_server.failures='3'
uci set netwatch.mail_server.initial_delay='0'
uci set netwatch.mail_server.repeat_interval='0'
uci set netwatch.mail_server.max_alerts='1'
uci set netwatch.mail_server.recovery_email='1'
uci commit netwatch
/etc/init.d/netwatch restart
```

Runtime state is kept in `/var/run/netwatch`, not written to flash. A service
reload retains state for unchanged named monitor sections. Active incidents and their email counters reset after a router reboot.

## Troubleshooting

Restart the daemon after command-line configuration changes, inspect its
public status, and then check its sanitized system log messages:

```sh
/etc/init.d/netwatch restart
ubus call netwatch status
logread -e netwatch
```

If `ubus` says the object is missing, check that the service is enabled and
running with `/etc/init.d/netwatch status`. If a monitor is invalid, compare
its fields with the ranges shown in LuCI. For email failures, verify the SMTP
host, port, TLS mode, sender, recipients, router clock, DNS, and CA bundle.
Port 587 normally uses `starttls`; port 465 uses `tls` from connection start.
The status API and log never expose the SMTP password.

## Upgrade

Back up the UCI configuration, upload the newer APKs, and install the runtime
before the LuCI package:

```sh
cp /etc/config/netwatch /root/netwatch.config.backup
apk add --allow-untrusted /tmp/netwatch_1.0.0-r1_all.apk
apk add --allow-untrusted /tmp/luci-app-netwatch_1.0.0-r1_all.apk
/etc/init.d/netwatch restart
```

Use the actual filenames for the newer release when they differ. The runtime
declares `/etc/config/netwatch` as a package conffile, so local configuration
is protected during package replacement. Keep the explicit backup and review
any `.apk-new` file before merging new defaults.

## Uninstall

Save the configuration first if it may be reused, then stop the service and
remove the UI before the runtime:

```sh
cp /etc/config/netwatch /root/netwatch.config.backup
/etc/init.d/netwatch stop
apk del luci-app-netwatch netwatch
```

After removal, check whether `/etc/config/netwatch` remains as a protected
modified conffile. Delete it manually only when the saved monitoring and SMTP
configuration is no longer needed.

Netwatch is licensed under GPL-2.0-only; see `LICENSE`.
