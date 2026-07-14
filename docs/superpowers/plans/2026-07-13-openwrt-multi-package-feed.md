# OpenWrt Multi-Package Feed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish Netwatch and its LuCI application in a public, signed, extensible OpenWrt APK feed at `Delitants/openwrt-packages`.

**Architecture:** Group related OpenWrt source packages below `packages/<project>/`, while keeping all installable x86_64 APKs and their single signed index below `feed/x86_64/`. A generic rebuild script indexes every APK in that feed directory, signs `packages.adb` with an ignored local private key, and strictly verifies the APKs and index against the committed public key before publication.

**Tech Stack:** POSIX shell, OpenWrt 25.12.5 x86/64 SDK, apk-tools 3.0.5, Docker, Git, GitHub CLI, raw.githubusercontent.com.

## Global Constraints

- GitHub repository is public and named exactly `Delitants/openwrt-packages`.
- Default branch is `main`.
- Source packages are nested below `packages/netwatch/`.
- The complete feed URL remains `https://raw.githubusercontent.com/Delitants/openwrt-packages/main/feed/x86_64/packages.adb` as packages are added.
- The initial feed contains `netwatch` `1.0.0-r1` and `luci-app-netwatch` `1.0.0-r1`.
- The committed public key is `keys/netwatch-local.pem`.
- The private signing key remains ignored at `work/signing/private-key.pem` and is never committed.
- Package and index verification must use strict `apk verify`; `--allow-untrusted` is not acceptable for the published installation workflow.
- Preserve the user's untracked `.DS_Store` without adding, changing, or deleting it.

---

## File Map

- `packages/netwatch/netwatch/`: Netwatch runtime OpenWrt source package.
- `packages/netwatch/luci-app-netwatch/`: LuCI OpenWrt source package.
- `feed/x86_64/`: Signed binary packages and the single signed repository index.
- `keys/netwatch-local.pem`: Public key routers install to trust the feed.
- `scripts/rebuild-feed.sh`: Generic feed index generation and strict verification.
- `tests/repository-layout_test.sh`: Regression checks for nested package paths.
- `tests/feed_test.sh`: Regression checks for feed inputs, signing safeguards, and expected contents.
- `scripts/build-packages.sh`: SDK links updated for nested sources.
- `scripts/verify-artifacts.sh`: Source archive expectations updated for nested sources.
- `tests/static.sh`: Static checks updated for nested sources and trusted-feed documentation.
- `README.md`: Trusted feed setup, installation, and future package publication instructions.

### Task 1: Relocate Source Packages into the Nested Project Layout

**Files:**
- Create: `tests/repository-layout_test.sh`
- Move: `netwatch/` to `packages/netwatch/netwatch/`
- Move: `luci-app-netwatch/` to `packages/netwatch/luci-app-netwatch/`
- Modify: `scripts/build-packages.sh`
- Modify: `scripts/verify-artifacts.sh`
- Modify: `tests/static.sh`

**Interfaces:**
- Consumes: Existing OpenWrt package sources and test suite.
- Produces: Stable source roots `packages/netwatch/netwatch` and `packages/netwatch/luci-app-netwatch` used by the SDK and later feed documentation.

- [ ] **Step 1: Write the failing layout test**

Create `tests/repository-layout_test.sh`:

```sh
#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for path in \
	packages/netwatch/netwatch/Makefile \
	packages/netwatch/luci-app-netwatch/Makefile
do
	[ -f "$root/$path" ] || {
		echo "missing nested package source: $path" >&2
		exit 1
	}
done

[ ! -e "$root/netwatch" ] || {
	echo 'legacy root package directory remains: netwatch' >&2
	exit 1
}
[ ! -e "$root/luci-app-netwatch" ] || {
	echo 'legacy root package directory remains: luci-app-netwatch' >&2
	exit 1
}

grep -Fq '/src/packages/netwatch/netwatch' "$root/scripts/build-packages.sh"
grep -Fq '/src/packages/netwatch/luci-app-netwatch' "$root/scripts/build-packages.sh"

echo 'repository layout tests passed'
```

