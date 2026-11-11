#!/usr/bin/env bats
# 4.3 validation cases V1 to V8, V10 and V11.

load helpers/common

setup() { common_setup; }

# list_with FAMILY ENTRY: the real list plus one entry, served for FAMILY.
list_with() {
	local f="$BATS_TEST_TMPDIR/list-$1.txt"
	{ cat "$FIXTURES/v$1-ok.txt"; printf '\n%s' "$2"; } >"$f"
	if [[ $1 == 4 ]]; then serve_v4 "$f"; else serve_v6 "$f"; fi
}

@test "V1: an IPv6 entry in the IPv4 list exits 3" {
	serve_v4 v4-with-v6.txt
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"IPv6 entry in the IPv4 list"* ]]
	[[ $output == *"line 16"* ]]
}

@test "V1: an IPv4 entry in the IPv6 list exits 3" {
	list_with 6 "104.16.0.0/13"
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"IPv4 entry in the IPv6 list"* ]]
}

@test "V2: a bad octet exits 3" {
	serve_v4 v4-bad-octet.txt
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"octet above 255"* ]]
}

@test "V2: a leading zero exits 3" {
	serve_v4 v4-leading-zero.txt
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"leading zero"* ]]
}

@test "V2: a bare address without a prefix exits 3" {
	serve_v4 v4-no-prefix.txt
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"no prefix length"* ]]
}

@test "V2: bad IPv6 forms exit 3" {
	local bad
	for bad in '2400:cb00:::/32' '2400::cb00::/32' '[2400:cb00::]/32' '2400:cb00::%eth0/32' \
		'::ffff:192.0.2.1/128' '2400:cb00:1:2:3:4:5:6:7/128' '2400:cb00::/129' '2400:cb00/32' \
		'g400:cb00::/32' '12345::/32' '2400:cb00::' ':2400::/32' '2400::1:/128' '2400:cb00::/032'; do
		list_with 6 "$bad"
		run cfrn --dry-run
		echo "entry $bad: status $status, $output"
		[ "$status" -eq 3 ]
	done
}

@test "V2: IPv4 prefix above 32 exits 3" {
	list_with 4 "104.16.0.0/33"
	run cfrn --dry-run
	[ "$status" -eq 3 ]
}

@test "V3: /7 IPv4 exits 3 and /8 passes" {
	serve_v4 v4-slash7.txt
	run cfrn --dry-run
	[ "$status" -eq 3 ]
	[[ $output == *"wider than the floor /8"* ]]
	serve_v4 v4-slash8-floor.txt
	run cfrn --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"set_real_ip_from 104.0.0.0/8;"* ]]
}

@test "V3: /15 IPv6 exits 3 and /16 passes" {
	serve_v6 v6-slash15.txt
	run cfrn --dry-run
	[ "$status" -eq 3 ]
	[[ $output == *"wider than the floor /16"* ]]
	serve_v6 v6-slash16-floor.txt
	run cfrn --dry-run
	[ "$status" -eq 0 ]
}

@test "V4: the default route exits 3" {
	serve_v4 v4-default-route.txt
	run cfrn --dry-run
	[ "$status" -eq 3 ]
	[[ $output == *"default route"* ]]
	list_with 6 "::/0"
	run cfrn --dry-run
	[ "$status" -eq 3 ]
}

@test "V4: private space exits 3" {
	serve_v4 v4-private.txt
	run cfrn --dry-run
	[ "$status" -eq 3 ]
	[[ $output == *"private"* ]]
}

@test "V4: unique-local IPv6 exits 3" {
	serve_v6 v6-ula.txt
	run cfrn --dry-run
	[ "$status" -eq 3 ]
	[[ $output == *"unique-local"* ]]
}

@test "V4: loopback exits 3" {
	serve_v4 v4-loopback.txt
	run cfrn --dry-run
	[ "$status" -eq 3 ]
	[[ $output == *"loopback"* ]]
}

@test "V4: other never-trusted space exits 3" {
	local bad
	for bad in 169.254.0.0/16 100.64.0.0/10 224.0.0.0/8 198.51.100.0/24 203.0.113.0/24 100.0.0.0/8; do
		list_with 4 "$bad"
		run cfrn --dry-run
		echo "entry $bad: status $status"
		[ "$status" -eq 3 ]
	done
	for bad in ::1/128 fe80::/10 ff02::/16 2001:db8::/32 ::ffff:0:0/96 3fff::/20; do
		list_with 6 "$bad"
		run cfrn --dry-run
		echo "entry $bad: status $status"
		[ "$status" -eq 3 ]
	done
}

