#!/bin/sh

sb_validate_uint() {
	_name=$1
	_value=$2
	_min=$3
	_max=$4
	case "$_value" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "$_value" -ge "$_min" ] && [ "$_value" -le "$_max" ]
}

sb_validate_path() {
	case "$1" in
		/*) ;;
		*) return 1 ;;
	esac
	case "$1" in
		*'
'*) return 1 ;;
	esac
}

sb_validate_sftp_host() {
	case "$1" in
		''|*[!A-Za-z0-9.-]*|.*|*..*|*.) return 1 ;;
	esac
}

sb_validate_sftp_user() {
	case "$1" in
		''|*[!A-Za-z0-9._-]*) return 1 ;;
	esac
}

sb_validate_sftp_path() {
	sb_validate_path "$1" || return 1
	case "$1" in
		*[!A-Za-z0-9._/-]*|*..*) return 1 ;;
	esac
}

sb_lftp_quote() {
	printf '%s' "$1" | sed 's/[\\"]/\\&/g'
}

sb_sanitize_hostname() {
	printf '%s\n' "$1" |
		tr '[:upper:]' '[:lower:]' |
		sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' -e 's/-$//'
}

sb_filename() {
	_host=$1
	_epoch=$2
	if [ -n "${SB_DATE:-}" ]; then
		_stamp=$SB_DATE
	else
		_stamp=$(date '+%Y%m%d-%H%M%S')
	fi
	printf 'openwrt-%s-%s.tar.gz\n' "$_host" "$_stamp"
}

sb_cron_line() {
	_mode=$1
	_hour=$2
	_minute=$3
	_weekday=$4
	case "$_mode" in
		daily) _day='*' ;;
		weekly) _day=$_weekday ;;
		*) return 1 ;;
	esac
	printf '%s %s * * %s /usr/sbin/scheduled-backup run\n' "$_minute" "$_hour" "$_day"
}

sb_select_expired() {
	_keep=$1
	shift
	[ "$_keep" -gt 0 ] || return 0
	printf '%s\n' "$@" |
		sed -n '/^openwrt-[a-z0-9-][a-z0-9-]*-[0-9]\{8\}-[0-9]\{6\}\.tar\.gz$/p' |
		sort |
		awk -v keep="$_keep" '{ file[NR] = $0 } END { for (i = 1; i <= NR - keep; i++) print file[i] }'
}

sb_redact() {
	if [ -n "$1" ]; then
		printf '%s\n' '[redacted]'
	else
		printf '\n'
	fi
}

sb_write_status() {
	_status=$1
	shift
	_status_dir=$(dirname -- "$_status")
	mkdir -p "$_status_dir" 2>/dev/null || return 1
	_status_tmp=${_status}.tmp.$$
	{
		printf 'state=%s\n' "$1"
		printf 'started=%s\n' "$2"
		printf 'finished=%s\n' "$3"
		printf 'filename=%s\n' "$4"
		printf 'size=%s\n' "$5"
		printf 'local_result=%s\n' "$6"
		printf 'local_message=%s\n' "$7"
		printf 'sftp_result=%s\n' "$8"
		printf 'sftp_message=%s\n' "$9"
		shift 9
		printf 'summary=%s\n' "$1"
	} >"$_status_tmp" || {
		rm -f "$_status_tmp"
		return 1
	}
	mv -f "$_status_tmp" "$_status" || {
		rm -f "$_status_tmp"
		return 1
	}
}