- [ ] **Step 2: Run the layout test and verify RED**

Run: `chmod +x tests/repository-layout_test.sh && ./tests/repository-layout_test.sh`

Expected: FAIL with `missing nested package source: packages/netwatch/netwatch/Makefile`.

- [ ] **Step 3: Move both source packages and update consumers**

Run:

```sh
mkdir -p packages/netwatch
git --git-dir=work/git-metadata --work-tree=. mv netwatch packages/netwatch/netwatch
git --git-dir=work/git-metadata --work-tree=. mv luci-app-netwatch packages/netwatch/luci-app-netwatch
```

Update `scripts/build-packages.sh` source paths to:

```sh
for source_dir in \
	/src/packages/netwatch/netwatch \
	/src/packages/netwatch/luci-app-netwatch
do
	if [ ! -f "$source_dir/Makefile" ]; then
		echo "error: missing package source: $source_dir" >&2
		exit 1
	fi
done
```

Update its links to:

```sh
ln -s /src/packages/netwatch/netwatch "$feed_dir/netwatch"
ln -s /src/packages/netwatch/luci-app-netwatch "$feed_dir/luci-app-netwatch"
```

Replace every source-package root in `tests/static.sh` and
`scripts/verify-artifacts.sh` with the corresponding nested path. The source
archive required entries become:

```text
openwrt-netwatch-1.0.0/packages/netwatch/netwatch/Makefile
openwrt-netwatch-1.0.0/packages/netwatch/luci-app-netwatch/Makefile
```

- [ ] **Step 4: Run the layout and existing test suites and verify GREEN**

Run:

```sh
./tests/repository-layout_test.sh
./tests/run-unit.sh \
  tests/unit/config_test.uc \
  tests/unit/ping_test.uc \
  tests/unit/probe_test.uc \
  tests/unit/state_test.uc \
  tests/unit/alerts_test.uc \
  tests/unit/message_test.uc
./tests/static.sh
```

Expected: layout test passes, six unit suites pass, and static verification passes.

- [ ] **Step 5: Commit the nested layout**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  packages scripts/build-packages.sh scripts/verify-artifacts.sh \
  tests/static.sh tests/repository-layout_test.sh
git --git-dir=work/git-metadata --work-tree=. commit \
  -m "refactor: nest OpenWrt package sources"
```

### Task 2: Add Generic Signed Feed Generation

**Files:**
- Create: `scripts/rebuild-feed.sh`
- Create: `tests/feed_test.sh`
- Create: `feed/x86_64/netwatch-1.0.0-r1.apk`
- Create: `feed/x86_64/luci-app-netwatch-1.0.0-r1.apk`
- Create: `feed/x86_64/packages.adb`
- Create: `keys/netwatch-local.pem`

**Interfaces:**
- Consumes: `scripts/in-sdk.sh`, signed APKs in `outputs/`, public key in `outputs/netwatch-local.pem`, private key path passed as argument.
- Produces: `scripts/rebuild-feed.sh ARCH PRIVATE_KEY`, a signed `feed/ARCH/packages.adb`, and strict verification of every indexed APK.

- [ ] **Step 1: Write the failing feed test**

Create `tests/feed_test.sh`:

```sh
#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script=$root/scripts/rebuild-feed.sh

[ -x "$script" ] || {
	echo 'missing executable feed rebuild script' >&2
	exit 1
}

for path in \
	keys/netwatch-local.pem \
	feed/x86_64/netwatch-1.0.0-r1.apk \
	feed/x86_64/luci-app-netwatch-1.0.0-r1.apk
do
	[ -f "$root/$path" ] || {
		echo "missing feed input: $path" >&2
		exit 1
	}
done

grep -Fq 'mkndx' "$script"
grep -Fq -- '--sign-key' "$script"
grep -Fq 'verify --keys-dir' "$script"
grep -Fq 'set -- "$feed_dir"/*.apk' "$script"
grep -Fq 'private key must be inside the repository working tree' "$script"

