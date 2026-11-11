#!/usr/bin/env bats
# F17 and F18: tolerant line handling, strict content.

load helpers/common

setup() { common_setup; }

@test "F17: the last range without a newline is kept (15 and 7 counted)" {
	[ "$(tail -c 1 "$FIXTURES/v4-ok.txt" | od -An -c | tr -d ' ')" = "2" ]
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output == *"15 IPv4, 7 IPv6"* ]]
	grep -q '131.0.72.0/22' "$OUT"
	grep -q '2c0f:f248::/32' "$OUT"
}

@test "F18: CRLF line endings are tolerated" {
	serve_v4 v4-crlf.txt
	run --separate-stderr cfrn --dry-run
	[ "$status" -eq 0 ]
	[ "$output" = "$(cat "$GOLDEN/default.conf")" ]
}

@test "F18: a UTF-8 byte order mark is tolerated" {
	serve_v4 v4-bom.txt
	run --separate-stderr cfrn --dry-run
	[ "$status" -eq 0 ]
	[ "$output" = "$(cat "$GOLDEN/default.conf")" ]
}

@test "F18: blank lines, spaces and tabs are tolerated" {
	serve_v4 v4-blank-lines.txt
	run --separate-stderr cfrn --dry-run
	[ "$status" -eq 0 ]
	[ "$output" = "$(cat "$GOLDEN/default.conf")" ]
}

@test "F18: other bytes are not tolerated" {
	printf '173.245.48.0/20\n\x01103.21.244.0/22' >"$BATS_TEST_TMPDIR/ctl.txt"
	serve_v4 "$BATS_TEST_TMPDIR/ctl.txt"
	run cfrn --dry-run
	[ "$status" -eq 3 ]
	[[ $output == *"not printable ASCII"* ]]
}
