# Scheduled Backup 1.0.0-r3 LuCI Layout Correction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a package-manager-upgradable `luci-app-scheduled-backup` `1.0.0-r3` with a theme-compatible Status table, aligned operation controls, and no empty Credentials section.

**Architecture:** Keep the existing LuCI `form.Map` and all backend/RPC behavior. Correct only the view structure by using LuCI's standard table classes, keeping credential widgets in the SFTP section, and giving the Operations widget a normal form title; then bump the package release and regenerate the signed feed.

**Tech Stack:** OpenWrt 25.12.5 x86_64 SDK, LuCI JavaScript form API, POSIX shell tests, Alpine APK tooling, Docker, Git, GitHub.

## Global Constraints

- Package version is exactly `1.0.0-r3` (`PKG_VERSION:=1.0.0`, `PKG_RELEASE:=3`).
- Build target is OpenWrt 25.12.5 x86/64; the architecture-independent package metadata remains `noarch`.
- Use standard LuCI classes and form rendering; add no package-specific CSS.
- Keep RPC calls, UCI reads and writes, validators, dependency conditions, secret handling, status polling, cron, backup generation, retention, SFTP, and native restore behavior unchanged.
- Preserve `/etc/config/scheduled-backup` and `/etc/scheduled-backup/` across package upgrades.
- The existing public key, private signing key, feed URL, and both Netwatch `1.0.0-r1` packages remain unchanged.
- The signed feed contains exactly one Scheduled Backup APK; replace r2 with r3 instead of retaining both.
- Never stage or commit `work/signing/private-key.pem`, `work/`, or `outputs/`.

---

### Task 1: Correct the LuCI layout with a failing regression test

**Files:**
- Modify: `packages/scheduled-backup/luci-app-scheduled-backup/tests/test_luci_static.sh`
- Modify: `packages/scheduled-backup/luci-app-scheduled-backup/htdocs/luci-static/resources/view/scheduled-backup.js`

**Interfaces:**
- Consumes: existing `statusRow(label, value)`, `renderStatus(node, status)`, the SFTP NamedSection in local variable `s`, and the `_operations` DummyValue.
- Produces: standard LuCI Status DOM classes, credential options owned by the SFTP section, and a titled `Backup actions` form row. No function signatures or RPC interfaces change.

- [ ] **Step 1: Add the failing layout contract assertions**

Append these assertions to `test_luci_static.sh` immediately before the
`MAKEFILE=$ROOT/Makefile` block:

```sh
for class in \
	"'class': 'table cbi-section-table'" \
	"'class': 'tr cbi-section-table-row'" \
	"'class': 'th cbi-section-table-cell left'" \
	"'class': 'td cbi-section-table-cell left'"
do
	grep -Fq "$class" "$VIEW" || {
		echo "missing LuCI layout class: $class" >&2
		exit 1
	}
done

grep -Fq "s.option(form.DummyValue, '_operations', _('Backup actions'))" \
	"$VIEW" || {
	echo 'Operations are not aligned through a titled LuCI form row' >&2
	exit 1
}

if grep -Fq "s = m.section(form.NamedSection, 'main', 'scheduled_backup', _('Credentials'));" \
	"$VIEW"; then
	echo 'Credentials still render as an independent section' >&2
	exit 1
fi

sftp_line=$(grep -n "_('SFTP'));" "$VIEW" | head -1 | cut -d: -f1)
password_line=$(grep -n "'_password'" "$VIEW" | head -1 | cut -d: -f1)
operations_line=$(grep -n "_('Operations'));" "$VIEW" | head -1 | cut -d: -f1)
[ "$sftp_line" -lt "$password_line" ] && [ "$password_line" -lt "$operations_line" ] || {
	echo 'Credential widgets are not contained by the SFTP section' >&2
	exit 1
}
```

- [ ] **Step 2: Run the focused test and observe the expected failure**

Run:

```sh
sh packages/scheduled-backup/luci-app-scheduled-backup/tests/test_luci_static.sh
```

Expected: nonzero exit with `missing LuCI layout class` because r2's Status
markup lacks the standard LuCI classes.

- [ ] **Step 3: Apply the minimal view correction**

Replace `statusRow()` with:

```javascript
function statusRow(label, value) {
	return E('tr', { 'class': 'tr cbi-section-table-row' }, [
		E('th', { 'class': 'th cbi-section-table-cell left' }, label),
		E('td', { 'class': 'td cbi-section-table-cell left' },
			value || _('Not available'))
	]);
}
```

Change the table creation in `renderStatus()` to:

```javascript
var table = E('table', { 'class': 'table cbi-section-table' }, [
```

