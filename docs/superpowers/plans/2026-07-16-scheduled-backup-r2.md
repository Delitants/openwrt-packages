# Scheduled Backup 1.0.0-r2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a package-manager-upgradable `luci-app-scheduled-backup` `1.0.0-r2` whose LuCI view is installed below `/www`, whose installation invalidates LuCI caches, and whose signed feed replaces r1.

**Architecture:** Convert the Scheduled Backup recipe to the standard OpenWrt LuCI `luci.mk` flow used by the repository's Netwatch UI. Keep runtime files and configuration unchanged, extend repository tests and artifact verification to enforce the installed paths and post-install script, then build on a case-sensitive Docker volume and publish the r2 APK through the existing signed x86_64 feed.

**Tech Stack:** OpenWrt 25.12.5 x86_64 SDK, OpenWrt APK tools 3, LuCI `luci.mk`, POSIX shell tests, jq, Docker, Git, GitHub CLI.

## Global Constraints

- Package version is exactly `1.0.0-r2` (`PKG_VERSION:=1.0.0`, `PKG_RELEASE:=2`).
- The public feed URL and committed RSA public key do not change.
- The r1 Scheduled Backup APK is removed from the feed when r2 is added.
- Netwatch `1.0.0-r1` APKs and their signatures remain unchanged.
- `/etc/config/scheduled-backup` and `/etc/scheduled-backup/` remain conffiles.
- Runtime backup, cron, local retention, SFTP, and restore behavior do not change.
- No private signing key is committed.

---

### Task 1: Convert the package recipe to standard LuCI packaging

**Files:**
- Modify: `packages/scheduled-backup/luci-app-scheduled-backup/tests/test_luci_static.sh`
- Modify: `packages/scheduled-backup/luci-app-scheduled-backup/Makefile`

**Interfaces:**
- Consumes: the existing `root/` runtime payload and `htdocs/luci-static/resources/view/scheduled-backup.js`.
- Produces: an OpenWrt LuCI recipe that installs `htdocs/` under `/www`, installs `root/` under `/`, declares r2, and inherits LuCI post-install cache handling.

- [ ] **Step 1: Add failing package-recipe assertions**

Append these assertions before the final success message in `test_luci_static.sh`:

```sh
MAKEFILE=$ROOT/Makefile

grep -Fq 'PKG_VERSION:=1.0.0' "$MAKEFILE"
grep -Fq 'PKG_RELEASE:=2' "$MAKEFILE"
grep -Fq 'LUCI_TITLE:=Scheduled configuration backups' "$MAKEFILE"
grep -Fq 'LUCI_PKGARCH:=all' "$MAKEFILE"
grep -Fq 'LUCI_DEPENDS:=' "$MAKEFILE"
grep -Fq '+luci-base' "$MAKEFILE"
grep -Fq '+rpcd-mod-file' "$MAKEFILE"
grep -Fq 'include $(TOPDIR)/feeds/luci/luci.mk' "$MAKEFILE"
grep -Fq 'define Package/$(PKG_NAME)/conffiles' "$MAKEFILE"
grep -Fxq '/etc/config/scheduled-backup' "$MAKEFILE"
grep -Fxq '/etc/scheduled-backup/' "$MAKEFILE"

if grep -Fq '$(CP) ./htdocs/* $(1)/' "$MAKEFILE"; then
	echo 'Scheduled Backup still installs htdocs at filesystem root' >&2
	exit 1
fi
```

- [ ] **Step 2: Run the test and confirm the r1 recipe fails**

Run:

```sh
packages/scheduled-backup/luci-app-scheduled-backup/tests/test_luci_static.sh
```

Expected: nonzero exit at `PKG_RELEASE:=2` or the first missing `LUCI_*` declaration.

- [ ] **Step 3: Replace the package recipe**

Replace `packages/scheduled-backup/luci-app-scheduled-backup/Makefile` with:

```make
include $(TOPDIR)/rules.mk

PKG_VERSION:=1.0.0
PKG_RELEASE:=2
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Scheduled Backup maintainers

LUCI_TITLE:=Scheduled configuration backups
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-file +uci +lftp +openssh-client +openssh-client-utils +openssh-keygen
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/scheduled-backup
/etc/scheduled-backup/
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
```

