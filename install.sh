#!/usr/bin/env bash
#
# Install or uninstall cloudflare-realip-nginx.
#
#   ./install.sh                     install, run a dry run with the nginx
#                                    syntax test, then enable the timer
#   ./install.sh --no-timer          install but do not enable the timer
#   ./install.sh --cron              use a cron file instead of systemd
#   ./install.sh --prefix /opt/x     put the tool in /opt/x/sbin
#   ./install.sh --uninstall         remove the tool, units, cron file, lock
#   ./install.sh --uninstall --purge also remove the snippet, state, config
#
# --destdir DIR installs under DIR (for packaging and tests). Service
# commands (systemctl, reload) are skipped when it is set.
#
# Copyright (c) 2026 Indian Opinion. MIT licence, see LICENSE.

set -euo pipefail
umask 022

readonly NAME=cloudflare-realip-nginx
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SRC

PREFIX=/usr/local
DESTDIR=
ACTION=install
USE_TIMER=1
FORCE_CRON=0
PURGE=0
CHANGED=0

say() { printf '%s\n' "$*"; }
fail() {
	printf 'install.sh: error: %s\n' "$*" >&2
	exit 1
}

usage() {
	sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while (($# > 0)); do
	case $1 in
	--prefix)
		(($# >= 2)) || fail "--prefix needs a directory"
		PREFIX=$2
		shift
		;;
	--destdir)
		(($# >= 2)) || fail "--destdir needs a directory"
		DESTDIR=${2%/}
		shift
		;;
	--no-timer) USE_TIMER=0 ;;
	--cron) FORCE_CRON=1 ;;
	--uninstall) ACTION=uninstall ;;
	--purge) PURGE=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*) fail "unknown argument: $1 (see --help)" ;;
	esac
	shift
done

