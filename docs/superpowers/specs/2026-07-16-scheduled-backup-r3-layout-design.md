# Scheduled Backup 1.0.0-r3 LuCI Layout Correction Design

## Problem

The `luci-app-scheduled-backup` `1.0.0-r2` page is functional, but its custom
Status markup does not use LuCI's table row and cell classes. The Bootstrap
theme styles `.table .tr`, `.table .th`, and `.table .td`; the current native
`tr`, `th`, and `td` elements therefore render without the expected padding,
borders, or responsive behavior. Labels and values appear joined together.

The view also renders Credentials as a separate section even when all of its
options are hidden because SFTP is disabled. This leaves an empty heading.
Operations uses an untitled `DummyValue`, so its buttons start at the page
edge instead of aligning with the other form controls.

## Goals

- Publish `luci-app-scheduled-backup` `1.0.0-r3` in the existing signed x86_64
  feed as a normal package-manager upgrade.
- Make Status a properly spaced, two-column, responsive LuCI table.
- Remove the empty Credentials section while keeping credential fields
  conditional on SFTP and authentication mode.
- Align the Run Now and Test SFTP controls with other form values.
- Remain compatible with LuCI themes by using standard LuCI classes and form
  rendering rather than package-specific CSS.
- Preserve all scheduling, backup generation, local retention, SFTP,
  credential-storage, and native restore behavior.

## Non-goals

- No tabbed or card-based redesign.
- No custom stylesheet or theme-specific selector overrides.
- No backend, rpcd, ACL, cron, UCI schema, or dependency changes.
- No change to authentication, host trust, retention, status polling, or
  confirmation behavior.
- No feed URL or signing-key change, and no changes to Netwatch packages.

## LuCI Layout

The existing General, Schedule, Local Storage, SFTP, Operations, and Status
order remains. Standard `form.Map`, `form.NamedSection`, and option widgets
continue to render configuration inputs.

Credential widgets move from their separate NamedSection into the existing
SFTP NamedSection immediately after the SFTP connection and retention
options. Their current `depends()` rules remain unchanged, so password
controls appear only for password authentication and private-key controls
appear only for key authentication. When SFTP is disabled, no empty
Credentials heading remains.

The Operations `DummyValue` receives the visible title `Backup actions`.
LuCI will then render the action buttons inside the normal value field,
aligned with the input column. Button labels, handlers, confirmations, and
notifications remain unchanged.

Status remains a full-width custom table inside its section. The table uses
`table cbi-section-table`; each row uses `tr cbi-section-table-row`; label
cells use `th cbi-section-table-cell left`; and value cells use
`td cbi-section-table-cell left`. This matches the standard LuCI table
contract and gives desktop and mobile themes the hooks needed for padding,
borders, wrapping, and responsive layout.

## Compatibility and Data Flow

The layout correction changes only DOM structure and package release
metadata. It does not change RPC calls, UCI reads or writes, dependency
conditions, validators, secret handling, or status data. `renderStatus()`
continues to replace the current status node, so polling behavior is
unchanged.

No migration is required. Existing `/etc/config/scheduled-backup` values,
stored SFTP credentials, private keys, and trusted host identity remain
preserved by the existing conffile and keep-file declarations.

## Tests

Test-driven implementation will first add failing LuCI static assertions that
require:

- the standard Status table, row, header-cell, and value-cell classes;
- a titled `Backup actions` DummyValue;
- credential options to be attached to the SFTP section rather than a
  standalone Credentials section;
- `PKG_RELEASE:=3`.

The minimal view and recipe changes will then make those assertions pass.
All existing backend, rpcd, cron, SFTP, retention, LuCI static, repository,
feed, package-output, artifact, and signature checks remain required.

## Package and Feed Publication

Keep `PKG_VERSION:=1.0.0` and bump `PKG_RELEASE` from `2` to `3`. Update release
scripts, tests, checksums, and package documentation to expect `1.0.0-r3`.
Build with the pinned official OpenWrt 25.12.5 x86_64 SDK.

Replace `feed/x86_64/luci-app-scheduled-backup-1.0.0-r2.apk` with the signed
`feed/x86_64/luci-app-scheduled-backup-1.0.0-r3.apk`; do not retain both
releases. Rebuild `packages.adb` and strictly verify every APK and the index
against `keys/netwatch-local.pem`. The two Netwatch `1.0.0-r1` packages remain
unchanged.

Publish the change through a pull request and merge it to `main`. Finally,
download the public raw r3 APK and `packages.adb`, verify their signatures,
and confirm that the public index contains exactly one Scheduled Backup entry
at `1.0.0-r3`.

## Upgrade Instructions

Routers using the existing feed upgrade with:

```sh
apk update
apk upgrade luci-app-scheduled-backup
```

After upgrading, the user refreshes LuCI. Logging out and back in is only a
fallback if the existing browser session retains stale ACL state.

## Release Validation

Before publication:

1. Observe the new layout regression test fail against r2.
2. Apply the minimal view and release changes and run all tests to green.
3. Build and inspect the r3 APK with the pinned SDK.
4. Confirm the Status classes and existing LuCI view path in the APK payload.
5. Sign and strictly verify the r3 APK and rebuilt feed index.
6. Confirm the signing key, build workspace, and unrelated files are not
   tracked.
7. Merge the pull request and verify the exact public GitHub feed bytes.

SDK, static, and package-content checks do not substitute for a live browser
check on the user's installed LuCI theme. The user's screenshot is the visual
acceptance baseline for the corrected spacing and alignment.