- [ ] **Step 4: Run the nested package suite**

Run:

```sh
packages/scheduled-backup/luci-app-scheduled-backup/tests/run.sh
```

Expected: exit 0 with `LuCI static contracts passed`, `backend tests passed`, and `rpcd tests passed` among the output.

- [ ] **Step 5: Commit the recipe correction**

```sh
git add \
  packages/scheduled-backup/luci-app-scheduled-backup/Makefile \
  packages/scheduled-backup/luci-app-scheduled-backup/tests/test_luci_static.sh
git commit -m "fix scheduled backup LuCI packaging"
```

---

### Task 2: Update release plumbing, documentation, and artifact contracts

**Files:**
- Modify: `tests/feed_test.sh`
- Modify: `tests/package-output_test.sh`
- Modify: `tests/static.sh`
- Modify: `scripts/package-output.sh`
- Modify: `scripts/verify-artifacts.sh`
- Modify: `packages/scheduled-backup/luci-app-scheduled-backup/README.md`
- Modify: `docs/plans/2026-07-13-openwrt-packages-repository-design.md`

**Interfaces:**
- Consumes: the r2 package recipe from Task 1 and built APK metadata from Task 3.
- Produces: stable `_all.apk` output naming, r2 feed expectations, upgrade instructions, and artifact checks for paths, scripts, dependencies, and conffiles.

- [ ] **Step 1: Make feed and output tests require r2**

In `tests/feed_test.sh`, replace the Scheduled Backup feed input with:

```sh
feed/x86_64/luci-app-scheduled-backup-1.0.0-r2.apk
```

Add this r1 exclusion after the feed-input loop:

```sh
[ ! -e "$root/feed/x86_64/luci-app-scheduled-backup-1.0.0-r1.apk" ] || {
	echo 'obsolete scheduled-backup r1 APK remains in feed' >&2
	exit 1
}
```

Add this README contract:

```sh
grep -Fq 'apk upgrade luci-app-scheduled-backup' "$scheduled_readme" || {
	echo 'README omits scheduled-backup package-manager upgrade' >&2
	exit 1
}
```

In `tests/package-output_test.sh`, change the Scheduled Backup fixture and assertions to:

```sh
printf 'scheduled backup apk fixture\n' > "$tmp/work/sdk/bin/packages/base/luci-app-scheduled-backup-1.0.0-r2.apk"

[ -f "$tmp/outputs/luci-app-scheduled-backup_1.0.0-r2_all.apk" ] || {
	echo 'scheduled-backup r2 APK was not published to outputs' >&2
	exit 1
}
grep -Fq 'luci-app-scheduled-backup_1.0.0-r2_all.apk' \
	"$tmp/outputs/SHA256SUMS"
```

In `tests/static.sh`, require all of these strings in the Scheduled Backup README:

```sh
'apk upgrade luci-app-scheduled-backup'
'1.0.0-r2'
'/www/luci-static/resources/view/scheduled-backup.js'
```

Also require `outputs/luci-app-scheduled-backup_1.0.0-r2_all.apk` in `scripts/verify-artifacts.sh`:

```sh
grep -Fq 'outputs/luci-app-scheduled-backup_1.0.0-r2_all.apk' \
	"$root/scripts/verify-artifacts.sh" || {
	echo 'artifact verifier omits Scheduled Backup r2' >&2
	fail=1
}
```

- [ ] **Step 2: Run the release tests and confirm they fail against r1**

Run:

```sh
sh tests/feed_test.sh
sh tests/package-output_test.sh
sh tests/static.sh
```

Expected: failures report the missing r2 feed APK, missing r2 output, and missing upgrade/artifact-verification contracts.

- [ ] **Step 3: Update output packaging to r2**

In `scripts/package-output.sh`, use:

```sh
scheduled_backup_apk=$(find_one_apk 'Scheduled Backup LuCI' \
	'luci-app-scheduled-backup-1.0.0-r2.apk')

scheduled_backup_output=$output_dir/luci-app-scheduled-backup_1.0.0-r2_all.apk
```

Replace the Scheduled Backup checksum input with:

