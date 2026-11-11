#!/usr/bin/env bats
# 4.8 rollback cases RB1 to RB4.

load helpers/common

setup() {
	common_setup
	install_good_snippet
	cp "$OUT" "$BATS_TEST_TMPDIR/good.conf"
	serve_v4 v4-plus-one.txt
	run cfrn
	[ "$status" -eq 0 ]
	cp "$OUT" "$BATS_TEST_TMPDIR/new.conf"
	: >"$CALLS"
	rm -f "$SHIM_DIR"/*.count
}

@test "RB1: rollback swaps, tests and reloads; a second rollback undoes the first" {
	run cfrn --rollback
	[ "$status" -eq 0 ]
	[[ $output == *"rolled back"* ]]
	cmp "$OUT" "$BATS_TEST_TMPDIR/good.conf"
	cmp "$STATE/previous.conf" "$BATS_TEST_TMPDIR/new.conf"
	[ "$(calls '^nginx -t$')" -eq 1 ]
	[ "$(calls '^systemctl reload nginx')" -eq 1 ]
	run cfrn --rollback
	[ "$status" -eq 0 ]
	cmp "$OUT" "$BATS_TEST_TMPDIR/new.conf"
	cmp "$STATE/previous.conf" "$BATS_TEST_TMPDIR/good.conf"
}

@test "RB1: a rollback that fails nginx -t swaps back and exits 4" {
	export NGINX_FULL_RC=1
	run cfrn --rollback
	[ "$status" -eq 4 ]
	cmp "$OUT" "$BATS_TEST_TMPDIR/new.conf"
	cmp "$STATE/previous.conf" "$BATS_TEST_TMPDIR/good.conf"
	[ "$(calls 'reload')" -eq 0 ]
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output != *"held"* ]]
}

@test "RB2: no backup is exit 1, untouched" {
	rm "$STATE/previous.conf"
	before=$(fingerprint)
	run cfrn --rollback
	[ "$status" -eq 1 ]
	[[ $output == *"no backup"* ]]
	assert_untouched "$before"
}

@test "RB3: a scheduled run after a rollback is held without fetching" {
	run cfrn --rollback
	[ "$status" -eq 0 ]
	: >"$CALLS"
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output == *"held after rollback"* ]]
	[ "$(calls '^curl ')" -eq 0 ]
	cmp "$OUT" "$BATS_TEST_TMPDIR/good.conf"
	grep -q '^last_result=held$' "$STATE/state"
}

@test "RB3: --release clears the hold" {
	run cfrn --rollback
	run cfrn --release
	[ "$status" -eq 0 ]
	[[ $output == *"hold released"* ]]
	run cfrn
	[ "$status" -eq 0 ]
	cmp "$OUT" "$BATS_TEST_TMPDIR/new.conf"
}

@test "RB3: an expired hold warns and proceeds" {
	run cfrn --rollback
	sed -i 's/^hold_until=.*/hold_until=1000/' "$STATE/state"
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output == *"hold expired"* ]]
	cmp "$OUT" "$BATS_TEST_TMPDIR/new.conf"
}

@test "RB3: the hold lasts CFRN_HOLD_DAYS" {
	run cfrn --rollback
	hold=$(sed -n 's/^hold_until=//p' "$STATE/state")
	now=$(date +%s)
	[ $((hold - now)) -gt $((7 * 86400 - 60)) ]
	[ $((hold - now)) -le $((7 * 86400)) ]
}

@test "RB4: the backup lives in the state directory only" {
	[ -f "$STATE/previous.conf" ]
	run ls -A "$ROOT/etc/nginx/conf.d"
	[ "$output" = "cloudflare-realip.conf" ]
	run cfrn --rollback
	run ls -A "$ROOT/etc/nginx/conf.d"
	[ "$output" = "cloudflare-realip.conf" ]
}