[[ $PREFIX == /* ]] || fail "--prefix must be an absolute path"
[[ $PREFIX =~ ^/[A-Za-z0-9._/+-]*$ ]] || fail "--prefix has unsafe characters"
if [[ $PURGE == 1 && $ACTION != uninstall ]]; then
	fail "--purge only works with --uninstall"
fi
if [[ -z $DESTDIR && $(id -u) != 0 ]]; then
	fail "run as root (or use --destdir to stage the files somewhere else)"
fi

SBINDIR="$PREFIX/sbin"
TOOL="$DESTDIR$SBINDIR/$NAME"
CONF="$DESTDIR/etc/default/$NAME"
UNITDIR="$DESTDIR/etc/systemd/system"
CRONFILE="$DESTDIR/etc/cron.d/$NAME"
PERIODIC="$DESTDIR/etc/periodic/daily/$NAME"

# Service commands touch the running system, so they are skipped for a
# staged install unless a test asks for them.
run_services() {
	[[ -z $DESTDIR || ${CFRN_INSTALL_RUN_SERVICE_COMMANDS:-0} == 1 ]]
}

has_systemd() {
	[[ -d ${CFRN_SYSTEMD_RUN_DIR:-/run/systemd/system} ]] && command -v systemctl >/dev/null 2>&1
}

# Read one setting from the config file without executing it.
cfg_get() { # key default
	local v=
	if [[ -f $CONF ]]; then
		v=$(sed -n "s/^[[:space:]]*$1=//p" "$CONF" | tail -n 1)
		v=${v%\"}
		v=${v#\"}
		v=${v%\'}
		v=${v#\'}
	fi
	printf '%s' "${v:-$2}"
}

OUTPUT=$(cfg_get CFRN_OUTPUT /etc/nginx/conf.d/cloudflare-realip.conf)
STATE_DIR=$(cfg_get CFRN_STATE_DIR /var/lib/$NAME)
OUTPUT_DIR=$(dirname "$OUTPUT")
STAGING_DIR=$(cfg_get CFRN_STAGING_DIR "")
if [[ -z $STAGING_DIR ]]; then
	STAGING_DIR="$(dirname "$OUTPUT_DIR")"
	STAGING_DIR="${STAGING_DIR%/}/.$NAME"
fi
NGINX=$(cfg_get CFRN_NGINX nginx)
SERVICE=$(cfg_get CFRN_SERVICE_NAME nginx)
for p in "$OUTPUT" "$STATE_DIR" "$STAGING_DIR"; do
	[[ $p =~ ^/[A-Za-z0-9._/@+-]*$ ]] || fail "unsafe path in $CONF: $p"
done

# put SRC DEST MODE: install a file only when its content differs.
put() {
	if [[ -f $2 ]] && cmp -s -- "$1" "$2"; then
		say "unchanged: $2"
		return 0
	fi
	install -D -m "$3" -- "$1" "$2"
	say "installed: $2"
	CHANGED=1
}

render() { # template > stdout
	sed -e "s|@SBINDIR@|$SBINDIR|g" \
		-e "s|@OUTPUT_DIR@|$OUTPUT_DIR|g" \
		-e "s|@STAGING_DIR@|$STAGING_DIR|g" \
		-e "s|@STATE_DIR@|$STATE_DIR|g" \
		-e "s|@MINUTE@|$((RANDOM % 60))|g" \
		-e "s|@HOUR@|$((RANDOM % 24))|g" \
		-e "s|@DELAY@|$((RANDOM % 3600))|g" "$1"
}

TMPD=
cleanup() {
	if [[ -n $TMPD && -d $TMPD ]]; then
		rm -rf -- "$TMPD"
	fi
}
trap cleanup EXIT

do_install() {
	local tmp mode=systemd
	TMPD=$(mktemp -d)
	tmp=$TMPD

	if [[ $FORCE_CRON == 1 ]] || ! has_systemd; then
		mode=cron
		if [[ $FORCE_CRON == 0 ]]; then
			say "systemd not found: installing a cron job instead of a timer"
		fi
	fi

	put "$SRC/bin/$NAME" "$TOOL" 0755

	if [[ ! -f $CONF ]]; then
		put "$SRC/etc/default/$NAME" "$CONF" 0644
	elif cmp -s -- "$SRC/etc/default/$NAME" "$CONF"; then
		say "unchanged: $CONF"
	elif [[ -f $CONF.new ]] && cmp -s -- "$SRC/etc/default/$NAME" "$CONF.new"; then
		say "kept: $CONF (your settings; the shipped default is in $CONF.new)"
	else
		install -m 0644 -- "$SRC/etc/default/$NAME" "$CONF.new"
		say "kept: $CONF (your settings); wrote the new default to $CONF.new"
		CHANGED=1
	fi

	local units_changed=0
	if [[ $mode == systemd ]]; then
		local before=$CHANGED
		CHANGED=0
		render "$SRC/systemd/$NAME.service.in" >"$tmp/$NAME.service"
		put "$tmp/$NAME.service" "$UNITDIR/$NAME.service" 0644
		put "$SRC/systemd/$NAME.timer" "$UNITDIR/$NAME.timer" 0644
		units_changed=$CHANGED
		CHANGED=$((before | CHANGED))
	elif [[ -d $DESTDIR/etc/cron.d ]]; then
		if [[ -f $CRONFILE ]]; then
			say "unchanged: $CRONFILE (keeps its random time)"
		else
			render "$SRC/cron/$NAME.in" >"$tmp/cron"
			put "$tmp/cron" "$CRONFILE" 0644
		fi
	elif [[ -d $DESTDIR/etc/periodic/daily ]]; then
		if [[ -f $PERIODIC ]]; then
			say "unchanged: $PERIODIC (keeps its random delay)"
		else
			render "$SRC/cron/periodic-daily.in" >"$tmp/periodic"
			put "$tmp/periodic" "$PERIODIC" 0755
		fi
	else
		fail "neither systemd, /etc/cron.d nor /etc/periodic/daily found; schedule '$SBINDIR/$NAME --quiet' once a day yourself"
	fi

	local d
	for d in "$DESTDIR$STATE_DIR:0750" "$DESTDIR$STAGING_DIR:0700"; do
		if [[ ! -d ${d%:*} ]]; then
			install -d -m "${d##*:}" -- "${d%:*}"
			say "created: ${d%:*}"
			CHANGED=1
		fi
	done
	if [[ ! -d $DESTDIR$OUTPUT_DIR ]]; then
		if [[ -d $(dirname "$DESTDIR$OUTPUT_DIR") ]]; then
			install -d -m 0755 -- "$DESTDIR$OUTPUT_DIR"
			say "created: $DESTDIR$OUTPUT_DIR"
			CHANGED=1
		else
			say "note: $(dirname "$OUTPUT_DIR") does not exist; install nginx or set CFRN_OUTPUT in $CONF"
		fi
	fi

	if [[ $CHANGED == 0 ]]; then
		say "nothing to do: already installed"
		return 0
	fi

	say "checking: $NAME --dry-run --test"
	if ! CFRN_OUTPUT="$DESTDIR$OUTPUT" CFRN_STATE_DIR="$DESTDIR$STATE_DIR" \
		"$TOOL" --config "$CONF" --dry-run --test --quiet >/dev/null; then
		fail "the dry run failed, so the timer was not enabled; fix the error above and run install.sh again"
	fi
	say "dry run passed"

	if [[ $mode != systemd ]]; then
		say "done: scheduled by cron"
		return 0
	fi
	if [[ $USE_TIMER == 0 ]]; then
		say "done: timer not enabled (--no-timer); enable it with: systemctl enable --now $NAME.timer"
		return 0
	fi
	if ! run_services; then
		say "skipped: systemctl enable --now $NAME.timer (--destdir is set)"
		return 0
	fi
	if [[ $units_changed == 1 ]]; then
		systemctl daemon-reload
	fi
	if ! systemctl is-enabled --quiet "$NAME.timer"; then
		systemctl enable --now "$NAME.timer"
		say "enabled: $NAME.timer"
	fi
	say "done: the timer runs daily; check with: systemctl list-timers $NAME.timer"
}

remove() { # path
	if [[ -e $1 ]]; then
		rm -f -- "$1"
		say "removed: $1"
	fi
}

nginx_reload() {
	if ! run_services; then
		say "skipped: nginx reload (--destdir is set)"
		return 0
	fi
	if has_systemd; then
		systemctl reload "$SERVICE" || say "warning: reload failed; reload nginx by hand"
	else
		"$NGINX" -s reload || say "warning: reload failed; reload nginx by hand"
	fi
}

do_uninstall() {
	if has_systemd && run_services && [[ -f $UNITDIR/$NAME.timer ]]; then
		systemctl disable --now "$NAME.timer" || true
	fi
	remove "$TOOL"
	remove "$UNITDIR/$NAME.service"
	remove "$UNITDIR/$NAME.timer"
	remove "$CRONFILE"
	remove "$PERIODIC"
	remove "$DESTDIR$STATE_DIR/lock"
	if [[ -d $DESTDIR$STAGING_DIR ]]; then
		if rmdir -- "$DESTDIR$STAGING_DIR" 2>/dev/null; then
			say "removed: $DESTDIR$STAGING_DIR"
		fi
	fi
	if has_systemd && run_services; then
		systemctl daemon-reload || true
	fi

	if [[ $PURGE == 0 ]]; then
		say "kept: $DESTDIR$OUTPUT (the snippet)"
		say "kept: $DESTDIR$STATE_DIR (backup and state)"
		say "kept: $CONF (your settings)"
		say "Removing the snippet changes every logged client address at the next"
		say "reload, so it is a separate step: ./install.sh --uninstall --purge"
		return 0
	fi

	local snippet="$DESTDIR$OUTPUT" saved=
	if [[ -f $snippet ]]; then
		saved=$(mktemp)
		cp -p -- "$snippet" "$saved"
		rm -f -- "$snippet"
		local out rc=0
		out=$("$NGINX" -t 2>&1) || rc=$?
		if ((rc != 0)); then
			cp -p -- "$saved" "$snippet"
			rm -f -- "$saved"
			printf '%s\n' "$out" >&2
			fail "nginx -t fails without the snippet, so it was put back. If another file still includes $OUTPUT, remove that include first, then run --uninstall --purge again"
		fi
		rm -f -- "$saved"
		say "removed: $snippet"
	fi
	if [[ -d $DESTDIR$STATE_DIR && $STATE_DIR != / ]]; then
		rm -rf -- "$DESTDIR$STATE_DIR"
		say "removed: $DESTDIR$STATE_DIR"
	fi
	remove "$CONF"
	remove "$CONF.new"
	nginx_reload
	say "done: purged"
}

if [[ $ACTION == install ]]; then
	do_install
else
	do_uninstall
fi