@test "V5: host bits set exits 3" {
	serve_v4 v4-host-bits.txt
	run cfrn --dry-run
	[ "$status" -eq 3 ]
	[[ $output == *"host bits set"* ]]
	list_with 6 "2400:cb00::1/32"
	run cfrn --dry-run
	[ "$status" -eq 3 ]
	[[ $output == *"host bits set"* ]]
}

@test "V6: mixed-case IPv6 renders the same as lower case" {
	run cfrn --dry-run
	expected=$output
	serve_v6 v6-mixed-case.txt
	run cfrn --dry-run
	[ "$status" -eq 0 ]
	[ "$output" = "$expected" ]
}

@test "V6: IPv6 is written in RFC 5952 form" {
	list_with 6 "2001:0DB9:0000:0000:0001:0000:0000:0000/96"
	run --separate-stderr cfrn --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"set_real_ip_from 2001:db9:0:0:1::/96;"* ]]
	list_with 6 "2001:db9:0:0:1:0:0:1/128"
	run cfrn --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"set_real_ip_from 2001:db9::1:0:0:1/128;"* ]]
}

@test "V7: duplicates are removed with a warning" {
	serve_v4 v4-dupes.txt
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output == *"warning:"*"duplicate range 104.16.0.0/13 removed"* ]]
	[ "$(grep -c 'set_real_ip_from 104.16.0.0/13;' "$OUT")" -eq 1 ]
	[[ $output == *"15 IPv4"* ]]
}

@test "V8: too few ranges exits 3" {
	serve_v4 v4-too-few.txt
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"9 ranges, expected 10 to 200"* ]]
}

@test "V8: too many ranges exits 3" {
	serve_v4 v4-too-many.txt
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"201 ranges, expected 10 to 200"* ]]
}

@test "V10: a half list is refused, exit 3, untouched" {
	setting CFRN_MIN_COUNT_V4 5
	install_good_snippet
	before=$(fingerprint)
	serve_v4 v4-half.txt
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"drop 8 of 15"* ]]
	assert_untouched "$before"
}

@test "V10: a half list is accepted with --force" {
	setting CFRN_MIN_COUNT_V4 5
	install_good_snippet
	serve_v4 v4-half.txt
	run cfrn --force
	[ "$status" -eq 0 ]
	[[ $output == *"allowed by --force"* ]]
	[[ $output == *"removed: 104.16.0.0/13"* ]]
	[ "$(grep -c '^set_real_ip_from [0-9.]*/' "$OUT")" -eq 7 ]
}

@test "V10: one more range is accepted and logged" {
	install_good_snippet
	serve_v4 v4-plus-one.txt
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output == *"added: 45.85.118.0/23"* ]]
	[[ $output == *"(+1 -0)"* ]]
	grep -q 'logger .*added: 45.85.118.0/23' "$CALLS"
}

@test "V11: a private extra address is accepted in its own block" {
	run cfrn --extra-trusted 10.0.0.5/32 --extra-trusted unix: --extra-trusted fd00::/8
	[ "$status" -eq 0 ]
	grep -q '^# Extra trusted addresses' "$OUT"
	[ "$(sed -n '/^# Extra trusted/,/^$/p' "$OUT" | grep -c set_real_ip_from)" -eq 3 ]
	grep -q 'set_real_ip_from unix:;' "$OUT"
	grep -q 'set_real_ip_from fd00::/8;' "$OUT"
}

@test "V11: extra addresses are still checked for syntax and host bits" {
	run cfrn --extra-trusted 10.0.0.5/24
	[ "$status" -eq 1 ]
	[[ $output == *"host bits"* ]]
	run cfrn --extra-trusted 10.0.0.5
	[ "$status" -eq 1 ]
	[[ $output == *"no prefix length"* ]]
	[ "$(calls '^curl ')" -eq 0 ]
}

@test "V11: a default route is refused as an extra address" {
	run cfrn --extra-trusted 0.0.0.0/0
	[ "$status" -eq 1 ]
	[[ $output == *"default route"* ]]
	run cfrn --extra-trusted ::/0
	[ "$status" -eq 1 ]
	[[ $output == *"default route"* ]]
	[ "$(calls '^curl ')" -eq 0 ]
}

@test "V11: duplicate extra addresses are removed with a warning" {
	run cfrn --dry-run --extra-trusted 10.0.0.5/32 --extra-trusted 10.0.0.5/32
	[ "$status" -eq 0 ]
	[[ $output == *"duplicate extra trusted address 10.0.0.5/32"* ]]
	[ "$(grep -c 'set_real_ip_from 10.0.0.5/32;' <<<"$output")" -eq 1 ]
}
