#!/usr/bin/env bats
# 4.10 X1: --verify, one failing fixture per check.

load helpers/common

setup() {
	common_setup
	install_good_snippet
}

@test "X1: all checks pass on a healthy setup" {
	run cfrn --verify
	[ "$status" -eq 0 ]
	[ "$(grep -c '^ok:' <<<"$output")" -eq 5 ]
}

@test "X1: a missing snippet fails" {
	rm "$OUT"
	run cfrn --verify
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL: snippet exists"* ]]
}

@test "X1: a foreign snippet fails" {
	cp "$FIXTURES/hand-written-snippet.conf" "$OUT"
	run cfrn --verify
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL: snippet was written by"* ]]
	[[ $output == *"ok:   snippet exists"* ]]
}

@test "X1: a snippet that is not included fails" {
	export NGINX_DUMP="# configuration file /etc/nginx/nginx.conf:"
	run cfrn --verify
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL: snippet is included"* ]]
}

@test "X1: a failing nginx -t fails" {
	export NGINX_FULL_RC=1
	run cfrn --verify
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL: nginx -t passes"* ]]
}

@test "X1: an old last success fails" {
	sed -i 's/^last_success=.*/last_success=1000/' "$STATE/state"
	run cfrn --verify
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL: last success within 14 days"* ]]
}
