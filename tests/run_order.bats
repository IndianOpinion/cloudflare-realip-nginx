#!/usr/bin/env bats
# 4.1: the run stops at the first failing step and nothing after it runs.

load helpers/common

setup() { common_setup; }

@test "4.1: a config error stops before any network call" {
	setting CFRN_HEADER 'bad;header'
	run cfrn
	[ "$status" -eq 1 ]
	[ "$(calls '^curl ')" -eq 0 ]
	[ "$(calls '^nginx')" -eq 0 ]
}

@test "4.1: an IPv4 fetch failure stops before the IPv6 fetch and before nginx" {
	reset_url "$V4_URL"
	serve "$V4_URL" 404 text/html - 0
	run cfrn
	[ "$status" -eq 2 ]
	[ "$(calls "^curl $V6_URL")" -eq 0 ]
	[ "$(calls '^nginx -t')" -eq 0 ]
	[ ! -e "$OUT" ]
}

@test "4.1: a validation failure stops before any nginx command" {
	serve_v4 v4-host-bits.txt
	run cfrn
	[ "$status" -eq 3 ]
	[ "$(calls '^nginx')" -eq 0 ]
	[ ! -e "$OUT" ]
}

@test "4.1: a candidate test failure stops before backup, rename, full test and reload" {
	install_good_snippet
	serve_v4 v4-plus-one.txt
	before=$(fingerprint)
	export NGINX_CANDIDATE_RC=1
	run cfrn
	[ "$status" -eq 4 ]
	[ "$(calls '^nginx -t$')" -eq 0 ]
	assert_untouched "$before"
}

@test "4.1: steps run in the documented order on a change" {
	run cfrn
	[ "$status" -eq 0 ]
	order=$(grep -v '^logger\|^curl-env' "$CALLS" | sed 's/ .*//' | uniq | tr '\n' ' ')
	[ "$order" = "curl nginx systemctl " ]
	grep -n '' "$CALLS" | grep -v 'logger\|curl-env' >"$BATS_TEST_TMPDIR/seq"
	run grep -o 'nginx -t -q\|nginx -t$\|nginx -T\|systemctl reload' "$BATS_TEST_TMPDIR/seq"
	[ "${lines[0]}" = "nginx -t -q" ]
	[ "${lines[1]}" = "nginx -t" ]
	[ "${lines[2]}" = "nginx -T" ]
	[ "${lines[3]}" = "systemctl reload" ]
}