Delete only these two lines before the `_password` option so the credential
widgets remain attached to the existing SFTP section:

```javascript
s = m.section(form.NamedSection, 'main', 'scheduled_backup', _('Credentials'));
s.addremove = false;
```

Change the Operations DummyValue creation to:

```javascript
o = s.option(form.DummyValue, '_operations', _('Backup actions'));
```

- [ ] **Step 4: Run the focused and nested package tests**

Run:

```sh
sh packages/scheduled-backup/luci-app-scheduled-backup/tests/test_luci_static.sh
sh packages/scheduled-backup/luci-app-scheduled-backup/tests/run.sh
git diff --check
```

Expected: `LuCI static contracts passed`, followed by backend, LuCI, and rpcd
test success; `git diff --check` emits no output.

- [ ] **Step 5: Review and commit the isolated layout correction**

Run:

```sh
git diff -- packages/scheduled-backup/luci-app-scheduled-backup
git add \
  packages/scheduled-backup/luci-app-scheduled-backup/tests/test_luci_static.sh \
  packages/scheduled-backup/luci-app-scheduled-backup/htdocs/luci-static/resources/view/scheduled-backup.js
git diff --cached --check
git commit -m "fix scheduled backup LuCI layout"
```

Expected: the commit changes only the view and its static contract test.

---

### Task 2: Prepare all source-controlled r3 release plumbing test-first

**Files:**
- Modify: `packages/scheduled-backup/luci-app-scheduled-backup/tests/test_luci_static.sh`
- Modify: `tests/package-output_test.sh`
- Modify: `tests/static.sh`
- Modify: `packages/scheduled-backup/luci-app-scheduled-backup/Makefile`
- Modify: `packages/scheduled-backup/luci-app-scheduled-backup/README.md`
- Modify: `scripts/package-output.sh`
- Modify: `scripts/verify-artifacts.sh`

**Interfaces:**
- Consumes: the Task 1 view and unchanged package name `luci-app-scheduled-backup`.
- Produces: source tests and release scripts that require only `1.0.0-r3`, plus documentation for the package-manager upgrade.

- [ ] **Step 1: Change release-facing tests to require r3 first**

Make these exact test changes without changing production scripts yet:

```text
packages/.../tests/test_luci_static.sh:
  PKG_RELEASE:=2 -> PKG_RELEASE:=3

tests/package-output_test.sh:
  luci-app-scheduled-backup-1.0.0-r2.apk -> luci-app-scheduled-backup-1.0.0-r3.apk
  luci-app-scheduled-backup_1.0.0-r2_all.apk -> luci-app-scheduled-backup_1.0.0-r3_all.apk
  scheduled-backup r2 -> scheduled-backup r3

tests/static.sh:
  1.0.0-r2 -> 1.0.0-r3
  outputs/luci-app-scheduled-backup_1.0.0-r2_all.apk ->
    outputs/luci-app-scheduled-backup_1.0.0-r3_all.apk
  artifact verifier omits Scheduled Backup r2 ->
    artifact verifier omits Scheduled Backup r3

```

- [ ] **Step 2: Run the release tests and observe r3-specific failures**

Run:

```sh
sh packages/scheduled-backup/luci-app-scheduled-backup/tests/test_luci_static.sh
sh tests/package-output_test.sh
sh tests/static.sh
```

Expected: failures identify `PKG_RELEASE:=3`, the missing r3 SDK fixture match,
the missing r3 feed APK, or active scripts/documentation that still name r2.
The failures must be version-specific rather than shell syntax errors.

- [ ] **Step 3: Bump the package recipe and release scripts**

Set the package release in `Makefile`:

```make
PKG_VERSION:=1.0.0
PKG_RELEASE:=3
```

In `scripts/package-output.sh`, use exactly:

```sh
scheduled_backup_apk=$(find_one_apk 'Scheduled Backup LuCI' \
	'luci-app-scheduled-backup-1.0.0-r3.apk')
scheduled_backup_output=$output_dir/luci-app-scheduled-backup_1.0.0-r3_all.apk
```

Use `outputs/luci-app-scheduled-backup_1.0.0-r3_all.apk` in its checksum list.

In `scripts/verify-artifacts.sh`, set:

```sh
scheduled=outputs/luci-app-scheduled-backup_1.0.0-r3_all.apk
```

and require this metadata:

```jq
.info.name == "luci-app-scheduled-backup" and
.info.version == "1.0.0-r3" and
.info.arch == "noarch"
```

After extracting the scheduled package, add this installed-view check:

