# OpenWrt Multi-Package Repository Design

## Goal

Publish the signed Netwatch runtime and LuCI packages from a public GitHub
repository owned by `Delitants`, while keeping the repository suitable for
additional OpenWrt package projects. All packages for the `x86_64` feed are
indexed by one signed `packages.adb` file at a stable URL.

## Repository

- GitHub repository: `Delitants/openwrt-packages`
- Visibility: public
- Default branch: `main`
- Feed URL:
  `https://raw.githubusercontent.com/Delitants/openwrt-packages/main/feed/x86_64/packages.adb`

The raw GitHub URL avoids a separate Pages deployment and changes only when a
new commit updates the feed. OpenWrt is configured with the complete
`packages.adb` URL.

## Layout

```text
openwrt-packages/
|-- packages/
|   `-- netwatch/
|       |-- netwatch/
|       `-- luci-app-netwatch/
|   `-- scheduled-backup/
|       `-- luci-app-scheduled-backup/
|-- feed/
|   `-- x86_64/
|       |-- packages.adb
|       |-- netwatch-1.1.0-r1.apk
|       |-- luci-app-netwatch-1.1.0-r1.apk
|       `-- luci-app-scheduled-backup-1.0.0-r3.apk
|-- keys/
|   `-- netwatch-local.pem
`-- scripts/
    `-- rebuild-feed.sh
```

Each project receives a directory below `packages/`; a project may contain
multiple related OpenWrt source packages. Scheduled Backup uses
`packages/scheduled-backup/luci-app-scheduled-backup/` without changing the
binary feed URL.

The binary feed is separate from the source hierarchy. Every APK available to
the x86_64 router is stored beside `feed/x86_64/packages.adb`, regardless of
which project produced it. Regenerating that one index adds or updates package
entries without requiring another repository URL.

## Signing and Trust

- Commit only the public RSA key at `keys/netwatch-local.pem`.
- Never commit the private signing key.
- Preserve valid repository-key signatures on every APK.
- Build `packages.adb` from all APKs in `feed/x86_64/` and sign the index with
  the same private key.
- Verify both APK signatures and the generated index with strict `apk verify`
  before publishing.

The repository includes a repeatable feed rebuild script. It requires the
private key as an explicit local argument or environment-supplied path and
refuses to find or commit a private key implicitly.

## Publication Workflow

1. Build and sign a package.
2. Copy its canonical APK filename into `feed/x86_64/`.
3. Regenerate and sign `feed/x86_64/packages.adb` over every APK in that
   directory.
4. Strictly verify the complete feed with the committed public key.
5. Commit and push the source and feed changes to `main`.

The feed contains Netwatch `1.1.0-r1`, `luci-app-netwatch` `1.1.0-r1`, and
`luci-app-scheduled-backup` `1.0.0-r3`.

## Router Setup

The README will document how to install the public key, add the complete feed
URL, update the indexes, and install the packages without
`--allow-untrusted`. The exact commands will target OpenWrt 25.12.5 and use
the native APK repository configuration available on that release.

## Verification

Before the GitHub repository is considered published:

- the existing project tests and artifact checks must pass after relocation;
- all APK files must pass strict signature verification;
- `packages.adb` must pass strict signature verification;
- the index must contain exactly the expected initial package names and
  versions;
- the raw GitHub feed URL and public key URL must return the committed bytes;
- no private key or unrelated local file may be tracked.
