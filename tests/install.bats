#!/usr/bin/env bats
# 4.11 install and uninstall, I1 to I5, in a staged root (--destdir).

load helpers/common

setup() {
	common_setup
	DEST="$BATS_TEST_TMPDIR/dest"
	mkdir -p "$DEST/etc/nginx/conf.d" "$DEST/etc/cron.d" "$DEST/etc/default" "$BATS_TEST_TMPDIR/systemd-run"
	export CFRN_SYSTEMD_RUN_DIR="$BATS_TEST_TMPDIR/systemd-run"
	export CFRN_INSTALL_RUN_SERVICE_COMMANDS=1
	DTOOL="$DEST/usr/local/sbin/cloudflare-realip-nginx"
	DCONF="$DEST/etc/default/cloudflare-realip-nginx"
	DSTATE="$DEST/var/lib/cloudflare-realip-nginx"
	DOUT="$DEST/etc/nginx/conf.d/cloudflare-realip.conf"
	UNITS="$DEST/etc/systemd/system"
}

inst() {
	"$REPO_ROOT/install.sh" --destdir "$DEST" "$@"
}

@test "I1: a fresh install puts every file in place, runs the dry run, then enables the timer" {
	run inst
	echo "$output"
	[ "$status" -eq 0 ]
	[ -x "$DTOOL" ]
	cmp "$DCONF" "$REPO_ROOT/etc/default/cloudflare-realip-nginx"
	[ -f "$UNITS/cloudflare-realip-nginx.timer" ]
	grep -q '^ExecStart=/usr/local/sbin/cloudflare-realip-nginx$' "$UNITS/cloudflare-realip-nginx.service"
	grep -q '^ReadWritePaths=/etc/nginx/conf.d /etc/nginx/.cloudflare-realip-nginx /var/lib/cloudflare-realip-nginx$' "$UNITS/cloudflare-realip-nginx.service"
	[ "$(stat -c %a "$DSTATE")" = "750" ]
	[ -d "$DEST/etc/nginx/.cloudflare-realip-nginx" ]
	[ "$(calls '^nginx -t -q')" -eq 1 ]
	[ "$(calls '^curl ')" -eq 2 ]
	grep -n 'nginx -t -q\|systemctl enable --now cloudflare-realip-nginx.timer' "$CALLS" >"$BATS_TEST_TMPDIR/order"
	[ "$(wc -l <"$BATS_TEST_TMPDIR/order")" -eq 2 ]
	[[ $(tail -n 1 "$BATS_TEST_TMPDIR/order") == *"enable --now"* ]]
	[ ! -e "$DOUT" ]
}

@test "I1: an existing config is kept and the new default goes to .new" {
	printf 'CFRN_HEADER=X-Mine\n' >"$DCONF"
	run inst
	[ "$status" -eq 0 ]
	[ "$(cat "$DCONF")" = "CFRN_HEADER=X-Mine" ]
	cmp "$DCONF.new" "$REPO_ROOT/etc/default/cloudflare-realip-nginx"
	[[ $output == *"wrote the new default to $DCONF.new"* ]]
}

@test "I1: a failing dry run stops the install before the timer is enabled" {
	serve_v4 v4-private.txt
	run inst
	[ "$status" -eq 1 ]
	[[ $output == *"timer was not enabled"* ]]
	[ "$(calls 'systemctl enable')" -eq 0 ]
}

@test "I1: --no-timer installs the units without enabling them" {
	run inst --no-timer
	[ "$status" -eq 0 ]
	[ -f "$UNITS/cloudflare-realip-nginx.timer" ]
	[ "$(calls 'systemctl enable')" -eq 0 ]
}

@test "I1: --prefix changes the tool path and the unit's ExecStart" {
	run inst --prefix /opt/cfrn
	[ "$status" -eq 0 ]
	[ -x "$DEST/opt/cfrn/sbin/cloudflare-realip-nginx" ]
	grep -q '^ExecStart=/opt/cfrn/sbin/cloudflare-realip-nginx$' "$UNITS/cloudflare-realip-nginx.service"
}

@test "I2: without systemd the cron file is installed and the installer says so" {
	export CFRN_SYSTEMD_RUN_DIR="$BATS_TEST_TMPDIR/no-such-dir"
	run inst
	[ "$status" -eq 0 ]
	[[ $output == *"systemd not found"* ]]
	[ -f "$DEST/etc/cron.d/cloudflare-realip-nginx" ]
	grep -Eq '^[0-9]{1,2} [0-9]{1,2} \* \* \* root /usr/local/sbin/cloudflare-realip-nginx --quiet$' "$DEST/etc/cron.d/cloudflare-realip-nginx"
	[ ! -e "$UNITS/cloudflare-realip-nginx.timer" ]
}

