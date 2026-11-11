# Shared setup for the bats suite. Every test runs in its own temporary root
# with stand-in commands for curl, nginx, systemctl, sudo, id, logger and
# mktemp first on PATH. Nothing touches the network or the real nginx.

bats_require_minimum_version 1.5.0

REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
TOOL="$REPO_ROOT/bin/cloudflare-realip-nginx"
export FIXTURES="$BATS_TEST_DIRNAME/fixtures"
GOLDEN="$BATS_TEST_DIRNAME/golden"
V4_URL=https://www.cloudflare.com/ips-v4
V6_URL=https://www.cloudflare.com/ips-v6

common_setup() {
	ROOT="$BATS_TEST_TMPDIR/root"
	export SHIM_DIR="$BATS_TEST_TMPDIR/shim"
	export TMPDIR="$BATS_TEST_TMPDIR/tmp"
	mkdir -p "$ROOT/etc/nginx/conf.d" "$ROOT/var/lib/cfrn" "$SHIM_DIR" "$TMPDIR"
	export PATH="$BATS_TEST_DIRNAME/helpers/shims:$PATH"
	OUT="$ROOT/etc/nginx/conf.d/cloudflare-realip.conf"
	STATE="$ROOT/var/lib/cfrn"
	STAGING="$ROOT/etc/nginx/.cloudflare-realip-nginx"
	CONF="$BATS_TEST_TMPDIR/config"
	CALLS="$SHIM_DIR/calls.log"
	: >"$CALLS"
	cat >"$CONF" <<CONFIG
# Test configuration
CFRN_OUTPUT=$OUT
CFRN_STATE_DIR=$STATE
CFRN_SERVICE_MANAGER=systemd
CFRN_RETRY_DELAY=0
CONFIG
	export NGINX_DUMP="# configuration file $OUT:"
	unset FAKE_UID SUDO_DENY SUDO_LIST_RC MKTEMP_FAIL_MATCH CURL_IGNORE_MAXSIZE
	unset NGINX_CANDIDATE_RC NGINX_FULL_RC NGINX_RELOAD_RC SYSTEMCTL_RELOAD_RC SYSTEMCTL_ACTIVE_RC
	unset https_proxy no_proxy
	serve_ok
}

# serve_ok: both endpoints answer with the real lists.
serve_ok() {
	: >"$SHIM_DIR/curl.spec"
	serve "$V4_URL" 200 "text/plain;charset=UTF-8" v4-ok.txt 0
	serve "$V6_URL" 200 "text/plain;charset=UTF-8" v6-ok.txt 0
}

# serve URL STATUS CONTENT-TYPE FIXTURE CURL-EXIT [REDIRECT]
serve() {
	printf '%s %s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" "${6:-}" >>"$SHIM_DIR/curl.spec"
}

# reset_url URL: forget earlier spec lines for one URL.
reset_url() {
	local tmp="$SHIM_DIR/curl.spec.tmp"
	awk -v u="$1" '$1 != u' "$SHIM_DIR/curl.spec" >"$tmp"
	mv "$tmp" "$SHIM_DIR/curl.spec"
}

serve_v4() { reset_url "$V4_URL"; serve "$V4_URL" 200 text/plain "$1" 0; }
serve_v6() { reset_url "$V6_URL"; serve "$V6_URL" 200 text/plain "$1" 0; }

cfrn() {
	"$TOOL" --config "$CONF" "$@"
}

setting() {
	printf '%s=%s\n' "$1" "$2" >>"$CONF"
}

# Install a good snippet as if an earlier run had written it.
install_good_snippet() {
	run cfrn
	[ "$status" -eq 0 ]
	: >"$CALLS"
	rm -f "$SHIM_DIR"/*.count
}

calls() { grep -c -- "$1" "$CALLS" || true; }

# Fingerprint of everything "untouched" covers: live snippet, backup, modes.
fingerprint() {
	local f
	for f in "$OUT" "$STATE/previous.conf"; do
		if [[ -e $f ]]; then
			printf '%s %s ' "$(stat -c '%a %u' "$f")" "$(sha256sum <"$f" | cut -c1-16)"
		else
			printf 'absent '
		fi
	done
}

assert_untouched() { # fingerprint-before
	[ "$(fingerprint)" = "$1" ]
	[ "$(calls 'reload')" -eq 0 ]
}

no_temp_left() {
	[ -z "$(find "$ROOT/etc/nginx" -name '.cloudflare-realip.*' -type f)" ]
}