```sh
scheduled_view="$tmp/extracted/scheduled/www/luci-static/resources/view/scheduled-backup.js"
for class in \
	'table cbi-section-table' \
	'tr cbi-section-table-row' \
	'th cbi-section-table-cell left' \
	'td cbi-section-table-cell left'
do
	grep -Fq "$class" "$scheduled_view" || {
		echo "error: built Scheduled Backup view lacks layout class: $class" >&2
		exit 1
	}
done
```

- [ ] **Step 4: Update the package README for the r3 upgrade**

Replace the first paragraph of the Upgrade section with:

```markdown
Version `1.0.0-r3` corrects the LuCI form alignment and responsive Status
layout. Upgrade from the existing signed feed with:
```

After the command block, document:

```markdown
The r3 page uses standard LuCI form and table classes, aligns **Run Now** and
**Test SFTP** with the other controls, and keeps credential controls inside
the SFTP section. Refresh LuCI after the upgrade. Log out and back in only if
the existing browser session still has stale ACL state.
```

Keep the existing `/www/luci-static/resources/view/scheduled-backup.js`,
configuration preservation, Attended Sysupgrade, removal, and integration
status documentation.

- [ ] **Step 5: Run all source-level tests to green**

Run:

```sh
sh packages/scheduled-backup/luci-app-scheduled-backup/tests/run.sh
sh tests/package-output_test.sh
sh tests/repository-layout_test.sh
sh tests/static.sh
git diff --check
```

Expected: every command exits 0. The feed contract remains unchanged until
Task 4, where it gets its own red-green cycle against the generated binaries.

- [ ] **Step 6: Review and commit the r3 source release preparation**

Run:

```sh
git diff --stat
git diff -- \
  packages/scheduled-backup/luci-app-scheduled-backup/Makefile \
  packages/scheduled-backup/luci-app-scheduled-backup/README.md \
  scripts/package-output.sh scripts/verify-artifacts.sh \
  tests/package-output_test.sh tests/static.sh
git add \
  packages/scheduled-backup/luci-app-scheduled-backup/Makefile \
  packages/scheduled-backup/luci-app-scheduled-backup/README.md \
  packages/scheduled-backup/luci-app-scheduled-backup/tests/test_luci_static.sh \
  scripts/package-output.sh scripts/verify-artifacts.sh \
  tests/package-output_test.sh tests/static.sh
git diff --cached --check
git commit -m "prepare scheduled backup r3 release"
```

Expected: the committed source tree is clean except for ignored build outputs;
the only intentionally deferred failure is the still-r2 tracked feed.

---

### Task 3: Build and verify the r3 APK with the pinned SDK

**Files:**
- Generate (ignored): `outputs/luci-app-scheduled-backup_1.0.0-r3_all.apk`
- Generate (ignored): `outputs/SHA256SUMS`
- Generate (ignored): `outputs/openwrt-netwatch-1.0.0-source.tar.gz`
- Generate (ignored): `work/sdk/bin/packages/x86_64/base/luci-app-scheduled-backup-1.0.0-r3.apk`

**Interfaces:**
- Consumes: the clean committed r3 source, cached official OpenWrt 25.12.5 SDK, and unchanged Netwatch r1 build outputs.
- Produces: one noarch r3 APK whose installed view contains the corrected DOM classes and whose complete artifact set passes `verify-artifacts.sh`.

- [ ] **Step 1: Confirm source and SDK provenance**

Run:

```sh
git status --short
git log -4 --oneline
shasum -a 256 /Users/neolo/Documents/Codex/2026-07-10/ca/work/downloads/openwrt-sdk-25.12.5-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
```

Expected: no tracked changes; layout and r3 preparation commits are at HEAD;
the SDK archive checksum is
`0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c`.

- [ ] **Step 2: Clean and build only Scheduled Backup in the case-sensitive SDK volume**

Run from the repository root:

