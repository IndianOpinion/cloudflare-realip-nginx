#!/usr/bin/env bats
# 4.2 fetch cases F1 to F16 (F13 and F14 are in config.bats, F17 and F18 in
# parse.bats).

load helpers/common

setup() { common_setup; }

@test "F1: normal lists render the expected snippet" {
	run cfrn
	[ "$status" -eq 0 ]
	cmp "$OUT" "$GOLDEN/default.conf"
	[[ $output == *"updated: 15 IPv4, 7 IPv6 (+22 -0), nginx reloaded"* ]]
}

@test "F2: connect timeout is retried 3 times then exit 2, untouched" {
	install_good_snippet
	before=$(fingerprint)
	reset_url "$V4_URL"
	serve "$V4_URL" 000 - - 7
	run cfrn
	[ "$status" -eq 2 ]
	[ "$(calls "^curl $V4_URL")" -eq 3 ]
	[[ $output == *"after 3 attempts"* ]]
	assert_untouched "$before"
}

@test "F3: total timeout is retried then exit 2, untouched" {
	install_good_snippet
	before=$(fingerprint)
	reset_url "$V6_URL"
	serve "$V6_URL" 000 - - 28
	run cfrn
	[ "$status" -eq 2 ]
	[ "$(calls "^curl $V6_URL")" -eq 3 ]
	assert_untouched "$before"
}

@test "F2/F3: a retry that succeeds carries on" {
	reset_url "$V4_URL"
	serve "$V4_URL" 000 - - 28
	serve "$V4_URL" 200 text/plain v4-ok.txt 0
	run cfrn
	[ "$status" -eq 0 ]
	[ "$(calls "^curl $V4_URL")" -eq 2 ]
	[[ $output == *"attempt 1 failed"* ]]
}

@test "F4: DNS failure exit 2, untouched" {
	install_good_snippet
	before=$(fingerprint)
	reset_url "$V4_URL"
	serve "$V4_URL" 000 - - 6
	run cfrn
	[ "$status" -eq 2 ]
	[[ $output == *"curl exit 6"* ]]
	assert_untouched "$before"
}

@test "F5: TLS failure is not retried, exit 2, untouched" {
	install_good_snippet
	before=$(fingerprint)
	reset_url "$V4_URL"
	serve "$V4_URL" 000 - - 60
	run cfrn
	[ "$status" -eq 2 ]
	[ "$(calls "^curl $V4_URL")" -eq 1 ]
	assert_untouched "$before"
	run grep -c -- '--insecure\|-k ' "$TOOL"
	[ "$output" = "0" ]
}

@test "F6: 404 is not retried" {
	reset_url "$V4_URL"
	serve "$V4_URL" 404 text/html - 0
	run cfrn
	[ "$status" -eq 2 ]
	[ "$(calls "^curl $V4_URL")" -eq 1 ]
	[[ $output == *"HTTP 404"* ]]
	[[ $output == *"$V4_URL"* ]]
}

@test "F6: 429 and 503 are retried, then exit 2, untouched" {
	install_good_snippet
	before=$(fingerprint)
	reset_url "$V4_URL"
	serve "$V4_URL" 429 text/html - 0
	serve "$V4_URL" 503 text/html - 0
	run cfrn
	[ "$status" -eq 2 ]
	[ "$(calls "^curl $V4_URL")" -eq 3 ]
	[[ $output == *"HTTP 503"* ]]
	assert_untouched "$before"
}

@test "F7: a curl partial-transfer error is retried then exit 2" {
	reset_url "$V4_URL"
	serve "$V4_URL" 000 - - 18
	run cfrn
	[ "$status" -eq 2 ]
	[ "$(calls "^curl $V4_URL")" -eq 3 ]
}

@test "F7: a body cut mid-line fails validation, exit 3" {
	serve_v4 v4-truncated-mid-line.txt
	run cfrn
	[ "$status" -eq 3 ]
	[ ! -e "$OUT" ]
}

@test "F7: a body cut between lines fails the count check, exit 3" {
	serve_v4 v4-truncated-between-lines.txt
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"6 ranges, expected 10 to 200"* ]]
}

@test "F8: an empty body exits 3" {
	install_good_snippet
	before=$(fingerprint)
	serve_v4 empty.txt
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"empty list"* ]]
	assert_untouched "$before"
}

