#!/usr/bin/env bash
# A monitoring check in the Nagios plugin style, built on --verify and
# --diff. Exit 0 OK, 1 WARNING (a change is waiting), 2 CRITICAL.
#
#   examples/monitoring-check.sh [--config FILE]
#
# Run it as root or as a user with the sudoers rules in examples/sudoers.
set -uo pipefail

tool=${CFRN_TOOL:-cloudflare-realip-nginx}

if ! out=$("$tool" "$@" --verify --no-syslog 2>&1); then
	printf 'CRITICAL: %s\n' "$(grep -m 1 '^FAIL' <<<"$out" || echo "verify failed")"
	exit 2
fi
"$tool" "$@" --diff --quiet --no-syslog >/dev/null 2>&1
case $? in
0) echo "OK: snippet is current and nginx accepts it" ;;
10)
	echo "WARNING: Cloudflare's list changed and the snippet has not caught up yet"
	exit 1
	;;
*)
	echo "CRITICAL: could not fetch or validate Cloudflare's lists"
	exit 2
	;;
esac
