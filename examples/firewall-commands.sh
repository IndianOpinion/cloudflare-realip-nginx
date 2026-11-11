#!/usr/bin/env bash
# Print (never run) firewall commands that allow ports 80 and 443 only from
# Cloudflare's published ranges. Read the output, then run it yourself.
# See README, "Lock the origin to Cloudflare", for the traps first.
#
#   examples/firewall-commands.sh ufw
#   examples/firewall-commands.sh nft
set -euo pipefail

kind=${1:-}
case $kind in ufw | nft) ;; *)
	echo "usage: $0 ufw|nft" >&2
	exit 1
	;;
esac

fetch() {
	curl --silent --show-error --fail --proto =https --tlsv1.2 "$1"
	echo
}
v4=$(fetch https://www.cloudflare.com/ips-v4 | grep -E '^[0-9.]+/[0-9]+$')
v6=$(fetch https://www.cloudflare.com/ips-v6 | grep -E '^[0-9a-fA-F:]+/[0-9]+$')

if [[ $kind == ufw ]]; then
	echo "# Keep your SSH rule. Then allow web traffic from Cloudflare only:"
	for r in $v4 $v6; do
		echo "ufw allow proto tcp from $r to any port 80,443 comment 'cloudflare'"
	done
	echo "# Then remove any rule that allows 80 or 443 from anywhere, for example:"
	echo "#   ufw status numbered   (and delete 'Nginx Full', '80/tcp', '443/tcp' ALLOW Anywhere)"
else
	echo "table inet cloudflare_web {"
	echo "  set cf4 { type ipv4_addr; flags interval; elements = { $(echo $v4 | tr ' ' ',') } }"
	echo "  set cf6 { type ipv6_addr; flags interval; elements = { $(echo $v6 | tr ' ' ',') } }"
	echo "  chain input {"
	echo "    type filter hook input priority -10; policy accept;"
	echo "    tcp dport { 80, 443 } ip saddr @cf4 accept"
	echo "    tcp dport { 80, 443 } ip6 saddr @cf6 accept"
	echo "    tcp dport { 80, 443 } drop"
	echo "  }"
	echo "}"
fi
