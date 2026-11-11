#!/usr/bin/env bats
# 4.6 first run cases FR1 to FR4.

load helpers/common

setup() { common_setup; }

@test "FR1: no snippet, no backup, no state: the write succeeds" {
	[ ! -e "$STATE/state" ]
	run cfrn
	[ "$status" -eq 0 ]
	[ -f "$OUT" ]
	[ ! -e "$STATE/previous.conf" ]
	[[ $output != *"drop"* ]]
}

@test "FR1: a full test failure on a first run leaves no file" {
	export NGINX_FULL_RC="1 0"
	run cfrn
	[ "$status" -eq 4 ]
	[ ! -e "$OUT" ]
	[ ! -e "$STATE/previous.conf" ]
	[ -z "$(ls -A "$ROOT/etc/nginx/conf.d")" ]
}

@test "FR2: diff on a first run shows the whole file added, exit 10" {
	run --separate-stderr cfrn --diff
	[ "$status" -eq 10 ]
	[ "$(grep -c '^+set_real_ip_from' <<<"$output")" -eq 22 ]
	[ "$(grep -c '^-[^-]' <<<"$output" || true)" -eq 0 ]
	[ ! -e "$OUT" ]
}

@test "FR3: a missing target directory exits 1 with its name" {
	rm -r "$ROOT/etc/nginx/conf.d"
	run cfrn
	[ "$status" -eq 1 ]
	[[ $output == *"$ROOT/etc/nginx/conf.d does not exist"* ]]
	[ ! -e "$ROOT/etc/nginx/conf.d" ]
}

@test "FR4: a missing state directory is created as root, mode 0750" {
	rm -r "$STATE"
	run cfrn
	[ "$status" -eq 0 ]
	[ "$(stat -c %a "$STATE")" = "750" ]
}

@test "FR4: a missing state directory is exit 1 as non-root" {
	rm -r "$STATE"
	export FAKE_UID=1000
	run cfrn
	[ "$status" -eq 1 ]
	[[ $output == *"state directory $STATE does not exist"* ]]
	[ ! -e "$STATE" ]
}
