# Scheduled Backup 1.0.0-r2 Packaging Correction Design

## Problem

`luci-app-scheduled-backup` `1.0.0-r1` uses the generic OpenWrt
`package.mk` flow and manually copies `htdocs/` into the package root. The
published APK therefore installs the LuCI view at
`/luci-static/resources/view/scheduled-backup.js` instead of the web root at
`/www/luci-static/resources/view/scheduled-backup.js`.

The generic package flow also omits LuCI's standard post-install hook, which
clears `/tmp/luci-indexcache.*` and `/tmp/luci-modulecache/` and reloads
`rpcd`. A newly installed package can consequently be absent from the LuCI
menu, and its view cannot load from the expected URL even after a manual cache
refresh.

## Goals

- Publish `luci-app-scheduled-backup` `1.0.0-r2` in the existing signed
  x86_64 feed.
- Install the LuCI JavaScript view below `/www/luci-static/resources/view/`.
- Use LuCI's standard post-install cache invalidation and `rpcd` reload.
- Preserve `/etc/config/scheduled-backup` and `/etc/scheduled-backup/` during
  package upgrades.
- Allow an installed `1.0.0-r1` package to upgrade through the existing APK
  feed with normal package-manager commands.
- Keep backup generation, scheduling, local retention, SFTP, and restore
  behavior unchanged.

## Non-goals

- No changes to the LuCI form or backend behavior.
- No automatic movement or deletion of the misplaced r1
  `/luci-static/resources/view/scheduled-backup.js` file. APK replacement
  removes files owned by r1 while installing the r2 file list.
- No signing-key rotation or feed URL change.
- No change to Netwatch packages.

## Package Recipe

Replace the custom `package.mk` recipe with the repository's established
LuCI package pattern:

- retain `PKG_VERSION:=1.0.0` and set `PKG_RELEASE:=2`;
- express the title through `LUCI_TITLE`;
- express the existing runtime dependencies through `LUCI_DEPENDS`;
- set `LUCI_PKGARCH:=all`;
- retain the MIT license and maintainer;
- retain the package conffile declaration for both scheduled-backup paths;
- include `$(TOPDIR)/feeds/luci/luci.mk`.

`luci.mk` owns installation of `htdocs/` under `/www`, installation of
`root/` under `/`, JavaScript minification where configured, LuCI cache
invalidation, and `rpcd` reload. The package must not duplicate these actions.

## Tests

Source-level tests will fail on r1 and pass on r2 by requiring:

- `PKG_RELEASE:=2`;
- `LUCI_DEPENDS` and `LUCI_PKGARCH:=all`;
- inclusion of `$(TOPDIR)/feeds/luci/luci.mk`;
- absence of the old manual `$(CP) ./htdocs/* $(1)/` installation.

Built-artifact verification will require:

- package name `luci-app-scheduled-backup`;
- version `1.0.0-r2`;
- the view at `/www/luci-static/resources/view/scheduled-backup.js`;
- no view at `/luci-static/resources/view/scheduled-backup.js`;
- the menu and rpcd ACL JSON files;
- the standard LuCI post-install cache invalidation and `rpcd` reload;
- the existing conffile declarations and runtime dependencies.

All existing backend, rpcd, cron, SFTP, retention, LuCI static, repository,
feed, and package-output tests remain required.

## Feed Publication

Build the corrected package with the pinned OpenWrt 25.12.5 x86_64 SDK.
Replace `feed/x86_64/luci-app-scheduled-backup-1.0.0-r1.apk` with
`feed/x86_64/luci-app-scheduled-backup-1.0.0-r2.apk`; do not retain both
releases in the feed. Re-sign the r2 APK with the existing repository private
key, rebuild `feed/x86_64/packages.adb` over all current APKs, and strictly
verify every APK and the index against `keys/netwatch-local.pem`.

The rebuilt index must contain exactly one Scheduled Backup entry at
`1.0.0-r2` and retain both Netwatch `1.0.0-r1` entries unchanged.

## Upgrade Instructions

The package README will document:

```sh
apk update
apk upgrade luci-app-scheduled-backup
```

After the upgrade, the user logs out of LuCI and back in if the existing
browser session still holds the old ACL set. The package's standard LuCI
post-install hook handles server-side cache invalidation and `rpcd` reload;
manual file copying and service restarts are not part of the normal r2
upgrade.

## Release Validation

Before publication:

1. Run the complete repository and nested Scheduled Backup test suites.
2. Build `1.0.0-r2` with the pinned SDK.
3. Inspect the APK manifest and file paths.
4. Sign and strictly verify the APK and rebuilt feed index.
5. Confirm no private signing key or unrelated file is tracked.
6. Publish through a pull request and merge to `main`, making the existing
   raw `packages.adb` URL serve the r2 index.

Live installation on an OpenWrt router is recommended as a follow-up runtime
check but is not represented by SDK and static test results.
