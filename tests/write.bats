#!/usr/bin/env bats
# 4.5 write, test and reload cases W1 to W14.

load helpers/common

setup() { common_setup; }

@test "W1: an unchanged run does no write, no backup and no reload" {
	install_good_snippet
	inode=$(stat -c '%i %Y' "$OUT")
	sed -i 's/^last_success=.*/last_success=1000/' "$STATE/state"
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output == *"unchanged: 15 IPv4, 7 IPv6"* ]]
	[ "$(stat -c '%i %Y' "$OUT")" = "$inode" ]
	[ ! -e "$STATE/previous.conf" ]
	[ "$(calls '^nginx -t')" -eq 0 ]
	[ "$(calls 'reload')" -eq 0 ]
	grep -q '^last_result=unchanged$' "$STATE/state"
	! grep -q '^last_success=1000$' "$STATE/state"
}

@test "W2: a changed run writes, backs up, tests and reloads once" {
	install_good_snippet
	cp "$OUT" "$BATS_TEST_TMPDIR/old.conf"
	serve_v4 v4-plus-one.txt
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output == *"updated: 16 IPv4, 7 IPv6 (+1 -0), nginx reloaded"* ]]
	cmp "$STATE/previous.conf" "$BATS_TEST_TMPDIR/old.conf"
	grep -q 'set_real_ip_from 45.85.118.0/23;' "$OUT"
	[ "$(calls '^nginx -t -q')" -eq 1 ]
	[ "$(calls '^nginx -t$')" -eq 1 ]
	[ "$(calls '^systemctl reload nginx')" -eq 1 ]
	grep -q '^last_result=updated$' "$STATE/state"
	grep -q '^pending_reload=0$' "$STATE/state"
	no_temp_left
}

@test "W3: a candidate test failure deletes the temp file, exit 4, untouched" {
	install_good_snippet
	before=$(fingerprint)
	serve_v4 v4-plus-one.txt
	export NGINX_CANDIDATE_RC=1
	export NGINX_CANDIDATE_MSG='nginx: [emerg] unknown directive "set_real_ip_from" in /x:9'
	run cfrn
	[ "$status" -eq 4 ]
	[[ $output == *"without ngx_http_realip_module"* ]]
	[[ $output == *'unknown directive'* ]]
	assert_untouched "$before"
	no_temp_left
}

@test "W4: a full test failure restores the backup, no reload, exit 4" {
	install_good_snippet
	before=$(fingerprint)
	cp "$OUT" "$BATS_TEST_TMPDIR/old.conf"
	serve_v4 v4-plus-one.txt
	export NGINX_FULL_RC="1 0"
	export NGINX_FULL_MSG='nginx: [emerg] "real_ip_header" directive is duplicate in /etc/nginx/conf.d/x.conf:40'
	run cfrn
	[ "$status" -eq 4 ]
	[[ $output == *"previous state restored"* ]]
	[[ $output == *"is duplicate"* ]]
	cmp "$OUT" "$BATS_TEST_TMPDIR/old.conf"
	[ "$(calls 'reload')" -eq 0 ]
	[ "$(calls '^nginx -t$')" -eq 2 ]
	grep -q '^in_progress=0$' "$STATE/state"
	no_temp_left
}

@test "W4: a configuration broken before the run is reported plainly" {
	install_good_snippet
	cp "$OUT" "$BATS_TEST_TMPDIR/old.conf"
	serve_v4 v4-plus-one.txt
	export NGINX_FULL_RC="1 1"
	run cfrn
	[ "$status" -eq 4 ]
	[[ $output == *"already broken before this run"* ]]
	cmp "$OUT" "$BATS_TEST_TMPDIR/old.conf"
}

@test "W5: a reload failure exits 5, keeps the file, and the next run retries" {
	install_good_snippet
	serve_v4 v4-plus-one.txt
	export SYSTEMCTL_RELOAD_RC="1 0"
	run cfrn
	[ "$status" -eq 5 ]
	[[ $output == *"reload failed"* ]]
	grep -q 'set_real_ip_from 45.85.118.0/23;' "$OUT"
	grep -q '^pending_reload=1$' "$STATE/state"
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output == *"unchanged"*"pending reload done"* ]]
	[ "$(calls '^systemctl reload nginx')" -eq 2 ]
	grep -q '^pending_reload=0$' "$STATE/state"
}

@test "W6: nginx stopped: the file is written, no reload, exit 0" {
	export SYSTEMCTL_ACTIVE_RC=3
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output == *"nginx is not running, reload skipped"* ]]
	[ -f "$OUT" ]
	[ "$(calls '^systemctl reload')" -eq 0 ]
}

@test "W6: without systemd the pid file decides" {
	setting CFRN_SERVICE_MANAGER none
	setting CFRN_PID_FILE "$BATS_TEST_TMPDIR/nginx.pid"
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output == *"not running"* ]]
	[ "$(calls '^nginx -s reload')" -eq 0 ]
	serve_v4 v4-plus-one.txt
	echo $$ >"$BATS_TEST_TMPDIR/nginx.pid"
	run cfrn
	[ "$status" -eq 0 ]
	[ "$(calls '^nginx -s reload')" -eq 1 ]
}

