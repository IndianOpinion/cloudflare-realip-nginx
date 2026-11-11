#!/usr/bin/env bash
# Offline demo: runs a dry run and a real update against a scratch directory
# with the test stand-ins for curl, nginx and systemctl, so nothing touches
# the network or your nginx. Run it from anywhere:
#
#   examples/offline-demo.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

export SHIM_DIR="$work/shim" FIXTURES="$here/tests/fixtures" TMPDIR="$work/tmp"
export PATH="$here/tests/helpers/shims:$PATH"
mkdir -p "$SHIM_DIR" "$TMPDIR" "$work/etc/nginx/conf.d" "$work/state"
: >"$SHIM_DIR/calls.log"
printf '%s\n' \
	"https://www.cloudflare.com/ips-v4 200 text/plain v4-ok.txt 0" \
	"https://www.cloudflare.com/ips-v6 200 text/plain v6-ok.txt 0" >"$SHIM_DIR/curl.spec"
cat >"$work/config" <<CONFIG
CFRN_OUTPUT=$work/etc/nginx/conf.d/cloudflare-realip.conf
CFRN_STATE_DIR=$work/state
CFRN_SERVICE_MANAGER=systemd
CFRN_SYSLOG=no
CONFIG
export NGINX_DUMP="# configuration file $work/etc/nginx/conf.d/cloudflare-realip.conf:"

tool="$here/bin/cloudflare-realip-nginx"
echo "== dry run"
"$tool" --config "$work/config" --dry-run
echo
echo "== update"
"$tool" --config "$work/config" --quiet && echo "exit $?"
echo
echo "== status"
"$tool" --config "$work/config" --status
echo
echo "== commands the tool ran (stand-ins)"
grep -v '^curl-env' "$SHIM_DIR/calls.log" | sed "s|$work|<work>|g"
