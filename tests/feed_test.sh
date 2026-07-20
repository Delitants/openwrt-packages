#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script=$root/scripts/rebuild-feed.sh
readme=$root/README.md
scheduled_readme=$root/packages/scheduled-backup/luci-app-scheduled-backup/README.md

git --git-dir="$root/work/git-metadata" --work-tree="$root" \
	check-ignore -q .DS_Store || {
	echo '.DS_Store is not ignored' >&2
	exit 1
}

[ -x "$script" ] || {
	echo 'missing executable feed rebuild script' >&2
	exit 1
}

for path in \
	keys/netwatch-local.pem \
	feed/x86_64/netwatch-1.1.0-r1.apk \
	feed/x86_64/luci-app-netwatch-1.1.0-r1.apk \
	feed/x86_64/luci-app-scheduled-backup-1.0.0-r3.apk
do
	[ -f "$root/$path" ] || {
		echo "missing feed input: $path" >&2
		exit 1
	}
done

if find "$root/feed/x86_64" -maxdepth 1 -type f \
	\( -name 'netwatch-*.apk' -o -name 'luci-app-netwatch-*.apk' \) \
	! -name 'netwatch-1.1.0-r1.apk' \
	! -name 'luci-app-netwatch-1.1.0-r1.apk' -print | grep -q .; then
	echo 'obsolete Netwatch APK remains in feed' >&2
	exit 1
fi

for obsolete in \
	feed/x86_64/luci-app-scheduled-backup-1.0.0-r1.apk \
	feed/x86_64/luci-app-scheduled-backup-1.0.0-r2.apk
do
	[ ! -e "$root/$obsolete" ] || {
		echo "obsolete Scheduled Backup APK remains in feed: $obsolete" >&2
		exit 1
	}
done

grep -Fq 'mkndx' "$script"
grep -Fq '"$apk" --allow-untrusted mkndx' "$script" || {
	echo 'mkndx does not allow already verified signed inputs' >&2
	exit 1
}
grep -Fq -- '--sign-key' "$script"
grep -Fq 'verify --keys-dir' "$script"
grep -Fq 'set -- "$feed_dir"/*.apk' "$script"
grep -Fq 'private key must be inside the repository working tree' "$script"
grep -Fq '/apk --allow-untrusted adbsign' "$readme" || {
	echo 'README signing example does not allow replacing the SDK signature' >&2
	exit 1
}
grep -Fq -- '--reset-signatures --sign-key' "$readme" || {
	echo 'README signing example does not reset the SDK signature' >&2
	exit 1
}
grep -Fq 'apk add luci-app-scheduled-backup' "$scheduled_readme" || {
	echo 'README omits scheduled-backup installation' >&2
	exit 1
}
grep -Fq 'System > Scheduled Backup' "$scheduled_readme" || {
	echo 'README omits scheduled-backup LuCI location' >&2
	exit 1
}
grep -Fq 'apk upgrade luci-app-scheduled-backup' "$scheduled_readme" || {
	echo 'README omits scheduled-backup package-manager upgrade' >&2
	exit 1
}

if git --git-dir="$root/work/git-metadata" --work-tree="$root" \
	ls-files | grep -E '(^|/)(private-key|.*\.key)(\.pem)?$'; then
	echo 'private signing key is tracked' >&2
	exit 1
fi

echo 'feed tests passed'