@test "W7: an unwritable temp file exits 1, untouched" {
	install_good_snippet
	before=$(fingerprint)
	serve_v4 v4-plus-one.txt
	export MKTEMP_FAIL_MATCH=.cloudflare-realip.
	run cfrn
	[ "$status" -eq 1 ]
	[[ $output == *"cannot create a temporary file"* ]]
	assert_untouched "$before"
	no_temp_left
}

@test "W8: the temp file is dot-named, outside the include directory, and removed on TERM" {
	export NGINX_CANDIDATE_SLEEP=3
	"$TOOL" --config "$CONF" >"$BATS_TEST_TMPDIR/out" 2>&1 &
	pid=$!
	for _ in $(seq 1 50); do
		[ -e "$SHIM_DIR/candidate-started" ] && break
		sleep 0.1
	done
	[ -e "$SHIM_DIR/candidate-started" ]
	run find "$ROOT/etc/nginx" -type f
	[ "${#lines[@]}" -eq 1 ]
	tmp=${lines[0]}
	[ "$(dirname "$tmp")" = "$STAGING" ]
	[[ $(basename "$tmp") == .cloudflare-realip.* ]]
	[[ $tmp != *.conf ]]
	[ "$(stat -c %d "$STAGING")" = "$(stat -c %d "$ROOT/etc/nginx/conf.d")" ]
	kill -TERM "$pid"
	st=0
	wait "$pid" || st=$?
	[ "$st" -eq 143 ]
	grep -q 'interrupted by SIGTERM' "$BATS_TEST_TMPDIR/out"
	[ ! -e "$tmp" ]
	[ ! -e "$OUT" ]
	no_temp_left
}

@test "W9: the snippet is written mode 0644, never looser" {
	umask 077
	run cfrn
	[ "$status" -eq 0 ]
	[ "$(stat -c %a "$OUT")" = "644" ]
	chmod 0666 "$OUT"
	serve_v4 v4-plus-one.txt
	run cfrn
	[ "$status" -eq 0 ]
	[ "$(stat -c %a "$OUT")" = "644" ]
}

@test "W10: a symlink target exits 1" {
	echo "# elsewhere" >"$BATS_TEST_TMPDIR/real.conf"
	ln -s "$BATS_TEST_TMPDIR/real.conf" "$OUT"
	run cfrn
	[ "$status" -eq 1 ]
	[[ $output == *"is a symlink"* ]]
	[ -L "$OUT" ]
	[ "$(cat "$BATS_TEST_TMPDIR/real.conf")" = "# elsewhere" ]
}

@test "W11: a hand-written snippet is refused" {
	cp "$FIXTURES/hand-written-snippet.conf" "$OUT"
	before=$(fingerprint)
	run cfrn
	[ "$status" -eq 1 ]
	[[ $output == *"not written by this tool"* ]]
	assert_untouched "$before"
	[ "$(calls '^curl ')" -eq 0 ]
}

@test "W11: a hand-written snippet is replaced with --force and kept as the backup" {
	cp "$FIXTURES/hand-written-snippet.conf" "$OUT"
	run cfrn --force
	[ "$status" -eq 0 ]
	cmp "$STATE/previous.conf" "$FIXTURES/hand-written-snippet.conf"
	cmp "$OUT" "$GOLDEN/default.conf"
}

@test "W12: a second run while one holds the lock exits 6, untouched" {
	install_good_snippet
	serve_v4 v4-plus-one.txt
	before=$(fingerprint)
	exec 9>>"$STATE/lock"
	flock -n 9
	run cfrn
	exec 9>&-
	[ "$status" -eq 6 ]
	[[ $output == *"another run is in progress"* ]]
	assert_untouched "$before"
	[ "$(calls '^curl ')" -eq 0 ]
	run cfrn
	[ "$status" -eq 0 ]
}

@test "W13: a warning when nginx -T does not mention the path" {
	export NGINX_DUMP="# configuration file /etc/nginx/nginx.conf:"
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output == *"is not included anywhere"* ]]
	[[ $output == *"include $OUT;"* ]]
}

@test "W14: leftover in-progress state triggers a test and a restore" {
	install_good_snippet
	cp "$OUT" "$STATE/previous.conf"
	printf '%s\nset_real_ip_from broken\n' "$(head -n 1 "$OUT")" >"$OUT"
	printf 'in_progress=1\nin_progress_had_backup=1\n' >"$STATE/state"
	export NGINX_FULL_RC="1 0"
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output == *"interrupted"* ]]
	[[ $output == *"restoring the backup"* ]]
	cmp "$OUT" "$GOLDEN/default.conf"
	grep -q '^in_progress=0$' "$STATE/state"
}

@test "W14: an interrupted snippet that passes is kept and reloaded" {
	install_good_snippet
	printf 'in_progress=1\nin_progress_had_backup=0\n' >"$STATE/state"
	run cfrn
	[ "$status" -eq 0 ]
	[[ $output == *"passes nginx -t; keeping it"* ]]
	[ "$(calls '^systemctl reload nginx')" -eq 1 ]
}
