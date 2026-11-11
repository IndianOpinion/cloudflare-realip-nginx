#!/usr/bin/env bats
# 4.9 dry run and diff mode, D1 to D4.

load helpers/common

setup() { common_setup; }

@test "D1: dry run prints the snippet and changes nothing" {
	run --separate-stderr cfrn --dry-run
	[ "$status" -eq 0 ]
	[ "$output" = "$(cat "$GOLDEN/default.conf")" ]
	[ ! -e "$OUT" ]
	[ "$(calls 'reload')" -eq 0 ]
	[ "$(calls '^nginx')" -eq 0 ]
}

@test "D1: dry run with --test runs the candidate syntax test only" {
	run cfrn --dry-run --test
	[ "$status" -eq 0 ]
	[[ $output == *"candidate test passed"* ]]
	[ "$(calls '^nginx -t -q')" -eq 1 ]
	[ "$(calls '^nginx -t$')" -eq 0 ]
	export NGINX_CANDIDATE_RC=1
	run cfrn --dry-run --test
	[ "$status" -eq 4 ]
}

@test "D1: dry run returns the same failure codes as a real run" {
	serve_v4 v4-private.txt
	run cfrn --dry-run
	[ "$status" -eq 3 ]
}

@test "D2: diff exits 0 when the same and 10 when different" {
	run cfrn
	run cfrn --diff
	[ "$status" -eq 0 ]
	serve_v4 v4-plus-one.txt
	run --separate-stderr cfrn --diff
	[ "$status" -eq 10 ]
	[[ $output == *"+set_real_ip_from 45.85.118.0/23;"* ]]
	[[ $output == *"--- $OUT (live)"* ]]
}

@test "D3: neither mode writes state, takes a lock or calls reload" {
	run cfrn --dry-run
	run cfrn --diff
	[ ! -e "$STATE/state" ]
	[ ! -e "$STATE/lock" ]
	[ "$(calls 'reload')" -eq 0 ]
	[ "$(calls 'is-active')" -eq 0 ]
}

@test "D4: dry run as non-root with a readable snippet works" {
	run cfrn
	rm -r "$STATE"
	export FAKE_UID=1000
	run cfrn --dry-run
	[ "$status" -eq 0 ]
	run cfrn --diff
	[ "$status" -eq 0 ]
	[ "$(calls '^sudo')" -eq 0 ]
}
