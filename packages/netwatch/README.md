# OpenWrt Netwatch

Netwatch monitors hosts with ICMP ping or TCP connection tests and sends
rate-limited SMTP failure and recovery notifications. It includes a native
OpenWrt service and a LuCI interface.

This project is published as part of the public `Delitants/openwrt-packages`
multi-package repository. Related OpenWrt package sources are grouped below
`packages/<project>/`, while all x86_64 installable packages share one signed
binary feed.

## Requirements

- A router running OpenWrt 25.12.5 for the x86/64 target.
- Working official OpenWrt package feeds so `apk` can resolve dependencies.
- For source builds and verification: Docker, Git, `curl`, `jq`, `gzip`,
  `tar` with Zstandard support, and `shasum` on the build host.

Both APK manifests declare `noarch`, but this repository pins and verifies
them with the official OpenWrt 25.12.5 x86/64 SDK. The stable artifact names
use the conventional `_all` suffix. The runtime package depends on ucode and
its fs, log, socket, ubus, UCI, and uloop modules, plus `msmtp` and the CA
certificate bundle.

## Build

Fetch and verify the pinned SDK, build the repository packages inside the SDK
container, and publish the stable output filenames:

```sh
./scripts/fetch-sdk.sh
./scripts/in-sdk.sh ./scripts/build-packages.sh
./scripts/package-output.sh
```

`fetch-sdk.sh` pins the official
`openwrt-sdk-25.12.5-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst` archive to
SHA-256
`0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c`.
The build script starts from a fresh package configuration so stale SDK-wide
package selections cannot leak into the build. The packaging script publishes:

- `outputs/netwatch_1.0.0-r1_all.apk`
- `outputs/luci-app-netwatch_1.0.0-r1_all.apk`
- `outputs/openwrt-netwatch-1.0.0-source.tar.gz`
- `outputs/SHA256SUMS`

## Build verification

The release artifacts were built with the pinned OpenWrt 25.12.5 x86/64 SDK
and inspected with its apk-tools 3.0.5. The exact replayable verification is:

```sh
./tests/run-unit.sh \
  tests/unit/config_test.uc \
  tests/unit/ping_test.uc \
  tests/unit/probe_test.uc \
  tests/unit/state_test.uc \
  tests/unit/alerts_test.uc \
  tests/unit/message_test.uc
./tests/static.sh
./scripts/verify-artifacts.sh
git --git-dir=work/git-metadata --work-tree=. diff --check
git --git-dir=work/git-metadata --work-tree=. status --short
```

For direct inspection of the two raw manifests, run:

```sh
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk adbdump --format json \
  /src/outputs/netwatch_1.0.0-r1_all.apk | jq .info
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk adbdump --format json \
  /src/outputs/luci-app-netwatch_1.0.0-r1_all.apk | jq .info
shasum -a 256 -c outputs/SHA256SUMS
```

The recorded result is six passing unit suites, a passing static/ucode check,
and two `1.0.0-r1` `noarch` manifests. The runtime manifest contains the CA
bundle, `msmtp`, ucode, and all required ucode modules; the LuCI manifest
contains `luci-base`, `rpcd-mod-luci`, and `netwatch`. All 13 runtime files and
seven LuCI files match the expected lists. `/etc/config/netwatch` is a
protected `0600` conffile, the init script is `0755`, and no packaged file is
group- or world-writable. The credential scan is clean. The translation POT
is a source-only build input and is intentionally not installed by the LuCI
APK. Checksums, source-archive exclusions, unique paths, and Git snapshot
reproducibility also pass.

The package generation step itself does not use a signing command or key.
Release APKs are signed separately before being copied into `feed/x86_64/`.
The feed rebuild then strictly verifies every APK against the committed public
key, generates the signed `packages.adb`, and strictly verifies the index.
Installation on a live router is not performed by the build workflow.

## Install

On OpenWrt 25.12.5, install the repository public key and add the complete
`packages.adb` URL to the persistent custom-feed file:

```sh
wget -O /etc/apk/keys/netwatch-local.pem \
  https://raw.githubusercontent.com/Delitants/openwrt-packages/main/keys/netwatch-local.pem

feed_url='https://raw.githubusercontent.com/Delitants/openwrt-packages/main/feed/x86_64/packages.adb'
grep -Fqx "$feed_url" /etc/apk/repositories.d/customfeeds.list || \
  printf '%s\n' "$feed_url" >> /etc/apk/repositories.d/customfeeds.list

apk update
apk add netwatch luci-app-netwatch
/etc/init.d/netwatch enable
/etc/init.d/netwatch restart
```

The public key makes both packages and the repository index trusted, so the
installation does not use `--allow-untrusted`. The LuCI package depends on the
runtime package; listing both makes the requested installation explicit.

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

## Package feed maintenance

Keep each related source group below `packages/<project>/`. To add another
package to the same x86_64 feed, build it, copy its canonical
`name-version.apk` file into `feed/x86_64/`, and sign that APK with the same
private key. Invoke `adbsign` once per file:

```sh
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk --allow-untrusted adbsign \
  --reset-signatures --sign-key /src/work/signing/private-key.pem \
  /src/feed/x86_64/name-version.apk
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk verify \
  --keys-dir /src/keys /src/feed/x86_64/name-version.apk
```

`--allow-untrusted` applies only while replacing the SDK-local input
signature. The following strict verification must report `OK` before the APK
is added to the feed index.

Regenerate the one index over every APK in the directory:

```sh
./scripts/rebuild-feed.sh x86_64 work/signing/private-key.pem
```

The rebuild refuses unsigned packages and packages signed by a key not found
in `keys/`. It signs and strictly verifies `feed/x86_64/packages.adb`, so the
router feed URL remains unchanged as packages are added. Commit the public
key, APKs, and signed index. Keep all private keys under ignored `work/`
storage and never commit them.

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

Back up the UCI configuration, refresh the trusted feed, and request both
packages:

```sh
cp /etc/config/netwatch /root/netwatch.config.backup
apk update
apk add netwatch luci-app-netwatch
/etc/init.d/netwatch restart
```

The runtime declares `/etc/config/netwatch` as a package conffile, so local
configuration is protected during package replacement. Keep the explicit
backup and review any `.apk-new` file before merging new defaults.

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
