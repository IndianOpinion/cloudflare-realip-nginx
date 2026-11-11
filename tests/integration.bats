#!/usr/bin/env bats
# Integration tests with a real nginx binary (R6, W8 glob behaviour, W2/W4
# end to end, P5). The curl, systemctl and logger stand-ins stay in place, so
# there is still no network access and no reload of a real nginx.
#
# Run with: CFRN_INTEGRATION=1 bats tests/integration.bats
# P5 also needs CFRN_INTEGRATION_SYSTEMD=1, root and a running systemd.

load helpers/common

setup() {
	if [[ ${CFRN_INTEGRATION:-0} != 1 ]]; then
		skip "set CFRN_INTEGRATION=1 to run tests against a real nginx"
	fi
	REAL_NGINX=$(command -v nginx || true)
	if [[ -z $REAL_NGINX ]]; then
		skip "nginx is not installed"
	fi
	common_setup
	# Every stand-in except nginx.
	local shims="$BATS_TEST_TMPDIR/shims" f
	mkdir -p "$shims"
	for f in "$BATS_TEST_DIRNAME"/helpers/shims/*; do
		[[ $(basename "$f") == nginx ]] || ln -s "$f" "$shims/"
	done
	export PATH="$shims:${PATH#"$BATS_TEST_DIRNAME/helpers/shims:"}"
	[ "$(command -v nginx)" = "$REAL_NGINX" ]
	NGX="$BATS_TEST_TMPDIR/ngx"
	mkdir -p "$NGX/logs" "$NGX/tmp"
}

# main_conf FILE BODY: a minimal nginx.conf around BODY, written to FILE.
main_conf() {
	local temp="" m
	for m in proxy fastcgi uwsgi scgi; do
		if ! nginx -V 2>&1 | grep -q -- "--without-http_${m}_module"; then
			temp+="    ${m}_temp_path $NGX/tmp/$m;"$'\n'
		fi
	done
	cat >"$1" <<CONF
pid $NGX/nginx.pid;
error_log $NGX/logs/error.log;
events { worker_connections 16; }
http {
    access_log off;
    client_body_temp_path $NGX/tmp/body;
$temp$2
}
CONF
}

ngx_test() { # conf
	nginx -t -q -p "$NGX/" -c "$1"
}

@test "integration: the candidate test passes with real nginx" {
	run cfrn --dry-run --test
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output == *"candidate test passed"* ]]
}

@test "R6: the snippet passes real nginx -t in the http context" {
	cp "$GOLDEN/default.conf" "$NGX/snippet.conf"
	main_conf "$NGX/http.conf" "    include $NGX/snippet.conf;"
	run ngx_test "$NGX/http.conf"
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "R6: the snippet passes real nginx -t in the server context" {
	cp "$GOLDEN/xff-recursive.conf" "$NGX/snippet.conf"
	main_conf "$NGX/server.conf" "    server { listen 127.0.0.1:18080; include $NGX/snippet.conf; }"
	run ngx_test "$NGX/server.conf"
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "R6: the snippet passes real nginx -t in the location context" {
	cp "$GOLDEN/default.conf" "$NGX/snippet.conf"
	main_conf "$NGX/location.conf" "    server { listen 127.0.0.1:18080; location / { include $NGX/snippet.conf; } }"
	run ngx_test "$NGX/location.conf"
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "R6: extra trusted addresses including unix: pass real nginx -t" {
	run --separate-stderr cfrn --dry-run --extra-trusted 10.0.0.5/32 --extra-trusted unix: --extra-trusted fd00::/8
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" >"$NGX/snippet.conf"
	main_conf "$NGX/extra.conf" "    include $NGX/snippet.conf;"
	run ngx_test "$NGX/extra.conf"
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "W8: nginx include globs skip dot files (open question 6)" {
	mkdir -p "$NGX/conf.d"
	cp "$GOLDEN/default.conf" "$NGX/conf.d/cloudflare-realip.conf"
	printf 'this is not nginx configuration\n' >"$NGX/conf.d/.cloudflare-realip.AbC123"
	main_conf "$NGX/star.conf" "    include $NGX/conf.d/*;"
	main_conf "$NGX/starconf.conf" "    include $NGX/conf.d/*.conf;"
	run ngx_test "$NGX/star.conf"
	echo "$output"
	[ "$status" -eq 0 ]
	run ngx_test "$NGX/starconf.conf"
	[ "$status" -eq 0 ]
	# Control: the same garbage without the leading dot is picked up.
	cp "$NGX/conf.d/.cloudflare-realip.AbC123" "$NGX/conf.d/visible"
	run ngx_test "$NGX/star.conf"
	[ "$status" -ne 0 ]
}

@test "W2 and W4 end to end with real nginx -t" {
	main_conf "$NGX/full.conf" "    include $ROOT/etc/nginx/conf.d/*.conf;"
	setting CFRN_TEST_COMMAND "\"nginx -t -q -p $NGX/ -c $NGX/full.conf\""
	setting CFRN_DUMP_COMMAND "\"nginx -T -q -p $NGX/ -c $NGX/full.conf\""
	run cfrn
	echo "$output"
	[ "$status" -eq 0 ]
	cmp "$OUT" "$GOLDEN/default.conf"
	[[ $output != *"not included"* ]]
	# Another file now sets real_ip_header in the same context, which breaks
	# the configuration with or without the new snippet.
	printf 'real_ip_header X-Real-IP;\n' >"$ROOT/etc/nginx/conf.d/other.conf"
	serve_v4 v4-plus-one.txt
	run cfrn
	echo "$output"
	[ "$status" -eq 4 ]
	[[ $output == *'"real_ip_header" directive is duplicate'* ]]
	[[ $output == *"already broken before this run"* ]]
	cmp "$OUT" "$GOLDEN/default.conf"
	[ "$(calls 'systemctl reload')" -eq 1 ]
}

@test "P5: a run under the shipped unit's sandbox passes W2" {
	if [[ ${CFRN_INTEGRATION_SYSTEMD:-0} != 1 ]]; then
		skip "set CFRN_INTEGRATION_SYSTEMD=1 (needs root and systemd)"
	fi
	local base props=() line
	base=$(mktemp -d /opt/cfrn-it.XXXXXX)
	mkdir -p "$base/etc/nginx/conf.d" "$base/state" "$base/shim" "$base/etc/nginx/.cloudflare-realip-nginx"
	cp "$SHIM_DIR/curl.spec" "$base/shim/"
	: >"$base/shim/calls.log"
	printf 'CFRN_OUTPUT=%s\nCFRN_STATE_DIR=%s\nCFRN_SERVICE_MANAGER=systemd\nCFRN_RETRY_DELAY=0\n' \
		"$base/etc/nginx/conf.d/cloudflare-realip.conf" "$base/state" >"$base/config"
	sed -e "s|@SBINDIR@|/usr/local/sbin|" -e "s|@OUTPUT_DIR@|$base/etc/nginx/conf.d|" \
		-e "s|@STAGING_DIR@|$base/etc/nginx/.cloudflare-realip-nginx|" -e "s|@STATE_DIR@|$base/state|" \
		"$REPO_ROOT/systemd/cloudflare-realip-nginx.service.in" >"$base/unit"
	while IFS= read -r line; do
		case $line in
		Protect* | ReadWritePaths=* | PrivateTmp=* | NoNewPrivileges=* | Restrict* | LockPersonality=* | SystemCallArchitectures=* | UMask=*)
			props+=(-p "$line")
			;;
		esac
	done <"$base/unit"
	props+=(-p "ReadWritePaths=$base/shim")
	run systemd-run --quiet --wait --pipe --collect "${props[@]}" \
		-E "PATH=$PATH" -E "SHIM_DIR=$base/shim" -E "FIXTURES=$FIXTURES" -E "NGINX_DUMP=# configuration file $base/etc/nginx/conf.d/cloudflare-realip.conf:" \
		"$TOOL" --config "$base/config"
	echo "$output"
	cat "$base/shim/calls.log"
	[ "$status" -eq 0 ]
	cmp "$base/etc/nginx/conf.d/cloudflare-realip.conf" "$GOLDEN/default.conf"
	rm -rf -- "$base"
}
