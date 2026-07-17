# Scheduled Backup for OpenWrt

`luci-app-scheduled-backup` creates standard OpenWrt configuration archives on a friendly daily or weekly schedule. It supports local and SFTP destinations independently or together, password or SSH-key authentication, and per-destination retention.

## Requirements

- OpenWrt 25.12.5 on x86/64.
- The repository [trusted feed setup](../../../README.md#trusted-feed-setup).
- Working official OpenWrt feeds for runtime dependencies.

## Install

After configuring the repository key and feed:

```sh
apk update
apk add luci-app-scheduled-backup
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

Refresh LuCI and open **System > Scheduled Backup**.

## Configure and test

Choose a daily or weekly schedule and enable local storage, SFTP, or both. The local and SFTP destinations have independent paths and retention limits; `0` keeps all completed copies. Use **Save & Apply** to regenerate the managed cron entry.

SFTP supports a password or uploaded private key. Use **Test SFTP** to authenticate, validate the remote path, and explicitly trust the SSH host fingerprint. Changed host keys fail closed.

Use **Run Now** for an immediate backup. A failed destination does not invalidate a successful copy at the other destination, and retention runs only after successful publication.

## Restore

Archives are direct `sysupgrade -k -b` output and remain compatible with OpenWrt native restore. Restore a `.tar.gz` archive through **System > Backup / Flash Firmware**, after inspecting it and keeping an off-device copy.

Treat every backup as sensitive: OpenWrt configuration archives can contain router credentials, including this package's root-only SFTP authentication material.

## Upgrade

Version `1.0.0-r3` corrects the LuCI form alignment and responsive Status
layout. Upgrade from the existing signed feed with:

```sh
apk update
apk upgrade luci-app-scheduled-backup
```

The r3 page uses standard LuCI form and table classes, aligns **Run Now** and
**Test SFTP** with the other controls, and keeps credential controls inside
the SFTP section. Refresh LuCI after the upgrade. Log out and back in only if
the existing browser session still has stale ACL state.

The view remains installed at
`/www/luci-static/resources/view/scheduled-backup.js`.

Keep-settings upgrades preserve UCI configuration, SFTP credential files, the private key, and accepted host identity. Full package retention across firmware upgrades requires Attended Sysupgrade while this feed remains configured and reachable.

## Remove

```sh
apk del luci-app-scheduled-backup
rm -rf /etc/scheduled-backup
rm -f /etc/config/scheduled-backup
```

Existing backup archives are intentionally not removed automatically.

## Build and test

The repository's shared build scripts compile this nested source with the pinned official OpenWrt 25.12.5 x86_64 SDK. Package-focused host tests are available here:

```sh
./tests/run.sh
```

## Integration status

The APK and signed feed are SDK-verified. No live OpenWrt VM/router integration was performed. Remaining runtime checks are installation, LuCI rendering, cron reload, native backup/restore, local retention, password/key SFTP, remote-path validation, host-key change rejection, and Attended Sysupgrade.