if git --git-dir="$root/work/git-metadata" --work-tree="$root" \
	ls-files | grep -E '(^|/)(private-key|.*\.key)(\.pem)?$'; then
	echo 'private signing key is tracked' >&2
	exit 1
fi

echo 'feed tests passed'
```

- [ ] **Step 2: Run the feed test and verify RED**

Run: `chmod +x tests/feed_test.sh && ./tests/feed_test.sh`

Expected: FAIL with `missing executable feed rebuild script`.

- [ ] **Step 3: Add feed inputs and the minimal rebuild implementation**

Copy the already signed artifacts under canonical repository filenames:

```sh
mkdir -p feed/x86_64 keys
cp outputs/netwatch_1.0.0-r1_all.apk feed/x86_64/netwatch-1.0.0-r1.apk
cp outputs/luci-app-netwatch_1.0.0-r1_all.apk feed/x86_64/luci-app-netwatch-1.0.0-r1.apk
cp outputs/netwatch-local.pem keys/netwatch-local.pem
```

Create `scripts/rebuild-feed.sh`:

```sh
#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
arch=${1:-}
key_arg=${2:-}

[ -n "$arch" ] || {
	echo "usage: $0 ARCH PRIVATE_KEY" >&2
	exit 2
}
[ -n "$key_arg" ] || {
	echo "usage: $0 ARCH PRIVATE_KEY" >&2
	exit 2
}