```sh
outputs/luci-app-scheduled-backup_1.0.0-r2_all.apk \
```

- [ ] **Step 4: Extend built-artifact verification**

In `scripts/verify-artifacts.sh`, add:

```sh
scheduled=outputs/luci-app-scheduled-backup_1.0.0-r2_all.apk
```

Include `"$scheduled"` in the required-artifact loop. Extend the SDK command to dump and extract it:

```sh
scheduled=$4
"$apk" adbdump --format json "$scheduled" > "$tmp/scheduled.json"
mkdir -p "$tmp/extracted/scheduled"
"$apk" --allow-untrusted extract --no-chown \
	--destination "$tmp/extracted/scheduled" "$scheduled"
```

Pass `"/src/$scheduled"` as the fourth data argument to that SDK shell command. Add these assertions after the Netwatch metadata checks:

```sh
jq -e '
	.info.name == "luci-app-scheduled-backup" and
	.info.version == "1.0.0-r2" and
	.info.arch == "noarch" and
	(.info.depends | sort == [
		"lftp", "libc", "luci-base", "openssh-client",
		"openssh-client-utils", "openssh-keygen", "rpcd",
		"rpcd-mod-file", "uci"
	])
' "$tmp/scheduled.json" >/dev/null

jq -e '
	any(.paths[];
		.name == "www/luci-static/resources/view" and
		any(.files[]?; .name == "scheduled-backup.js")) and
	(any(.paths[];
		.name == "luci-static/resources/view" and
		any(.files[]?; .name == "scheduled-backup.js")) | not) and
	any(.paths[];
		.name == "usr/share/luci/menu.d" and
		any(.files[]?; .name == "luci-app-scheduled-backup.json")) and
	any(.paths[];
		.name == "usr/share/rpcd/acl.d" and
		any(.files[]?; .name == "luci-app-scheduled-backup.json")) and
	(.scripts["post-install"] | contains("rm -f /tmp/luci-indexcache.*")) and
	(.scripts["post-install"] | contains("rm -rf /tmp/luci-modulecache/")) and
	(.scripts["post-install"] | contains("/etc/init.d/rpcd reload"))
' "$tmp/scheduled.json" >/dev/null

grep -Fxq '/etc/config/scheduled-backup' \
	"$tmp/extracted/scheduled/lib/apk/packages/luci-app-scheduled-backup.conffiles"
grep -Fxq '/etc/scheduled-backup/' \
	"$tmp/extracted/scheduled/lib/apk/packages/luci-app-scheduled-backup.conffiles"
```

Add this path to the source-archive required-file loop:

```sh
openwrt-netwatch-1.0.0/packages/scheduled-backup/luci-app-scheduled-backup/Makefile \
```

The existing writable-file and credential scans already cover every directory below `$tmp/extracted`, including the new Scheduled Backup extraction.

- [ ] **Step 5: Document package-manager upgrade and r2 layout**

Replace the Scheduled Backup README upgrade block with:

```markdown
## Upgrade

Version `1.0.0-r2` corrects LuCI installation and cache handling. Upgrade from
the existing signed feed with:

```sh
apk update
apk upgrade luci-app-scheduled-backup
```

The corrected view is installed at
`/www/luci-static/resources/view/scheduled-backup.js`. Log out of LuCI and
back in if the browser session still has the pre-upgrade ACL set.
```

Retain the existing paragraph explaining preservation of UCI configuration,
SFTP credentials, private key, and host identity.

In `docs/plans/2026-07-13-openwrt-packages-repository-design.md`, change the
Scheduled Backup feed filename and version references from `1.0.0-r1` to
`1.0.0-r2` without changing either Netwatch version.

- [ ] **Step 6: Run source-level release tests**

Run:

```sh
sh tests/repository-layout_test.sh
sh tests/feed_test.sh || test "$?" -eq 1
sh tests/package-output_test.sh
packages/scheduled-backup/luci-app-scheduled-backup/tests/run.sh
git diff --check
```

Expected: every test except `feed_test.sh` passes. `feed_test.sh` fails only because the generated r2 feed APK is intentionally not present until Task 3.

- [ ] **Step 7: Commit source and test changes**