@test "F8: a whitespace-only body exits 3" {
	serve_v6 whitespace.txt
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"empty list"* ]]
}

@test "F9: an oversize body is aborted, exit 3" {
	serve_v4 oversize.txt
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"larger than 65536 bytes"* ]]
	grep -q -- '--max-filesize' "$TOOL"
}

@test "F9: the size is checked again after the transfer" {
	export CURL_IGNORE_MAXSIZE=1
	serve_v4 oversize.txt
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"larger than 65536 bytes"* ]]
}

@test "F10: an HTML page with status 200 exits 3 and the body is not logged" {
	reset_url "$V4_URL"
	serve "$V4_URL" 200 "text/html;charset=UTF-8" html-challenge.html 0
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"content type 'text/html'"* ]]
	[[ $output != *"Just a moment"* ]]
	! grep -q "Just a moment" "$CALLS"
}

@test "F10: a JSON content type exits 3" {
	reset_url "$V6_URL"
	serve "$V6_URL" 200 application/json json.txt 0
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"application/json"* ]]
}

@test "F10: a missing content type exits 3" {
	reset_url "$V4_URL"
	serve "$V4_URL" 200 - v4-ok.txt 0
	run cfrn
	[ "$status" -eq 3 ]
}

@test "F11: JSON served as text/plain exits 3" {
	serve_v4 json.txt
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"line 1"* ]]
}

@test "F11: CSV served as text/plain exits 3" {
	serve_v4 csv.txt
	run cfrn
	[ "$status" -eq 3 ]
	[[ $output == *"line 1"* ]]
}

@test "F12: a redirect to plain HTTP is refused" {
	reset_url "$V4_URL"
	serve "$V4_URL" 301 text/html - 0 "http://www.cloudflare.com/ips-v4"
	run cfrn
	[ "$status" -eq 2 ]
	[[ $output == *"non-HTTPS"* ]]
	[ "$(calls '^curl http://')" -eq 0 ]
}

@test "F12: a redirect to another host is refused while pinned" {
	reset_url "$V4_URL"
	serve "$V4_URL" 302 text/html - 0 "https://evil.example/ips-v4"
	run cfrn
	[ "$status" -eq 2 ]
	[[ $output == *"evil.example"* ]]
	[ "$(calls '^curl https://evil')" -eq 0 ]
}

@test "F12: an HTTPS redirect on the pinned host is followed" {
	reset_url "$V4_URL"
	serve "$V4_URL" 301 text/html - 0 "https://www.cloudflare.com/ips-v4/"
	serve "https://www.cloudflare.com/ips-v4/" 200 text/plain v4-ok.txt 0
	run cfrn
	[ "$status" -eq 0 ]
}

@test "F12: more than 3 redirects are refused" {
	reset_url "$V4_URL"
	serve "$V4_URL" 301 text/html - 0 "https://www.cloudflare.com/a"
	serve "https://www.cloudflare.com/a" 301 text/html - 0 "https://www.cloudflare.com/b"
	serve "https://www.cloudflare.com/b" 301 text/html - 0 "https://www.cloudflare.com/c"
	serve "https://www.cloudflare.com/c" 301 text/html - 0 "https://www.cloudflare.com/d"
	run cfrn
	[ "$status" -eq 2 ]
	[[ $output == *"more than 3 redirects"* ]]
}

@test "F15: proxy variables reach curl" {
	export https_proxy=http://proxy.example:3128 no_proxy=localhost
	run cfrn --dry-run
	[ "$status" -eq 0 ]
	grep -q 'curl-env https_proxy=http://proxy.example:3128 no_proxy=localhost' "$CALLS"
}

@test "F16: IPv4 good and IPv6 failing writes nothing" {
	install_good_snippet
	before=$(fingerprint)
	serve_v4 v4-plus-one.txt
	serve_v6 v6-ula.txt
	run cfrn
	[ "$status" -eq 3 ]
	assert_untouched "$before"
	no_temp_left
}

@test "F16: IPv6 good and IPv4 failing writes nothing" {
	install_good_snippet
	before=$(fingerprint)
	reset_url "$V4_URL"
	serve "$V4_URL" 403 text/html - 0
	run cfrn
	[ "$status" -eq 2 ]
	assert_untouched "$before"
}
