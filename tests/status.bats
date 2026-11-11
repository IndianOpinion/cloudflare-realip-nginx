#!/usr/bin/env bats
# 4.10 X4: --status and the staleness warning.

load helpers/common

setup() { common_setup; }

@test "X4: status prints the last run, last success, counts and hash" {
	run cfrn
	run cfrn --status
	[ "$status" -eq 0 ]
	[[ $output == *"ranges:         15 IPv4, 7 IPv6"* ]]
	[[ $output == *"last run:"*"(updated, exit 0)"* ]]
	[[ $output == *"snippet sha256: $(sha256sum "$OUT" | cut -d ' ' -f 1)"* ]]
	[[ $output != *"warning"* ]]
}

@test "X4: a stale success shows a warning" {
	run cfrn
	sed -i 's/^last_success=.*/last_success=1000/' "$STATE/state"
	run cfrn --status
	[ "$status" -eq 0 ]
	[[ $output == *"warning: last success was"*"days ago (limit 14 days)"* ]]
}

@test "X4: every run logs the staleness warning" {
	run cfrn
	sed -i 's/^last_success=.*/last_success=1000/' "$STATE/state"
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output == *"warning: last success was"* ]]
	grep -q 'logger .*daemon.warning.*last success was' "$CALLS"
}

@test "X4: status with no runs says so" {
	run cfrn --status
	[ "$status" -eq 0 ]
	[[ $output == *"last success:   never"* ]]
	[[ $output == *"no successful run recorded yet"* ]]
}

@test "observability: a failed run is recorded in the state file" {
	run cfrn
	serve_v4 v4-private.txt
	run cfrn
	[ "$status" -eq 3 ]
	grep -q '^last_exit=3$' "$STATE/state"
	grep -q '^last_result=failed$' "$STATE/state"
	grep -q 'logger .*daemon.err' "$CALLS"
}

@test "metrics: the textfile is off by default and written when configured" {
	run cfrn
	[ -z "$(find "$BATS_TEST_TMPDIR" -name '*.prom')" ]
	mkdir "$BATS_TEST_TMPDIR/metrics"
	setting CFRN_METRICS_DIR "$BATS_TEST_TMPDIR/metrics"
	run cfrn
	[ "$status" -eq 0 ]
	prom="$BATS_TEST_TMPDIR/metrics/cloudflare_realip_nginx.prom"
	grep -q '^cloudflare_realip_nginx_ranges{family="ipv4"} 15$' "$prom"
	grep -q '^cloudflare_realip_nginx_last_run_exit_code 0$' "$prom"
}