case "$key_arg" in
	"$root"/*) key_rel=${key_arg#"$root"/} ;;
	/*)
		echo 'error: private key must be inside the repository working tree' >&2
		exit 2
		;;
	*) key_rel=$key_arg ;;
esac

case "/$key_rel/" in
	*/../*|*/./*)
		echo 'error: private key path must not contain dot segments' >&2
		exit 2
		;;
esac

[ -f "$root/$key_rel" ] || {
	echo "error: private key not found: $key_rel" >&2
	exit 2
}

feed_dir=$root/feed/$arch
[ -d "$feed_dir" ] || {
	echo "error: feed directory not found: feed/$arch" >&2
	exit 2
}

set -- "$feed_dir"/*.apk
[ "$1" != "$feed_dir/*.apk" ] || {
	echo "error: no APK files in feed/$arch" >&2
	exit 2
}

container_feed=/src/feed/$arch
container_key=/src/$key_rel

"$root/scripts/in-sdk.sh" sh -eu -c '
	apk=/sdk/staging_dir/host/bin/apk
	feed_dir=$1
	key=$2
	keys=/src/keys
	tmp=$feed_dir/packages.adb.tmp
	trap "rm -f \"$tmp\"" EXIT HUP INT TERM

	set -- "$feed_dir"/*.apk
	for package do
		"$apk" verify --keys-dir "$keys" "$package"
	done

	"$apk" mkndx \
		--description "Delitants OpenWrt package feed" \
		--sign-key "$key" \
		--output "$tmp" \
		"$@"
	"$apk" verify --keys-dir "$keys" "$tmp"
	"$apk" adbdump --format json "$tmp" >/dev/null
	mv "$tmp" "$feed_dir/packages.adb"
	trap - EXIT HUP INT TERM
' sh "$container_feed" "$container_key"

echo "rebuilt and verified feed/$arch/packages.adb"
```

- [ ] **Step 4: Run the static feed test and verify GREEN**

Run: `chmod +x scripts/rebuild-feed.sh && ./tests/feed_test.sh`

Expected: `feed tests passed`.

- [ ] **Step 5: Generate and strictly verify the real signed index**

Run:

```sh
./scripts/rebuild-feed.sh x86_64 work/signing/private-key.pem
./scripts/in-sdk.sh sh -eu -c '
  apk=/sdk/staging_dir/host/bin/apk
  for file in /src/feed/x86_64/*.apk /src/feed/x86_64/packages.adb; do
    "$apk" verify --keys-dir /src/keys "$file"
  done
  "$apk" adbdump --format json /src/feed/x86_64/packages.adb
' > work/feed-index.json
jq -e '
  [.packages[].name] | sort == ["luci-app-netwatch", "netwatch"]
' work/feed-index.json
```

Expected: every `apk verify` command succeeds and `jq` returns exit status 0.

- [ ] **Step 6: Commit the feed and tooling**

```sh
git --git-dir=work/git-metadata --work-tree=. add \
  scripts/rebuild-feed.sh tests/feed_test.sh keys feed
git --git-dir=work/git-metadata --work-tree=. commit \
  -m "feat: add signed x86_64 package feed"
```

### Task 3: Document Trusted Router Installation and Future Packages

**Files:**
- Modify: `tests/static.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: Published path contract from Tasks 1 and 2.
- Produces: Copy-paste OpenWrt 25.12.5 setup commands and the maintenance procedure for one growing index.

- [ ] **Step 1: Change README assertions first**

Replace the static README expectation `apk add --allow-untrusted` with these
required strings in `tests/static.sh`:

```sh
'https://raw.githubusercontent.com/Delitants/openwrt-packages/main/keys/netwatch-local.pem'
'https://raw.githubusercontent.com/Delitants/openwrt-packages/main/feed/x86_64/packages.adb'
'apk add netwatch luci-app-netwatch'
'./scripts/rebuild-feed.sh x86_64 work/signing/private-key.pem'
```

- [ ] **Step 2: Run the static test and verify RED**

Run: `./tests/static.sh`

Expected: FAIL with missing README content for the public key URL.

- [ ] **Step 3: Update the README**

Replace direct untrusted installation with:

```sh
wget -O /etc/apk/keys/netwatch-local.pem \
  https://raw.githubusercontent.com/Delitants/openwrt-packages/main/keys/netwatch-local.pem
printf '%s\n' \
  'https://raw.githubusercontent.com/Delitants/openwrt-packages/main/feed/x86_64/packages.adb' \
  > /etc/apk/repositories.d/delitants.list
apk update
apk add netwatch luci-app-netwatch
/etc/init.d/netwatch enable
/etc/init.d/netwatch restart
```

Add a `## Package feed maintenance` section explaining that every new signed
APK is copied into `feed/x86_64/`, then the single index is regenerated with:

```sh
./scripts/rebuild-feed.sh x86_64 work/signing/private-key.pem
```

State explicitly that private keys must remain below ignored `work/` storage
and must never be committed.

- [ ] **Step 4: Run documentation checks and verify GREEN**

Run: `./tests/static.sh`

Expected: static verification passes, including trusted-feed documentation.

- [ ] **Step 5: Commit the trusted feed documentation**

```sh
git --git-dir=work/git-metadata --work-tree=. add README.md tests/static.sh
git --git-dir=work/git-metadata --work-tree=. commit \
  -m "docs: add trusted package feed setup"
```

### Task 4: Run the Complete Local Release Gate

**Files:**
- Modify only if a failing verification exposes an implementation defect.

**Interfaces:**
- Consumes: Nested sources, signed APKs, signed index, public documentation.
- Produces: Fresh evidence that the exact tree intended for GitHub is releasable.

- [ ] **Step 1: Run all automated checks**

```sh
./tests/repository-layout_test.sh
./tests/feed_test.sh
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
```

Expected: all commands exit 0.

- [ ] **Step 2: Rebuild and verify the feed from scratch**

```sh
./scripts/rebuild-feed.sh x86_64 work/signing/private-key.pem
./scripts/in-sdk.sh sh -eu -c '
  apk=/sdk/staging_dir/host/bin/apk
  "$apk" verify --keys-dir /src/keys /src/feed/x86_64/netwatch-1.0.0-r1.apk
  "$apk" verify --keys-dir /src/keys /src/feed/x86_64/luci-app-netwatch-1.0.0-r1.apk
  "$apk" verify --keys-dir /src/keys /src/feed/x86_64/packages.adb
'
```

Expected: all three artifacts pass strict verification.

- [ ] **Step 3: Audit tracked and untracked state**

```sh
git --git-dir=work/git-metadata --work-tree=. status --short
git --git-dir=work/git-metadata --work-tree=. ls-files | \
  grep -E '(^|/)(private-key|.*\.key)(\.pem)?$' && exit 1 || true
```

Expected: only the user's existing `?? .DS_Store` is untracked; no private key is listed.

- [ ] **Step 4: Commit any deterministic index refresh**

If rebuilding changed `packages.adb`, inspect, stage, verify again, and commit:

```sh
git --git-dir=work/git-metadata --work-tree=. add feed/x86_64/packages.adb
git --git-dir=work/git-metadata --work-tree=. commit \
  -m "build: refresh signed package index"
```

### Task 5: Create and Publish the GitHub Repository

**Files:**
- External create: `https://github.com/Delitants/openwrt-packages`
- External publish: branch `main`

**Interfaces:**
- Consumes: Locally verified Git history and authenticated GitHub CLI session.
- Produces: Public GitHub repository, raw public key URL, and raw signed feed URL.

- [ ] **Step 1: Verify GitHub identity and name availability**

```sh
gh --version
gh auth status
if gh repo view Delitants/openwrt-packages >/dev/null 2>&1; then
  echo 'error: Delitants/openwrt-packages already exists' >&2
  exit 1
fi
```

Expected: `gh auth status` identifies an account allowed to create repositories in `Delitants`, and the repository does not exist.

- [ ] **Step 2: Create the public repository**

```sh
gh repo create Delitants/openwrt-packages \
  --public \
  --description 'Signed OpenWrt package feed and nested package sources'
git --git-dir=work/git-metadata --work-tree=. remote add origin \
  https://github.com/Delitants/openwrt-packages.git
```

Expected: GitHub reports the repository URL and `git remote -v` shows `origin`.

- [ ] **Step 3: Push main**

```sh
git --git-dir=work/git-metadata --work-tree=. push -u origin main
```

Expected: `main` is created on GitHub and configured as the upstream branch.

- [ ] **Step 4: Verify the public bytes and signatures**

```sh
tmp=$(mktemp -d)
curl -fL \
  https://raw.githubusercontent.com/Delitants/openwrt-packages/main/keys/netwatch-local.pem \
  -o "$tmp/netwatch-local.pem"
curl -fL \
  https://raw.githubusercontent.com/Delitants/openwrt-packages/main/feed/x86_64/packages.adb \
  -o "$tmp/packages.adb"
cmp keys/netwatch-local.pem "$tmp/netwatch-local.pem"
cmp feed/x86_64/packages.adb "$tmp/packages.adb"
```

Then copy the downloaded files below ignored `work/public-feed-check/` and run:

```sh
./scripts/in-sdk.sh /sdk/staging_dir/host/bin/apk verify \
  --keys-dir /src/work/public-feed-check/keys \
  /src/work/public-feed-check/packages.adb
```

Expected: both `cmp` commands and strict public-index verification succeed.

- [ ] **Step 5: Confirm GitHub and local repository state**

```sh
gh repo view Delitants/openwrt-packages \
  --json nameWithOwner,url,visibility,defaultBranchRef
git --git-dir=work/git-metadata --work-tree=. status --short
```

Expected: repository is `PUBLIC`, default branch is `main`, and local status contains no tracked changes and only the preserved `?? .DS_Store`.

---

## Self-Review

- Spec coverage: repository creation, public hosting, nested sources, one stable index, future-package workflow, signing, trust installation, and remote verification are each assigned to a task.
- Placeholder scan: no TBD, TODO, or deferred implementation step remains.
- Interface consistency: every source consumer uses `packages/netwatch/...`; every feed command uses `feed/x86_64`; all publication checks use the same two raw GitHub URLs.