```sh
git add \
  packages/scheduled-backup/luci-app-scheduled-backup/README.md \
  scripts/package-output.sh \
  scripts/verify-artifacts.sh \
  tests/feed_test.sh \
  tests/package-output_test.sh \
  tests/static.sh \
  docs/plans/2026-07-13-openwrt-packages-repository-design.md
git commit -m "prepare scheduled backup r2 release"
```

---

### Task 3: Build and verify r2 on a case-sensitive SDK volume

**Files:**
- Generate (ignored): `outputs/luci-app-scheduled-backup_1.0.0-r2_all.apk`
- Generate (ignored): `outputs/SHA256SUMS`
- Generate (ignored): `outputs/openwrt-netwatch-1.0.0-source.tar.gz`
- Generate (ignored): `work/sdk/bin/packages/x86_64/base/luci-app-scheduled-backup-1.0.0-r2.apk`

**Interfaces:**
- Consumes: the committed r2 source recipe, cached official SDK archive, and unchanged Netwatch build outputs.
- Produces: an SDK-built noarch r2 APK whose manifest and installed file paths satisfy `scripts/verify-artifacts.sh`.

- [ ] **Step 1: Confirm a clean committed source tree**

Run:

```sh
git status --short
git log -3 --oneline
```

Expected: no tracked changes and the design, packaging fix, and release-preparation commits at HEAD.

- [ ] **Step 2: Create and populate a case-sensitive Docker volume**

Run from the repository root:

```sh
repo=$(pwd -P)
archive=/Users/neolo/Documents/Codex/2026-07-10/ca/work/downloads/openwrt-sdk-25.12.5-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
volume=openwrt-sdk-25.12.5-scheduled-backup-r2
image=netwatch-openwrt-sdk:25.12.5

printf '%s  %s\n' \
  '0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c' \
  "$archive" | shasum -a 256 -c -
docker volume create "$volume"
docker run --rm --platform linux/amd64 \
  -v "$volume:/sdk" \
  -v "$archive:/tmp/openwrt-sdk.tar.zst:ro" \
  "$image" sh -eu -c '
    find /sdk -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    tar --zstd -xf /tmp/openwrt-sdk.tar.zst -C /sdk --strip-components=1
  '
```

Expected: checksum reports `OK`; the SDK is extracted into a Docker-managed,
case-sensitive filesystem.

- [ ] **Step 3: Install only required feed sources and build r2**

Run:

```sh
mkdir -p outputs
docker run --rm --platform linux/amd64 \
  -v "$volume:/sdk" \
  -v "$repo:/src" \
  -w /sdk \
  "$image" sh -eu -c '
    ./scripts/feeds update -a
    ./scripts/feeds install luci-base
    ./scripts/feeds install lftp
    ./scripts/feeds install openssh
    ln -s /src/packages/scheduled-backup/luci-app-scheduled-backup \
      package/luci-app-scheduled-backup
    trap "rm -f package/luci-app-scheduled-backup" EXIT HUP INT TERM
    printf "%s\n" \
      "# CONFIG_ALL is not set" \
      "# CONFIG_ALL_KMODS is not set" \
      "# CONFIG_ALL_NONSHARED is not set" \
      "CONFIG_PACKAGE_luci-app-scheduled-backup=y" > .config
    make defconfig
    make package/luci-app-scheduled-backup/clean
    make package/luci-app-scheduled-backup/compile V=s -j1
    matches=$(find bin/packages -type f \
      -name "luci-app-scheduled-backup-1.0.0-r2.apk" -print)
    count=$(printf "%s\n" "$matches" | awk "NF { n++ } END { print n + 0 }")
    [ "$count" -eq 1 ]
    cp "$matches" /src/outputs/luci-app-scheduled-backup_1.0.0-r2_all.apk
  '
```

Expected: package compilation exits 0 and exactly one r2 APK is copied to
`outputs/`.

- [ ] **Step 4: Put all three built APKs in the shared output workflow**

Run:

```sh
sdk_packages=/Users/neolo/Documents/Codex/2026-07-10/ca/work/sdk/bin/packages/x86_64/base
cp outputs/luci-app-scheduled-backup_1.0.0-r2_all.apk \
  "$sdk_packages/luci-app-scheduled-backup-1.0.0-r2.apk"
./scripts/package-output.sh
```