```sh
repo=$(pwd -P)
volume=openwrt-sdk-25.12.5-scheduled-backup-r2
image=netwatch-openwrt-sdk:25.12.5
mkdir -p outputs
docker run --rm --platform linux/amd64 \
  -v "$volume:/sdk" \
  -v "$repo:/src" \
  -w /sdk \
  "$image" sh -eu -c '
    package=package/luci-app-scheduled-backup
    [ ! -L "$package" ] || rm -f "$package"
    ln -s /src/packages/scheduled-backup/luci-app-scheduled-backup "$package"
    trap "rm -f $package" EXIT HUP INT TERM
    if grep -q "^# CONFIG_PACKAGE_luci-app-scheduled-backup is not set$" .config; then
      sed -i "s/^# CONFIG_PACKAGE_luci-app-scheduled-backup is not set$/CONFIG_PACKAGE_luci-app-scheduled-backup=y/" .config
    elif ! grep -qx "CONFIG_PACKAGE_luci-app-scheduled-backup=y" .config; then
      printf "%s\n" "CONFIG_PACKAGE_luci-app-scheduled-backup=y" >> .config
    fi
    make defconfig
    grep -qx "CONFIG_PACKAGE_luci-app-scheduled-backup=y" .config
    make package/luci-app-scheduled-backup/clean
    make package/luci-app-scheduled-backup/compile V=s -j1
    matches=$(find bin/packages/x86_64 -type f \
      -name "luci-app-scheduled-backup-1.0.0-r3.apk" -print)
    count=$(printf "%s\n" "$matches" | awk "NF { n++ } END { print n + 0 }")
    [ "$count" -eq 1 ]
    cp "$matches" /src/outputs/luci-app-scheduled-backup_1.0.0-r3_all.apk
  '
```

Expected: package compilation exits 0 and exactly one r3 APK is copied to
`outputs/`.

- [ ] **Step 3: Regenerate the complete output set from the clean Git snapshot**

Run:

```sh
cp outputs/luci-app-scheduled-backup_1.0.0-r3_all.apk \
  work/sdk/bin/packages/x86_64/base/luci-app-scheduled-backup-1.0.0-r3.apk
./scripts/package-output.sh
```

Expected: the two Netwatch r1 APKs, Scheduled Backup r3 APK, deterministic
source archive, and `SHA256SUMS` are generated.

- [ ] **Step 4: Verify the APK manifest, files, layout classes, and conffiles**

Run:

```sh
./scripts/verify-artifacts.sh
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk adbdump --format json \
  /src/outputs/luci-app-scheduled-backup_1.0.0-r3_all.apk | \
  jq -e '
    .info.name == "luci-app-scheduled-backup" and
    .info.version == "1.0.0-r3" and
    .info.arch == "noarch" and
    any(.paths[];
      .name == "www/luci-static/resources/view" and
      any(.files[]?; .name == "scheduled-backup.js")) and
    any(.paths[];
      .name == "lib/apk/packages" and
      any(.files[]?; .name == "luci-app-scheduled-backup.conffiles"))
  '
```

Expected: artifact verification passes; APK metadata is r3/noarch; the view
is below `/www`; the extracted view contains all four layout class strings;
and the conffile metadata remains present.

---

### Task 4: Sign, publish, merge, and verify the public r3 feed

**Files:**
- Modify: `tests/feed_test.sh`
- Delete: `feed/x86_64/luci-app-scheduled-backup-1.0.0-r2.apk`
- Create: `feed/x86_64/luci-app-scheduled-backup-1.0.0-r3.apk`
- Modify (generated): `feed/x86_64/packages.adb`

**Interfaces:**
- Consumes: verified Task 3 output and ignored `work/signing/private-key.pem`.
- Produces: the existing public feed URL with exactly one Scheduled Backup entry at r3, merged into `main` and verified from raw GitHub downloads.

- [ ] **Step 1: Change the feed contract to require only r3 and observe it fail**

In `tests/feed_test.sh`, change the required Scheduled Backup path to:

```sh
feed/x86_64/luci-app-scheduled-backup-1.0.0-r3.apk
```

Replace the obsolete-release assertion with:

```sh
for obsolete in \
	feed/x86_64/luci-app-scheduled-backup-1.0.0-r1.apk \
	feed/x86_64/luci-app-scheduled-backup-1.0.0-r2.apk
do
	[ ! -e "$root/$obsolete" ] || {
		echo "obsolete Scheduled Backup APK remains in feed: $obsolete" >&2
		exit 1
	}
done
```

Run:

```sh
sh tests/feed_test.sh
```

Expected: nonzero exit reporting the missing r3 feed input or remaining r2
APK, proving the feed regression test detects the unpublished state.

- [ ] **Step 2: Replace r2 with the unsigned r3 output and apply the repository signature**

Run:

```sh
git rm feed/x86_64/luci-app-scheduled-backup-1.0.0-r2.apk
cp outputs/luci-app-scheduled-backup_1.0.0-r3_all.apk \
  feed/x86_64/luci-app-scheduled-backup-1.0.0-r3.apk
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk \
  --allow-untrusted adbsign \
  --reset-signatures \
  --sign-key /src/work/signing/private-key.pem \
  /src/feed/x86_64/luci-app-scheduled-backup-1.0.0-r3.apk
```

Expected: r2 is staged for deletion and the r3 feed APK has exactly the
repository signature.

- [ ] **Step 3: Rebuild and strictly verify the combined feed**

Run:

```sh
./scripts/rebuild-feed.sh x86_64 work/signing/private-key.pem
./scripts/in-sdk.sh sh -eu -c '
  apk=/sdk/staging_dir/host/bin/apk
  for package in /src/feed/x86_64/*.apk; do
    "$apk" verify --keys-dir /src/keys "$package"
  done
  "$apk" verify --keys-dir /src/keys /src/feed/x86_64/packages.adb
  "$apk" adbdump --format json /src/feed/x86_64/packages.adb
'
```

Expected: all three APKs and `packages.adb` report `OK`; index JSON contains
Netwatch and LuCI Netwatch `1.0.0-r1` plus Scheduled Backup `1.0.0-r3` only.

- [ ] **Step 4: Run the complete final verification gate**

Run:

```sh
sh tests/static.sh
sh tests/repository-layout_test.sh
sh tests/feed_test.sh
sh tests/package-output_test.sh
sh packages/scheduled-backup/luci-app-scheduled-backup/tests/run.sh
./scripts/verify-artifacts.sh
git diff --check
test -z "$(git ls-files 'work/*' '*private-key*' '*.key' '*.key.pem')"
```

Expected: every command exits 0; the layout assertions pass; the feed contains
r3 and no r1/r2 Scheduled Backup APK; no private key path is tracked.

- [ ] **Step 5: Review and commit the feed contract and signed feed delta**

Run:

```sh
git add \
  tests/feed_test.sh \
  feed/x86_64/luci-app-scheduled-backup-1.0.0-r3.apk \
  feed/x86_64/packages.adb
git status --short
git diff --cached --stat
git diff --cached --check
git commit -m "publish scheduled backup 1.0.0-r3"
```

Expected: the commit updates the feed contract, deletes the r2 APK, adds the
r3 APK, and regenerates the signed index.

- [ ] **Step 6: Push and open a ready pull request**

Use this branch and PR metadata through the GitHub app, with `gh` only as a
fallback:

```sh
git push -u origin agent/fix-scheduled-backup-r3-layout
gh pr create \
  --repo Delitants/openwrt-packages \
  --base main \
  --head agent/fix-scheduled-backup-r3-layout \
  --title "Release Scheduled Backup 1.0.0-r3" \
  --body-file /private/tmp/openwrt-scheduled-backup-r3-pr.md
```

The PR body file must contain exactly these sections and facts:

```markdown
## Summary
- apply standard LuCI table classes to the responsive Status display
- keep credential controls in SFTP and align Backup actions with form inputs
- publish signed `luci-app-scheduled-backup` `1.0.0-r3` through the existing feed

## Verification
- nested backend, LuCI static, and rpcd tests
- repository, feed, and package-output tests
- official OpenWrt 25.12.5 x86_64 SDK build
- APK manifest, view path, layout classes, conffiles, credential scan, and checksums
- strict signatures for every feed APK and `packages.adb`

No live router/browser integration was performed; the supplied r2 screenshot
is the acceptance baseline for the corrected layout.
```

Read the PR back and merge only the reviewed head commit:

```sh
gh pr view --repo Delitants/openwrt-packages \
  --json number,url,state,isDraft,mergeable,headRefOid
gh pr merge --repo Delitants/openwrt-packages --merge
```

- [ ] **Step 7: Verify the merged public bytes**

Run:

```sh
git fetch origin main
git merge-base --is-ancestor HEAD origin/main
mkdir -p work/remote-verify-r3
curl -L --fail --silent --show-error \
  -o work/remote-verify-r3/luci-app-scheduled-backup-1.0.0-r3.apk \
  https://raw.githubusercontent.com/Delitants/openwrt-packages/main/feed/x86_64/luci-app-scheduled-backup-1.0.0-r3.apk
curl -L --fail --silent --show-error \
  -o work/remote-verify-r3/packages.adb \
  https://raw.githubusercontent.com/Delitants/openwrt-packages/main/feed/x86_64/packages.adb
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk verify \
  --keys-dir /src/keys \
  /src/work/remote-verify-r3/luci-app-scheduled-backup-1.0.0-r3.apk
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk verify \
  --keys-dir /src/keys /src/work/remote-verify-r3/packages.adb
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk adbdump --format json \
  /src/work/remote-verify-r3/packages.adb | \
  jq -e '[.packages[] | select(.name == "luci-app-scheduled-backup") | .version] == ["1.0.0-r3"]'
```

Expected: the feature branch is an ancestor of merged `origin/main`; both
public downloads verify against the repository key; and the public index has
exactly one Scheduled Backup entry at r3.

The user upgrade command is:

```sh
apk update
apk upgrade luci-app-scheduled-backup
```
