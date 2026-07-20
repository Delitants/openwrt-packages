# Delitants OpenWrt Packages

Signed OpenWrt 25.12.5 packages and nested source trees for x86/64.

## Packages

- [Netwatch](packages/netwatch/README.md) — ICMP/TCP/interface monitoring with email alerts and LuCI.
- [Scheduled Backup](packages/scheduled-backup/luci-app-scheduled-backup/README.md) — scheduled native configuration backups to local storage and/or SFTP.

## Trusted feed setup

Install the repository public key and add the combined package index:

```sh
wget -O /etc/apk/keys/netwatch-local.pem \
  https://raw.githubusercontent.com/Delitants/openwrt-packages/main/keys/netwatch-local.pem

feed_url='https://raw.githubusercontent.com/Delitants/openwrt-packages/main/feed/x86_64/packages.adb'
grep -Fqx "$feed_url" /etc/apk/repositories.d/customfeeds.list || \
  printf '%s\n' "$feed_url" >> /etc/apk/repositories.d/customfeeds.list

apk update
```

Follow the package-specific README above for installation, configuration, upgrade, and removal.

## Source layout

Each project is nested below `packages/<project>/`. All installable x86_64 APKs share `feed/x86_64/packages.adb`, so routers need only one stable feed URL.

## Feed maintenance

Build packages with the pinned SDK workflow:

```sh
./scripts/fetch-sdk.sh
./scripts/in-sdk.sh ./scripts/build-packages.sh
./scripts/package-output.sh
```

Before adding an APK to the feed, replace its SDK-local signature with the repository key and verify it strictly:

```sh
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk --allow-untrusted adbsign \
  --reset-signatures --sign-key /src/work/signing/private-key.pem \
  /src/feed/x86_64/name-version.apk
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk verify \
  --keys-dir /src/keys /src/feed/x86_64/name-version.apk
```

Regenerate the combined index over every APK:

```sh
./scripts/rebuild-feed.sh x86_64 work/signing/private-key.pem
```

The private key must remain under ignored `work/` storage and must never be committed.

## Verification

```sh
./tests/static.sh
./tests/repository-layout_test.sh
./tests/feed_test.sh
./scripts/verify-artifacts.sh
git diff --check
```

See the package-specific documentation for runtime verification status and limitations.