Expected: `package-output.sh` finds the two unchanged Netwatch r1 APKs and the
Scheduled Backup r2 APK, then generates all outputs and checksums from a clean
Git snapshot.

- [ ] **Step 5: Verify built artifacts**

Run:

```sh
./scripts/verify-artifacts.sh
```

Expected: exit 0. Scheduled Backup reports version `1.0.0-r2`, architecture
`noarch`, a view below `/www`, no root-level `/luci-static` view, the standard
LuCI cache-invalidating post-install script, and preserved conffiles.

---

### Task 4: Replace r1 in the signed feed and publish to main

**Files:**
- Delete: `feed/x86_64/luci-app-scheduled-backup-1.0.0-r1.apk`
- Create: `feed/x86_64/luci-app-scheduled-backup-1.0.0-r2.apk`
- Modify (generated): `feed/x86_64/packages.adb`

**Interfaces:**
- Consumes: the verified r2 output and ignored `work/signing/private-key.pem`.
- Produces: the existing public feed URL with exactly one Scheduled Backup entry at r2, then a merged GitHub release commit on `main`.

- [ ] **Step 1: Replace and sign the Scheduled Backup feed APK**

Run:

```sh
git rm feed/x86_64/luci-app-scheduled-backup-1.0.0-r1.apk
cp outputs/luci-app-scheduled-backup_1.0.0-r2_all.apk \
  feed/x86_64/luci-app-scheduled-backup-1.0.0-r2.apk
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk \
  --allow-untrusted adbsign \
  --reset-signatures \
  --sign-key /src/work/signing/private-key.pem \
  /src/feed/x86_64/luci-app-scheduled-backup-1.0.0-r2.apk
```

Expected: the r2 APK has exactly the repository signature and r1 is staged for
deletion.

- [ ] **Step 2: Rebuild and strictly verify the combined feed**

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
Netwatch and LuCI Netwatch `1.0.0-r1` plus Scheduled Backup `1.0.0-r2` only.

- [ ] **Step 3: Run the complete final verification gate**

Run:

```sh
sh tests/static.sh
sh tests/repository-layout_test.sh
sh tests/feed_test.sh
sh tests/package-output_test.sh
packages/scheduled-backup/luci-app-scheduled-backup/tests/run.sh
./scripts/verify-artifacts.sh
git diff --check
test -z "$(git ls-files 'work/*' '*private-key*' '*.key' '*.key.pem')"
```

Expected: every command exits 0 and no private key path is tracked.

- [ ] **Step 4: Commit the signed feed update**

```sh
git add \
  feed/x86_64/luci-app-scheduled-backup-1.0.0-r2.apk \
  feed/x86_64/packages.adb
git status -sb
git diff --cached --check
git commit -m "publish scheduled backup 1.0.0-r2"
```

- [ ] **Step 5: Push, open a ready PR, and merge after readback**

```sh
git push -u origin agent/fix-scheduled-backup-r2
gh pr create \
  --repo Delitants/openwrt-packages \
  --base main \
  --head agent/fix-scheduled-backup-r2 \
  --title "publish scheduled backup 1.0.0-r2" \
  --body-file /private/tmp/openwrt-scheduled-backup-r2-pr.md
gh pr view --repo Delitants/openwrt-packages \
  --json number,url,state,isDraft,mergeable,mergeStateStatus,headRefOid
gh pr merge --repo Delitants/openwrt-packages --merge
```

The PR body file must state the root cause, standard `luci.mk` correction,
package-manager upgrade command, r2 artifact path, strict signature results,
and the absence of live router integration. Merge only if GitHub reports the
reviewed head commit as cleanly mergeable.

- [ ] **Step 6: Verify publication on `main`**

```sh
gh pr view --repo Delitants/openwrt-packages \
  --json url,state,mergedAt,mergeCommit
git ls-remote origin refs/heads/main
```

Expected: PR state is `MERGED`, and remote `main` matches the reported merge
commit. The user can then run:

```sh
apk update
apk upgrade luci-app-scheduled-backup
```
