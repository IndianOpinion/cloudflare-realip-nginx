#!/usr/bin/env bats
# Configuration: F13, F14, R4 and the parser rules in section 7.

load helpers/common

setup() { common_setup; }

@test "F13: an http URL is exit 1 with no curl call" {
	setting CFRN_URL_V4 http://www.cloudflare.com/ips-v4
	run cfrn
	[ "$status" -eq 1 ]
	[[ $output == *"must be an https:// URL"* ]]
	[ "$(calls '^curl ')" -eq 0 ]
}

@test "F14: an off-host URL is exit 1 while pinned" {
	setting CFRN_URL_V6 https://mirror.example/ips-v6
	run cfrn
	[ "$status" -eq 1 ]
	[[ $output == *"only www.cloudflare.com is allowed"* ]]
	[ "$(calls '^curl ')" -eq 0 ]
}

@test "F14: an off-host URL is allowed with pinning off, with a warning on every run" {
	setting CFRN_URL_V6 https://mirror.example/ips-v6
	setting CFRN_PIN_HOST no
	serve https://mirror.example/ips-v6 200 text/plain v6-ok.txt 0
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output == *"warning: host pinning is off"* ]]
	run cfrn
	[[ $output == *"warning: host pinning is off"* ]]
}

@test "R4: a header with a space or a semicolon is exit 1" {
	run cfrn --header 'X-Real IP'
	[ "$status" -eq 1 ]
	run cfrn --header 'X-Real-IP;'
	[ "$status" -eq 1 ]
	[[ $output == *"letters, digits and hyphens"* ]]
	[ "$(calls '^curl ')" -eq 0 ]
}

@test "R4: True-Client-IP is accepted" {
	run cfrn --dry-run --header True-Client-IP
	[ "$status" -eq 0 ]
	[[ $output == *"real_ip_header True-Client-IP;"* ]]
}

@test "config: unknown keys are an error" {
	setting CFRN_OUTPT /etc/nginx/x.conf
	run cfrn
	[ "$status" -eq 1 ]
	[[ $output == *"unknown setting CFRN_OUTPT"* ]]
}

@test "config: the file is parsed, never executed" {
	printf 'CFRN_HEADER=$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR" >>"$CONF"
	run cfrn --dry-run
	[ "$status" -eq 1 ]
	[ ! -e "$BATS_TEST_TMPDIR/pwned" ]
	printf 'CFRN_SYSLOG_TAG="`touch %s/pwned`"\n' "$BATS_TEST_TMPDIR" >"$CONF"
	run cfrn --dry-run
	[ "$status" -eq 1 ]
	[ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "config: quoted values are accepted" {
	printf 'CFRN_EXTRA_TRUSTED="10.0.0.1/32 10.0.0.2/32"\n' >>"$CONF"
	run cfrn --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"set_real_ip_from 10.0.0.2/32;"* ]]
}

@test "config: environment overrides the file and flags override the environment" {
	setting CFRN_HEADER X-From-File
	CFRN_HEADER=X-From-Env run cfrn --dry-run
	[[ $output == *"real_ip_header X-From-Env;"* ]]
	CFRN_HEADER=X-From-Env run cfrn --dry-run --header X-From-Flag
	[[ $output == *"real_ip_header X-From-Flag;"* ]]
}

@test "config: a relative or unsafe output path is exit 1" {
	run cfrn --output etc/nginx/x.conf
	[ "$status" -eq 1 ]
	run cfrn --output '/etc/nginx/x y.conf'
	[ "$status" -eq 1 ]
	run cfrn --output '/etc/nginx/../x.conf'
	[ "$status" -eq 1 ]
}

@test "config: a missing explicit config file is exit 1" {
	run "$TOOL" --config "$BATS_TEST_TMPDIR/nope"
	[ "$status" -eq 1 ]
}

@test "config: unsafe command words are exit 1" {
	setting CFRN_RELOAD_COMMAND '"systemctl reload nginx;reboot"'
	run cfrn
	[ "$status" -eq 1 ]
	[[ $output == *"unsafe word"* ]]
}

@test "usage: two modes at once is exit 1, --test needs --dry-run" {
	run cfrn --dry-run --diff
	[ "$status" -eq 1 ]
	run cfrn --test
	[ "$status" -eq 1 ]
	run cfrn --bogus
	[ "$status" -eq 1 ]
}

@test "usage: --help and --version" {
	run "$TOOL" --help
	[ "$status" -eq 0 ]
	[[ $output == *"Usage: cloudflare-realip-nginx"* ]]
	run "$TOOL" --version
	[ "$output" = "cloudflare-realip-nginx 0.1.0" ]
}
