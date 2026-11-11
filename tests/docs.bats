#!/usr/bin/env bats
# X2 and X3 are manual steps; these tests make sure the README carries them,
# along with the firewall section that section 8 of the PRD requires.

load helpers/common

README="$REPO_ROOT/README.md"

@test "X2: README contains the log format and the trace steps" {
	grep -q 'realip_remote_addr' "$README"
	grep -q '/cdn-cgi/trace' "$README"
	grep -q 'log_format' "$README"
}

@test "X3: README contains the spoof check" {
	grep -q 'CF-Connecting-IP: 203.0.113' "$README"
	grep -qi 'spoof check' "$README"
}

@test "8: README has the firewall section with its traps" {
	grep -q '^## Lock the origin to Cloudflare' "$README"
	grep -q 'HTTP-01' "$README"
	grep -qi 'ufw' "$README"
	grep -qi 'nftables' "$README"
	grep -qi 'Authenticated Origin Pulls' "$README"
	grep -q '240.0.0.0/4' "$README"
}

@test "repo: no em dashes anywhere" {
	run grep -rIl $'\xe2\x80\x94' "$REPO_ROOT" --exclude-dir=.git
	[ "$status" -eq 1 ]
}