@test "I2: --cron installs the cron file on a systemd host" {
	run inst --cron
	[ "$status" -eq 0 ]
	[ -f "$DEST/etc/cron.d/cloudflare-realip-nginx" ]
	[ ! -e "$UNITS/cloudflare-realip-nginx.timer" ]
}

@test "I2: busybox crond gets a periodic/daily script" {
	export CFRN_SYSTEMD_RUN_DIR="$BATS_TEST_TMPDIR/no-such-dir"
	rmdir "$DEST/etc/cron.d"
	mkdir -p "$DEST/etc/periodic/daily"
	run inst
	[ "$status" -eq 0 ]
	[ -x "$DEST/etc/periodic/daily/cloudflare-realip-nginx" ]
}

@test "I3: a second install changes nothing and says so" {
	run inst
	[ "$status" -eq 0 ]
	export CFRN_SYSTEMD_RUN_DIR="$BATS_TEST_TMPDIR/systemd-run"
	before=$(find "$DEST" -type f -exec sha256sum {} + | sort)
	: >"$CALLS"
	export SYSTEMCTL_ENABLED_RC=0
	run inst
	[ "$status" -eq 0 ]
	[[ $output == *"nothing to do: already installed"* ]]
	[ "$(find "$DEST" -type f -exec sha256sum {} + | sort)" = "$before" ]
	[ "$(calls '^curl ')" -eq 0 ]
	[ "$(calls 'systemctl enable')" -eq 0 ]
}

@test "I3: a second cron install keeps the random time" {
	run inst --cron
	first=$(cat "$DEST/etc/cron.d/cloudflare-realip-nginx")
	run inst --cron
	[ "$status" -eq 0 ]
	[ "$(cat "$DEST/etc/cron.d/cloudflare-realip-nginx")" = "$first" ]
}

@test "I4: uninstall leaves the snippet, backup and config, and removes the rest" {
	run inst
	echo snippet >"$DOUT"
	echo backup >"$DSTATE/previous.conf"
	: >"$DSTATE/lock"
	run inst --uninstall
	[ "$status" -eq 0 ]
	[ ! -e "$DTOOL" ]
	[ ! -e "$UNITS/cloudflare-realip-nginx.service" ]
	[ ! -e "$UNITS/cloudflare-realip-nginx.timer" ]
	[ ! -e "$DSTATE/lock" ]
	[ -f "$DOUT" ]
	[ -f "$DSTATE/previous.conf" ]
	[ -f "$DCONF" ]
	[[ $output == *"kept: $DOUT"* ]]
	[[ $output == *"changes every logged client address"* ]]
	[ "$(calls 'systemctl disable --now cloudflare-realip-nginx.timer')" -eq 1 ]
	[ "$(calls 'systemctl reload\|-s reload')" -eq 0 ]
}

@test "I4: uninstall removes the cron file" {
	run inst --cron
	run inst --uninstall
	[ "$status" -eq 0 ]
	[ ! -e "$DEST/etc/cron.d/cloudflare-realip-nginx" ]
}

@test "I5: purge removes the snippet, state and config, then reloads" {
	run inst
	echo snippet >"$DOUT"
	echo backup >"$DSTATE/previous.conf"
	run inst --uninstall --purge
	[ "$status" -eq 0 ]
	[ ! -e "$DOUT" ]
	[ ! -e "$DSTATE" ]
	[ ! -e "$DCONF" ]
	[ "$(calls '^nginx -t$')" -eq 1 ]
	[ "$(calls '^systemctl reload nginx')" -eq 1 ]
}

@test "I5: purge puts the snippet back when nginx -t fails" {
	run inst
	echo snippet >"$DOUT"
	export NGINX_FULL_RC=1
	run inst --uninstall --purge
	[ "$status" -eq 1 ]
	[[ $output == *"remove that include first"* ]]
	[ "$(cat "$DOUT")" = "snippet" ]
	[ -d "$DSTATE" ]
	[ -f "$DCONF" ]
	[ "$(calls 'systemctl reload\|-s reload')" -eq 0 ]
}

@test "install: --purge without --uninstall is refused" {
	run inst --purge
	[ "$status" -eq 1 ]
}
