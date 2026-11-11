#!/usr/bin/env bats
# 4.7 permission cases P1 to P4 (P5 is in integration.bats).

load helpers/common

setup() { common_setup; }

@test "P1: a root run calls no helper" {
	run cfrn
	[ "$status" -eq 0 ]
	[ "$(calls '^sudo')" -eq 0 ]
}

@test "P2: a non-root run uses the helper for exactly the four commands" {
	export FAKE_UID=1000
	run cfrn
	[ "$status" -eq 0 ]
	[ -f "$OUT" ]
	[ "$(stat -c %a "$OUT")" = "644" ]
	run sh -c "grep '^sudo ' '$CALLS' | grep -v '^sudo -n -l ' | sort -u"
	[ "${#lines[@]}" -eq 4 ]
	[ "${lines[0]}" = "sudo -n install -m 0644 $STATE/staged.conf $OUT" ]
	[ "${lines[1]}" = "sudo -n nginx -T" ]
	[ "${lines[2]}" = "sudo -n nginx -t" ]
	[ "${lines[3]}" = "sudo -n systemctl reload nginx" ]
	[ "$(calls '^nginx -t -q')" -eq 1 ]
	[ "$(grep -c '^sudo -n nginx -t -q' "$CALLS" || true)" -eq 0 ]
	[ ! -e "$STATE/staged.conf" ]
}

@test "P2: a non-root first-run failure leaves a snippet that trusts nothing" {
	export FAKE_UID=1000 NGINX_FULL_RC="1 0"
	run cfrn
	[ "$status" -eq 4 ]
	[ "$(grep -c set_real_ip_from "$OUT" || true)" -eq 0 ]
	[ "$(grep -vc '^#' "$OUT" || true)" -eq 0 ]
}

@test "P3: non-root without a helper never runs the full test" {
	export FAKE_UID=1000
	setting CFRN_PRIV_HELPER none
	run cfrn
	[ "$status" -eq 1 ]
	[[ $output == *"without a privilege helper"* ]]
	[ "$(calls '^nginx -t$')" -eq 0 ]
	[ "$(calls '^curl ')" -eq 0 ]
}

@test "P4: sudo asking for a password fails preflight, exit 1, untouched" {
	install_good_snippet
	before=$(fingerprint)
	export FAKE_UID=1000 SUDO_LIST_RC=1
	run cfrn
	[ "$status" -eq 1 ]
	[[ $output == *"does not allow 'nginx -t' without a password"* ]]
	assert_untouched "$before"
	[ "$(calls '^curl ')" -eq 0 ]
}

@test "P4: the message names the missing right" {
	export FAKE_UID=1000 SUDO_DENY="systemctl reload"
	run cfrn
	[ "$status" -eq 1 ]
	[[ $output == *"'systemctl reload nginx'"* ]]
}
