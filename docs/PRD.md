# PRD: cloudflare-realip-nginx

Status: draft for review. A shell tool (bash 4.2 or later, `set -euo
pipefail`, shellcheck clean, bats tests), a systemd service and timer, a cron
example, and an install script.

This document describes behaviour, interfaces, cases and tests. It contains
no code. Command names, flags, file names and exit codes below are proposals
for the builder, who may refine them in `docs/ARCHITECTURE.md` as long as
every case in section 4 keeps its test in section 12. Sources are listed at
the end under "References".

## 1. Problem

When a site sits behind Cloudflare, every request reaches nginx from a
Cloudflare edge address. nginx sees that edge address as the client unless
the realip module is told which addresses to trust and which header holds
the visitor's address. Cloudflare publishes its ranges as two plain text
lists and says the list "needs to be updated regularly" [R3].

Without correct real-IP handling:

- `limit_req` and `limit_conn` keyed on the client address put thousands of
  readers into a handful of buckets, one per edge address. A single abuser
  gets every reader on the same edge throttled with them, and a login rate
  limit stops working as a per-attacker limit.
- `geo` blocklists, `allow` and `deny`, and access logs see Cloudflare, not
  the attacker.
- Applications behind nginx (PHP, Python, anything reading `REMOTE_ADDR`)
  log and rate limit the edge too.

When the list goes stale, the failure is quiet. A new Cloudflare range is
not trusted, so visitors routed through it show up as the edge address
again. Nothing errors. Rate limits start to misfire for some readers only.

Measured result: on the origin this tool came out of, the login rate limit
turns away about 1,300 brute-force attempts a day from a single address;
keyed on the edge address instead, those attempts would share a bucket with
every reader arriving through the same Cloudflare data centre.

The usual fix is a ten-line cron script. The one this project replaces
wrote the new file over the live one before testing it, reloaded nginx on
every run whether anything changed or not, checked only the IPv4 count, and
accepted any line containing a slash as a range. Each of those is a case
below.

There is also a security consequence that no snippet can fix on its own.
Cloudflare's ranges are what nginx trusts. If the origin also accepts
connections from anywhere else, a visitor can skip Cloudflare entirely: no
WAF, no edge rate limits, no DDoS absorption. And if real-IP is set up
wrongly (for example trusting every address, or logging the raw
`CF-Connecting-IP` header instead of the restored address), anyone who can
reach the origin directly can claim to be any client address they like. The
README must say plainly that the origin should accept web traffic only from
Cloudflare's ranges at the firewall, and explain how (section 8).

## 2. Goals and non-goals

### Goals

1. Fetch Cloudflare's published IPv4 and IPv6 ranges from the official text
   endpoints over HTTPS only.
2. Validate them strictly: CIDR syntax per family, no host bits set, no
   duplicates after normalisation, non-empty, plausible count, plausible
   change versus the previous list, optional pinning to the documented
   hosts.
3. Render an nginx snippet: one `set_real_ip_from` line per range, then
   `real_ip_header CF-Connecting-IP`. Options for `X-Forwarded-For` (or
   another single header name) and for `real_ip_recursive on`.
4. Install the snippet safely: temp file in the target directory, a syntax
   test of the candidate alone, an atomic rename, a full `nginx -t`, and a
   reload only when the content changed. On any failure after the rename,
   put the previous file back.
5. Keep the previous snippet for a one-command rollback.
6. Exit non-zero without touching the live snippet or nginx on any fetch or
   validation failure.
7. Log every run to stdout and to syslog, one summary line per run.
8. Offer a dry run (print the snippet, change nothing) and a diff mode (print
   a unified diff against the live snippet, change nothing).
9. Ship a systemd service and timer, a cron example, and an install script
   with uninstall, none of which need Ansible or any other tool.
10. Document the security consequence and the firewall step in the README.

### Non-goals

- Firewall management (ufw, nftables, iptables, cloud security groups). The
  README explains it; the tool never touches a firewall.
- Any call to the Cloudflare API, authenticated or not. The tool reads the
  two public text lists only.
- Other CDNs or proxies (CloudFront, Fastly, Akamai, a local load
  balancer). An operator can add extra trusted addresses (section 7), but
  the tool does not fetch other providers' lists.
- Other web servers (Apache, Caddy, HAProxy, Traefik).
- The Cloudflare China network ranges, which are not on the public text
  lists.
- Editing the operator's nginx configuration beyond the one snippet file. The
  tool never edits `nginx.conf`, a server block, or a `log_format`.
- Configuration management modules (Ansible, Chef, Puppet, Salt).
- Windows. Containers are documented (bind mount the snippet), not packaged.

## 3. Users and setting

The user is an operator running nginx on a Linux origin behind Cloudflare,
typically a single VM or a few. They install the tool once as root, enable
the timer, and want to forget about it until it tells them something is
wrong.

It runs:

- as root from a systemd timer (the default), or from cron;
- optionally as an unprivileged user with sudo rights for exactly the test
  and reload commands (section 4.7);
- by hand, at 2 a.m., in dry-run or diff mode, by someone checking why
  client addresses look wrong in the logs.

Supported hosts: Debian 11 and 12, Ubuntu 22.04 and 24.04, RHEL 9 and its
rebuilds (Rocky, Alma), Alpine 3.19 or later with cron only (no systemd).
nginx from the distribution, from nginx.org packages, or OpenResty.

## 4. Behaviour

Every case is numbered. Section 12 maps each number to at least one test.
"Live snippet" means the file nginx includes. "Untouched" means the live
snippet, its backup and the nginx process are exactly as before the run:
same bytes, same mode, same owner, no reload.

### 4.1 Run order (every mode)

The tool does these steps in this order and stops at the first failure:

1. Parse flags, read the config file, validate every setting.
2. Take an exclusive lock.
3. Preflight: nginx binary found, target directory exists and is writable
   (or writable through the configured privilege helper), state directory
   exists.
4. Fetch the IPv4 list, then the IPv6 list.
5. Parse and validate both lists.
6. Render the candidate snippet.
7. Compare with the live snippet. Dry run and diff mode stop here.
8. Write the candidate to a temp file in the target directory.
9. Test the candidate alone with nginx in a minimal throwaway config.
10. Copy the live snippet (if any) to the backup path.
11. Rename the temp file over the live snippet.
12. Run the full `nginx -t`. On failure, restore and stop.
13. Reload nginx.
14. Record success in the state file. Log the summary.

Steps 1 to 9 never touch the live snippet or nginx. That is the "fail
closed" guarantee: any failure before step 11 leaves the old, working
configuration exactly as it was, because a stale but valid trust list is far
safer than a wrong one or none.

### 4.2 Fetch cases

F1. Normal fetch. Both endpoints return HTTP 200 with `text/plain` and a
list of ranges. Continue.

F2. Connect timeout. No TCP or TLS connection within the connect timeout
(default 10 s). Retry with backoff (default 3 attempts, 2 s then 4 s).
After the last attempt: exit 2 (fetch failure), untouched.

F3. Total timeout. The transfer does not finish within the total timeout
(default 30 s per attempt), for example a server that trickles bytes.
Retry as F2, then exit 2, untouched.

F4. DNS failure. Name does not resolve. Retry as F2, then exit 2,
untouched.

F5. TLS failure. Certificate invalid, expired, wrong name, or the system CA
bundle is missing. No retry (it will not fix itself in seconds). Exit 2,
untouched. The tool never offers an "insecure" flag.

F6. HTTP error status. Any status other than 200 after redirects (403 bot
challenge, 404, 429, 5xx). 429 and 5xx are retried; 4xx other than 429 is
not. Then exit 2, untouched. The log line names the status and URL.

F7. Partial response. The connection closes before the declared
Content-Length is reached, or a chunked transfer is cut short. curl reports
this as an error: treat it as F6 (retry, then exit 2). A response cut short
without any transport error is caught by validation: a range cut mid-line
almost always has host bits set (V5) or fails syntax (V2), and a list cut
between lines fails the count or shrink checks (V8, V10).

F8. Empty body. HTTP 200 with zero bytes, or only whitespace. Exit 3
(validation failure), untouched.

F9. Oversized body. More than the maximum size (default 64 KiB; the real
lists are under 1 KiB). Abort the transfer at the limit. Exit 3,
untouched.

F10. Wrong content type. The response is HTML (a captive portal, an error
page served with 200, a bot challenge), JSON, or anything that is not
`text/plain`. Exit 3, untouched. The log quotes the content type, never the
body.

F11. Changed format. The body is `text/plain` but lines are no longer bare
ranges (for example a header line, JSON, CSV columns, or a comment syntax).
Treated by validation: any line that is not blank and not a valid range for
the expected family fails V2. Exit 3, untouched. The tool does not try to
guess a new format; a human must look.

F12. Redirects. Follow at most 3 redirects, HTTPS to HTTPS only. A redirect
to plain HTTP, or to a host outside the pinned list when pinning is on, is
refused: exit 2, untouched. (Today the bare paths answer 200 and the HTTP
form of the URL answers 301 to HTTPS.)

F13. Non-HTTPS URL configured. A URL override that is not `https://` is a
config error. Exit 1 before any network call.

F14. Host pinning. When pinning is on (the default), the configured URLs and
every redirect target must have the host `www.cloudflare.com`. A URL
override to another host is a config error (exit 1) unless pinning is
turned off explicitly. Turning it off is logged as a warning on every run.

F15. Proxy. The standard `https_proxy` and `no_proxy` environment variables
are honoured. A proxy that returns its own error page is caught by F6 or
F10.

F16. One family fails. If either list fails any fetch or validation case,
the whole run fails. The tool never writes a snippet with a fresh IPv4 list
and a stale or missing IPv6 list, or the reverse.

F17. Missing trailing newline. The real endpoints end the last range
without a newline (measured on 11 November 2026). The last line counts like
any other. Parsing must not drop it.

F18. Line endings and whitespace. CRLF line endings, a UTF-8 byte order
mark at the start, leading or trailing spaces and tabs, and blank lines are
tolerated and stripped. Nothing else is tolerated.

### 4.3 Validation cases

V1. Family. Every entry in the IPv4 list must be IPv4, every entry in the
IPv6 list must be IPv6. An IPv6 range in the IPv4 list (or the reverse)
fails. Exit 3.

V2. Syntax. Each entry is an address, a slash, and a prefix length. IPv4:
four decimal octets 0 to 255 with no leading zeros, prefix 0 to 32. IPv6:
standard text form with at most one `::`, hex groups of one to four digits,
prefix 0 to 128; embedded IPv4 notation, zone ids and brackets are
rejected. A bare address without a prefix is rejected (Cloudflare has
always published prefixes; a bare address means the format changed). Exit
3.

V3. Prefix floor. A prefix shorter than the floor is rejected (defaults:
/8 for IPv4, /16 for IPv6; the widest published today are /13 and /29).
This stops a corrupted or hostile list from making nginx trust a large part
of the internet, which would let anyone set their own client address. Exit
3.

V4. Never trusted. Default routes (`0.0.0.0/0`, `::/0`) and ranges that
overlap loopback, private (RFC 1918, RFC 4193), link-local, multicast,
documentation, carrier-grade NAT or IPv4-mapped space are rejected. Exit 3.

V5. Host bits. A range with bits set below the prefix (for example an
address ending in `.1` with a /24) is rejected rather than silently
masked. This also catches most mid-line truncation (F7). Exit 3.

V6. Normalisation. IPv6 is lower-cased and written in a canonical form
(RFC 5952) so that a change in Cloudflare's capitalisation or zero
compression does not count as a change.

V7. Duplicates. Duplicates after normalisation are removed and logged as a
warning, not an error.

V8. Count bounds. Each family must have at least the minimum (defaults: 10
IPv4, 3 IPv6; today Cloudflare publishes 15 and 7) and at most the maximum
(default 200 each). Outside the bounds: exit 3.

V9. Order. Output is sorted (IPv4 then IPv6, numeric order inside each) so
that a reordering by Cloudflare does not count as a change.

V10. Shrink guard. When a previous snippet exists, a run that would remove
more than the allowed share of either family (default 50 percent) is
refused with exit 3 unless `--force` is given. Additions are never limited.
The log names every added and removed range on every run that changes
anything.

V11. Extra trusted addresses. Addresses the operator adds (for example a
local load balancer, or `unix:`) are validated with V1, V2, V5 and V7 but
are exempt from V3 and V4, because a private load balancer address is a
normal thing to trust on purpose. They are written in their own commented
block after the Cloudflare ranges.

### 4.4 Render cases

R1. Default output. A comment header saying the file is generated, by which
tool and version, from which URLs, and that hand edits will be overwritten;
one `set_real_ip_from` line per range; then `real_ip_header
CF-Connecting-IP`. No timestamp in the file (see R5).

R2. `X-Forwarded-For` mode. `real_ip_header X-Forwarded-For`. The README
explains that Cloudflare appends to any `X-Forwarded-For` the visitor sent,
so without `real_ip_recursive on` nginx takes the last entry, which is the
address Cloudflare saw.

R3. Recursive. `--recursive` adds `real_ip_recursive on`. It is allowed
with any header but the tool warns that it has no effect with
`CF-Connecting-IP`, which carries one address.

R4. Other header. Any header name made only of letters, digits and hyphens
is accepted (for example `True-Client-IP` on Enterprise plans). Anything
else is a config error, exit 1. This keeps the value safe to write into
nginx configuration.

R5. Determinism. The same lists and options always render byte-identical
output. Run metadata (time, hashes, counts) goes to the state file and the
log, not the snippet, so that "changed" means the trust list or the options
changed.

R6. Context. The snippet contains only directives valid in the `http`,
`server` and `location` contexts, so it can be included at any of them. The
README recommends the `http` context, once, so it applies before any
`limit_req_zone`, `geo` or `map` keyed on the client address.

### 4.5 Write, test and reload cases

W1. Unchanged content. The candidate is byte-identical to the live snippet.
No write, no test, no backup rotation, no reload. Log "unchanged", update
the last-success time in the state file, exit 0.

W2. Changed content, all good. Steps 8 to 14 run. Exit 0. The log names
added and removed ranges.

W3. Candidate syntax test fails (step 9). For example the realip module is
not compiled in ("unknown directive set_real_ip_from"), or a bad extra
address slipped past validation. Delete the temp file. Exit 4,
untouched. The log quotes nginx's error and, for the unknown-directive
case, says the realip module is missing.

W4. Full `nginx -t` fails after the rename (step 12). For example another
file already sets `real_ip_header` in the same context ("duplicate"), or an
unrelated part of the configuration was already broken. Put the backup back
by rename (or delete the new file on a first run), run `nginx -t` again to
confirm the old state, do not reload, exit 4. If the configuration was
already broken before the run, the log says so plainly: the tool cannot
tell whose fault it is, so it restores and refuses.

W5. Reload fails (step 13). The configuration is valid (it passed W4), so
the new snippet stays in place. Exit 5. The log quotes the reload command's
error. The next run sees "unchanged" and will not retry the reload, so the
state file records a pending reload and the next run retries it.

W6. nginx not running. The reload is skipped with a notice, the new
snippet stays (nginx reads it when it starts), exit 0. Detected through
the service manager when present, otherwise through the pid file.

W7. Disk full or write error. The temp write fails. Delete what was
written. Exit 1, untouched.

W8. Temp file location. The temp file is created in the target directory,
so the rename is atomic (same filesystem) and the file gets the
directory's SELinux label. Its name starts with a dot and does not end in
`.conf`, so neither an `*.conf` nor a bare `*` include glob can pick it up.
It is removed on every exit path, including signals (INT, TERM, HUP).

W9. Mode and owner. The live snippet is written mode 0644, owned by the
user running the tool (root by default). An existing snippet's owner and
mode are not preserved if they are looser; they are never made looser.

W10. Target is a symlink. Refused with exit 1 and a message, because
renaming over a symlink silently replaces it and breaks whatever manages
the link. The operator can point the tool at the real path.

W11. Foreign file. The target exists but has no generated-by header from
this tool (a hand-written snippet, or one from another tool). Refused with
exit 1 unless `--force` is given, so the tool never overwrites a file it
did not write. With `--force`, the foreign file goes to the backup path
first like any other.

W12. Concurrency. A second run while one holds the lock exits 6 straight
away with a "run in progress" message, untouched. A stale lock from a
crashed run does not block forever: the lock is an advisory `flock` on a
file in the state directory, released by the kernel when the holder exits.

W13. Snippet not included. After a successful write the tool checks that
the full configuration dump (`nginx -T`) mentions the target path. If not,
it logs a warning that the file is not included anywhere and nothing will
change until it is. This is a warning, not a failure, because the include
might be added later. On a first run it prints the include line to add.

W14. Interrupted run. A crash or kill between steps 11 and 12 can leave a
new snippet in place that has not passed the full test. The next run
detects the leftover state (the state file records "in progress" before
step 10) and runs the full test first; on failure it restores the backup.

### 4.6 First run

FR1. No snippet yet, no backup, no state file. The shrink guard (V10) is
skipped because there is no previous list. W2 runs with no backup step. If
W4 fails, the new file is deleted so the box is exactly as before.

FR2. Diff mode on a first run shows the whole snippet as added.

FR3. Target directory missing. Exit 1 with a message naming it. The tool
does not create `/etc/nginx` subdirectories; the install script does.

FR4. State directory missing. Created by the install script; if it is still
missing, the tool creates it (mode 0750) when it runs as root, otherwise
exits 1.

### 4.7 Permissions

P1. Root. The default. Everything works.

P2. Unprivileged user with sudo. The user owns nothing in `/etc/nginx`. The
config names a privilege helper (default `sudo -n`) and the tool uses it
for exactly four commands: `nginx -t`, `nginx -T`, the reload command, and
an `install` of the finished file to the target path. The README ships a
sudoers example for exactly those commands with fixed arguments.

P3. `nginx -t` as non-root. It usually fails because TLS private keys and
log files are root-only. The tool therefore never runs the full test
without the helper when not root, and the README says why.

P4. Missing rights. A non-root run without the helper, or with `sudo -n`
asking for a password, fails at preflight (step 3) with exit 1 and a
message that names the missing right. Untouched.

P5. Hardened systemd unit. The shipped unit runs as root but with
`ProtectSystem=strict` and write access only to the target directory, the
state directory and the nginx log and run directories that `nginx -t`
needs. Running inside it must still pass W2.

### 4.8 Rollback

RB1. `--rollback` swaps the backup and the live snippet (so a second
`--rollback` undoes the first), runs the full `nginx -t`, and reloads. On
test failure it swaps back and exits 4.

RB2. No backup exists. Exit 1 with a message. Untouched.

RB3. Rollback and the timer. A rollback writes a hold marker into the state
file; scheduled runs log "held after rollback" and exit 0 without fetching
until the operator runs `--release`, or the hold expires (default 7 days,
after which the run warns and proceeds). Without this, the next timer run
would undo the rollback within a day.

RB4. Only one previous version is kept. The backup lives in the state
directory, not next to the snippet, so it can never be included by
accident.

### 4.9 Dry run and diff mode

D1. `--dry-run` runs steps 1 to 7, prints the candidate snippet to stdout,
optionally runs the candidate syntax test (step 9) with `--dry-run --test`,
and changes nothing. Exit 0 on success, or the same failure codes as a
real run.

D2. `--diff` runs steps 1 to 7 and prints a unified diff between the live
snippet and the candidate. Exit 0 when there is no difference and 10 when
there is one, so it can drive a monitoring check.

D3. Neither mode takes the lock longer than the fetch, writes the state
file, or calls the reload command.

D4. Neither mode needs root when the live snippet is world-readable.

### 4.10 Verification (how an operator proves it works)

Documented in the README, and partly automated by `--verify`:

X1. Configuration check. `--verify` confirms that the snippet exists, is
from this tool, is included (W13), passes `nginx -t`, and that the state
file shows a success in the last 14 days. It prints one line per check and
exits 0 only if all pass.

X2. Live request through Cloudflare. The operator adds `$remote_addr` and
`$realip_remote_addr` to a log format (the README shows how), requests the
site through Cloudflare, and compares the logged `$remote_addr` with their
own public address (for example the `ip=` line from Cloudflare's
`/cdn-cgi/trace` page on any proxied hostname). `$remote_addr` must be
their address; `$realip_remote_addr` must be a Cloudflare address.

X3. Spoof check. From a host outside Cloudflare, the operator sends a
request straight to the origin address with a forged `CF-Connecting-IP`
(using a documentation address such as one in 203.0.113.0/24). With the
firewall in place the connection must fail. Without it, the logged
`$remote_addr` must be the sender's real address, not the forged one. If
the forged address appears, real-IP is misconfigured and the README says
what to look for (an over-wide `set_real_ip_from`, or a log format or
application reading the raw header).

X4. Staleness. `--status` prints the time and result of the last run, the
last success, the range counts and the snippet hash. A last success older
than the staleness limit (default 14 days) is printed as a warning and also
logged by every run.

### 4.11 Install and uninstall

I1. `install.sh` copies the tool to `/usr/local/sbin`, the config file to
`/etc/default` (never overwriting an existing one; a new default goes next
to it with a `.new` suffix), the systemd units to `/etc/systemd/system`,
creates the state directory, runs `--dry-run --test`, and only then
enables and starts the timer. Flags: `--no-timer`, `--cron` (installs the
cron example under `/etc/cron.d` instead), `--prefix`.

I2. Without systemd (Alpine, containers), `install.sh` installs the cron
example and says so.

I3. Install is idempotent: a second run changes nothing and says so.

I4. `install.sh --uninstall` stops and disables the timer, removes the
tool, units, cron file and lock, and leaves the snippet, the backup and the
config in place, printing what it left and why: removing the snippet
changes every logged client address on the next reload, so that is a
separate, deliberate step.

I5. `install.sh --uninstall --purge` also removes the snippet, the state
directory and the config, then runs `nginx -t` and reloads. If the test
fails it puts the snippet back and stops. If other configuration still
refers to the snippet by path, the test fails and the message says to
remove the include first.

### 4.12 Failure modes summary

| Situation | Outcome | Open or closed |
|---|---|---|
| Any fetch failure | Exit 2, untouched | Closed: keep the last good list |
| Any validation failure | Exit 3, untouched | Closed |
| Candidate or full test fails | Exit 4, restored | Closed |
| Reload fails | Exit 5, valid file kept, reload retried next run | Open: the file is valid |
| nginx stopped | Exit 0, file written, no reload | Open: read on start |
| Lock busy | Exit 6, untouched | Closed |
| Held after rollback | Exit 0, no fetch | Closed until released |

"Closed" here always means the old snippet keeps working. The tool never
leaves nginx without a trust list it had before, and never widens trust on
a guess.

## 5. Public interface

### Command

`cloudflare-realip-nginx [mode] [options]`

Modes (one at a time; default is update): update, `--dry-run`, `--diff`,
`--rollback`, `--release`, `--verify`, `--status`, `--version`, `--help`.

Options: `--config FILE`, `--output FILE`, `--header NAME`, `--recursive`,
`--extra-trusted CIDR` (repeatable), `--force`, `--test` (with
`--dry-run`), `--quiet` (stdout only on warnings and errors),
`--no-syslog`.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (updated, unchanged, nginx stopped, or held) |
| 1 | Usage, configuration, permission or local write error |
| 2 | Fetch failure |
| 3 | Validation failure |
| 4 | nginx configuration test failed; previous state restored |
| 5 | Reload failed; new valid snippet in place |
| 6 | Another run holds the lock |
| 10 | `--diff` only: differences found |

### Files shipped

The tool, a config file with every setting commented, a systemd service
and timer, a cron example, `install.sh`, a sudoers example, a log format
example for verification.

### Snippet format

Plain nginx directives as in R1 to R4. The generated-by header is the
contract W11 checks; its exact wording is fixed in ARCHITECTURE.md and must
not change between minor versions.

## 6. Data

| Item | Default location | Retention |
|---|---|---|
| Live snippet | `/etc/nginx/conf.d/cloudflare-realip.conf` | Replaced on change |
| Backup | `/var/lib/cloudflare-realip-nginx/previous.conf` | One version |
| State file | `/var/lib/cloudflare-realip-nginx/state` | Overwritten each run |
| Lock | `/var/lib/cloudflare-realip-nginx/lock` | Run lifetime |
| Logs | stdout and syslog | Owned by the host's log rotation |

The state file holds plain key and value lines: last run time and result,
last success time, counts per family, snippet hash, pending-reload flag,
in-progress flag, hold marker and its expiry. No addresses of visitors are
ever stored. Uninstall is covered by I4 and I5.

## 7. Configuration and sensible defaults

Settings come from the config file (default
`/etc/default/cloudflare-realip-nginx`, shell-style `KEY=value`, parsed as
data and never sourced or executed), then environment variables with the
same names, then flags. Later wins. Unknown keys are a config error so
typos do not pass silently.

| Setting | Default | Notes |
|---|---|---|
| Output path | `/etc/nginx/conf.d/cloudflare-realip.conf` | Absolute path, no symlink |
| State directory | `/var/lib/cloudflare-realip-nginx` | |
| IPv4 URL | `https://www.cloudflare.com/ips-v4` | HTTPS only |
| IPv6 URL | `https://www.cloudflare.com/ips-v6` | HTTPS only |
| Pin host | on, `www.cloudflare.com` | F14 |
| Header | `CF-Connecting-IP` | R2, R4 |
| Recursive | off | R3 |
| Extra trusted | none | V11 |
| Min count IPv4 / IPv6 | 10 / 3 | V8 |
| Max count per family | 200 | V8 |
| Min prefix IPv4 / IPv6 | 8 / 16 | V3 |
| Max shrink | 50 percent | V10 |
| Connect / total timeout | 10 s / 30 s | F2, F3 |
| Attempts | 3 | F2 |
| Max body size | 64 KiB | F9 |
| Test command | `nginx -t` | |
| Reload command | `systemctl reload nginx`, else `nginx -s reload` | Auto-detected |
| Privilege helper | none as root, `sudo -n` otherwise | P2 |
| Staleness limit | 14 days | X4 |
| Hold expiry | 7 days | RB3 |
| Syslog tag | `cloudflare-realip-nginx` | |

Timer: daily at a randomised time (`RandomizedDelaySec` of one hour),
`Persistent=true` so a missed run happens at boot. Cron example: once a day
at a minute the installer picks at random, so a fleet does not hit the
endpoints at the same second.

## 8. Security and privacy

- Trust is the product. Every validation rule exists to stop the tool from
  trusting addresses it should not. A wider trust list means a wider set of
  hosts that can forge the client address.
- HTTPS only, certificate verification always on, redirects HTTPS-only,
  host pinned by default (F5, F12, F13, F14).
- The config file is parsed, never sourced; header names and paths are
  validated before they reach nginx configuration or a command line (R4).
- The privilege helper is used for four fixed commands only (P2). The
  sudoers example has no wildcards.
- No visitor data is read or stored. The tool does not read access logs.

### What the README must say about the firewall

The README has a section near the top, "Lock the origin to Cloudflare",
that says:

1. Real-IP only changes what nginx believes about connections that come
   from Cloudflare's ranges. Connections from anywhere else keep their own
   address, so a correct snippet cannot be spoofed through the header by
   a direct visitor. But a direct visitor still bypasses the WAF, edge rate
   limits, bot rules and DDoS protection. And one wrong step (an
   over-wide `set_real_ip_from`, an application that reads
   `CF-Connecting-IP` itself, a log format that logs the header instead of
   `$remote_addr`) turns direct access into address spoofing.
2. So accept ports 80 and 443 only from Cloudflare's ranges, at the host
   firewall or the cloud provider's security group, and keep SSH on its own
   rule. Short worked examples for ufw, nftables and a cloud security
   group, in prose and commands the operator runs by hand, using the same
   published lists.
3. The firewall list goes stale like the snippet does. Refreshing it is a
   separate job, out of scope here, and the README says so. A refresh that
   only adds ranges never removes retired ones.
4. Traps: closing port 80 to the world breaks HTTP-01 certificate renewal
   silently, months later; switch to DNS-01 or a Cloudflare origin
   certificate first. Leaving IPv6 open while closing IPv4 leaves the
   origin exposed.
5. Cloudflare's ranges are shared by every Cloudflare customer, so an
   allowlist stops the open internet but not traffic sent through someone
   else's Cloudflare account. For that, use Authenticated Origin Pulls
   (mutual TLS) or Cloudflare Tunnel; both are linked, neither is
   configured by this tool.
6. If Pseudo IPv4 is set to "Overwrite Headers" in Cloudflare, the client
   address for IPv6 visitors will be a pseudo address from 240.0.0.0/4 [R3].

## 9. Performance budget

- Two HTTPS GETs of under 1 KiB each per run. One run a day.
- A normal run finishes in under 5 s; the worst case is bounded by
  attempts times total timeout per list (default about 3 minutes).
- Memory: whatever bash and curl need; no list is held twice beyond the
  candidate and the live file.
- Reloads happen only on change. Cloudflare's lists changed a handful of
  times between 2017 and 2023 [R1], so expect very few reloads a year.
  Reload is graceful in nginx; no request is dropped.
- Tests: the bats suite runs in under 30 s on a laptop with no network.

## 10. Compatibility

- bash 4.2 or later, coreutils, curl 7.52 or later, `flock` (util-linux),
  `logger`, `diff`. No Python, no jq. On Alpine the README lists the
  packages to add.
- nginx 1.18 or later with `ngx_http_realip_module` built in (it is in the
  Debian, Ubuntu, RHEL, nginx.org and OpenResty builds; it is not built by
  default from source [R4]). Also works with any nginx that supports
  IPv6 CIDRs in `set_real_ip_from`.
- Include layouts: Debian and Ubuntu (`conf.d/*.conf` and
  `sites-enabled/*`), nginx.org packages (`conf.d/*.conf`), RHEL
  (`conf.d/*.conf`), OpenResty (path differs; set the output path).
- Init systems: systemd, or cron on anything else.
- SELinux enforcing on RHEL 9 must pass W2 (W8 is what makes it work).
- Containers: bind mount the snippet from the host and run the tool on the
  host, or run it as a side job with the reload command overridden. Not
  packaged.

## 11. Observability

- One summary line per run on stdout and in syslog, for example:
  "updated: 15 IPv4, 7 IPv6 (+1 -0), nginx reloaded" or "unchanged: 15
  IPv4, 7 IPv6". Warnings and errors go to syslog at the matching priority
  (`warning`, `err`).
- Every added or removed range is logged on its own line.
- Errors quote what failed: URL and status, content type, the first
  offending line number (not the whole body), nginx's own error text.
- `--status` and `--verify` (X1, X4) for a human or a monitoring check.
  `--diff` exit code 10 for "a change is waiting".
- The systemd unit's result is visible in `systemctl status` and the
  journal. The README shows the one command that answers "when did this
  last succeed".
- No log file of its own. Cron output is not redirected to a file that
  each run overwrites.

## 12. Acceptance tests

All tests use bats. Network and system commands are replaced by shims on
`PATH` that record their arguments and return canned results: a fake
`curl` that serves fixture files with a chosen status, content type and
exit code; a fake `nginx` whose `-t` and `-T` results are set per test; a
fake `systemctl`; a fake `sudo`. Tests run in a temporary root (output
path, state directory, config file all under it). Addresses in fixtures
are Cloudflare's real published ranges as of the fixture date, plus
documentation ranges for bad cases.

Fixtures (under `test/fixtures/`): `v4-ok.txt` and `v6-ok.txt` (real lists,
no trailing newline); `v4-crlf.txt`; `v4-bom.txt`; `v4-blank-lines.txt`;
`v4-dupes.txt`; `v6-mixed-case.txt`; `empty.txt`; `whitespace.txt`;
`html-challenge.html`; `json.txt`; `csv.txt`; `v4-with-v6.txt`;
`v4-bad-octet.txt`; `v4-leading-zero.txt`; `v4-no-prefix.txt`;
`v4-host-bits.txt`; `v4-truncated-mid-line.txt`;
`v4-truncated-between-lines.txt`; `v4-slash8-floor.txt`;
`v4-default-route.txt`; `v4-private.txt`; `v6-ula.txt`;
`v4-too-few.txt`; `v4-too-many.txt`; `v4-half.txt`; `v4-plus-one.txt`;
`oversize.txt`; `hand-written-snippet.conf`.

| Case | Test (file: name) |
|---|---|
| 4.1 | run_order.bats: steps stop at first failure, nothing after it runs |
| F1 | fetch.bats: normal lists render the expected snippet |
| F2 | fetch.bats: connect timeout retried 3 times then exit 2 untouched |
| F3 | fetch.bats: total timeout retried then exit 2 untouched |
| F4 | fetch.bats: DNS failure exit 2 untouched |
| F5 | fetch.bats: TLS failure not retried, exit 2 untouched |
| F6 | fetch.bats: 404 not retried; 429 and 503 retried; exit 2 untouched |
| F7 | fetch.bats: curl partial-transfer error exit 2; truncated fixtures exit 3 |
| F8 | fetch.bats: empty and whitespace-only bodies exit 3 |
| F9 | fetch.bats: oversize body aborted, exit 3 |
| F10 | fetch.bats: HTML and JSON content types exit 3, body not logged |
| F11 | fetch.bats: JSON-in-text and CSV fixtures exit 3 |
| F12 | fetch.bats: HTTPS to HTTP redirect refused; off-host redirect refused |
| F13 | config.bats: http URL is exit 1 with no curl call recorded |
| F14 | config.bats: off-host URL exit 1; allowed with pinning off and warns |
| F15 | fetch.bats: proxy variables reach the curl shim |
| F16 | fetch.bats: v4 ok and v6 failing writes nothing; reverse too |
| F17 | parse.bats: last range without newline is kept (15 and 7 counted) |
| F18 | parse.bats: CRLF, BOM, blank lines and spaces tolerated |
| V1 | validate.bats: IPv6 entry in IPv4 list exit 3 |
| V2 | validate.bats: bad octet, leading zero, no prefix, bad IPv6 forms exit 3 |
| V3 | validate.bats: /7 IPv4 and /15 IPv6 exit 3; /8 and /16 pass |
| V4 | validate.bats: default route, private, ULA, loopback each exit 3 |
| V5 | validate.bats: host bits set exit 3 |
| V6 | validate.bats: mixed-case IPv6 renders the same as lower-case |
| V7 | validate.bats: duplicates removed with a warning |
| V8 | validate.bats: too few and too many exit 3 |
| V9 | render.bats: shuffled input renders identical output |
| V10 | validate.bats: half list refused exit 3; accepted with --force; +1 accepted |
| V11 | validate.bats: private extra address accepted in its own block |
| R1 | render.bats: default output matches golden file |
| R2 | render.bats: X-Forwarded-For golden file |
| R3 | render.bats: recursive line present; warning with CF-Connecting-IP |
| R4 | config.bats: header with a space or semicolon exit 1 |
| R5 | render.bats: two renders byte-identical, no timestamp |
| R6 | integration.bats: snippet included at http, server and location passes real nginx -t |
| W1 | write.bats: unchanged run does no write, no backup, no reload |
| W2 | write.bats: changed run writes, backs up, tests, reloads once |
| W3 | write.bats: candidate test failure deletes temp, exit 4 untouched |
| W4 | write.bats: full test failure restores backup, no reload, exit 4 |
| W5 | write.bats: reload failure exit 5, file kept, next run retries reload |
| W6 | write.bats: nginx stopped writes file, no reload, exit 0 |
| W7 | write.bats: unwritable temp exit 1 untouched |
| W8 | write.bats: temp file in target dir, dot-named, removed on TERM |
| W9 | write.bats: output mode 0644 |
| W10 | write.bats: symlink target exit 1 |
| W11 | write.bats: hand-written snippet refused; replaced with --force |
| W12 | write.bats: second run while locked exit 6 |
| W13 | write.bats: warning when nginx -T does not mention the path |
| W14 | write.bats: leftover in-progress state triggers test and restore |
| FR1 | firstrun.bats: no snippet, write succeeds; test failure leaves no file |
| FR2 | firstrun.bats: diff shows whole file added, exit 10 |
| FR3 | firstrun.bats: missing target dir exit 1 |
| FR4 | firstrun.bats: state dir created as root; exit 1 as non-root |
| P1 | perms.bats: root run calls no helper |
| P2 | perms.bats: non-root run calls helper for exactly the four commands |
| P3 | perms.bats: non-root without helper never runs full test |
| P4 | perms.bats: sudo asking for a password fails preflight exit 1 |
| P5 | integration.bats: run under the shipped unit's sandbox settings |
| RB1 | rollback.bats: swap, test, reload; second rollback undoes the first |
| RB2 | rollback.bats: no backup exit 1 |
| RB3 | rollback.bats: timer run held; --release clears; expiry warns and proceeds |
| RB4 | rollback.bats: backup is in the state dir only |
| D1 | modes.bats: dry run prints snippet, changes nothing, no reload |
| D2 | modes.bats: diff exit 0 when same, 10 when different |
| D3 | modes.bats: neither mode writes state or calls reload |
| D4 | modes.bats: dry run as non-root with readable snippet works |
| X1 | verify.bats: each check fails on its own fixture |
| X2 | docs check: README contains the log format and trace steps |
| X3 | docs check: README contains the spoof check |
| X4 | status.bats: stale success shows a warning |
| I1 | install.bats: fresh install in a temp root; existing config kept, .new written |
| I2 | install.bats: no systemd installs the cron file |
| I3 | install.bats: second install changes nothing |
| I4 | install.bats: uninstall leaves snippet and config, removes the rest |
| I5 | install.bats: purge removes snippet; restored if nginx -t fails |
| 4.12 | covered by the rows above |

Integration tests (`integration.bats`) run real nginx in CI (the GitHub
runner's distribution package) with the curl shim still in place. A
separate scheduled CI job runs `--dry-run --test` against the live
endpoints once a week and opens an issue if it fails, so a change in
Cloudflare's format is seen before users see it. shellcheck runs on every
shell file in CI.

## 13. Open questions

Answered by the builder in `docs/ARCHITECTURE.md`.

1. Pure bash CIDR and IPv6 validation, or an optional helper such as
   `ipcalc` when present? This PRD assumes pure bash with no extra package.
2. Candidate syntax test (step 9): the exact minimal config, and how to run
   it without writing to the real pid file and error log (prefix, `-g`
   overrides, or a scratch directory).
3. Should IPv6 be optional (a flag to skip the IPv6 list) for origins with
   no IPv6 at all? This PRD says no: trusting ranges you never see costs
   nothing, and skipping them breaks the day IPv6 is added.
4. Should the tool emit a Prometheus textfile metric (last success time,
   counts) when a directory is configured?
5. Is the shrink guard default of 50 percent right, or should any removal
   need `--force`?
6. Does nginx's include glob skip dot files on every supported platform?
   W8 depends on it; the integration test must prove it.
7. Should the tool also offer, as a read-only check, a comparison against
   Cloudflare's public JSON listing? It is excluded here as a Cloudflare API
   call.

## 14. Lessons from production

1. Test before you install. Never put an untested file at the live path; a
   broken snippet left in place breaks the next reload, whoever triggers it.
2. Reload only when the bytes changed, and keep timestamps out of the file
   so that "changed" means something.
3. Validate both families. Checking the IPv4 count alone lets a bad IPv6
   list through.
4. A line containing a slash is not a CIDR. Check syntax, family, prefix
   floor and host bits.
5. The published lists end without a trailing newline. A line-reading loop
   that needs one drops the last range.
6. The lists' `Last-Modified` header differs between consecutive fetches,
   so it is useless for change detection. Compare content.
7. Keep firewall changes out of this tool. An "add only" firewall refresh
   bolted onto the same script never removes retired ranges and grows the
   blast radius of a bad fetch.
8. Do not send cron output to a log file each run overwrites. Log to syslog
   and alarm on staleness, or a dead job looks exactly like a healthy one.
9. Restore the real address once, at the `http` level, before any
   `limit_req_zone`, `geo` or `map` keyed on the client address. Otherwise
   rate limits and blocklists match the edge, not the attacker.
10. Real-IP does not hide the origin. If port 443 answers the whole
    internet, Cloudflare is optional for an attacker. Lock it at the
    firewall.
11. Closing port 80 to non-Cloudflare traffic silently breaks HTTP-01
    certificate renewal. Move to DNS-01 or an origin certificate first.
12. Make temp files in the target directory, not `/tmp`: a cross-filesystem
    move is not atomic, and on SELinux hosts it carries the wrong label.
13. `nginx -t` as an unprivileged user fails on root-only TLS keys. Plan
    the privilege model before the first non-root run, not after.
14. Pick install paths once and keep them. Timers and cron entries refer to
    them by absolute path, and moving one breaks a job quietly.

## References

- [R1] Cloudflare, "IP Ranges": https://www.cloudflare.com/ips/ (lists the
  text endpoints and the change history; 15 IPv4 and 7 IPv6 ranges as of
  11 November 2026).
- [R2] Cloudflare text lists: https://www.cloudflare.com/ips-v4 and
  https://www.cloudflare.com/ips-v6 (`text/plain`, no trailing newline).
- [R3] Cloudflare, "Restoring original visitor IPs":
  https://developers.cloudflare.com/support/troubleshooting/restoring-visitor-ips/restoring-original-visitor-ips/
  (nginx realip example, `CF-Connecting-IP` or `X-Forwarded-For`, Pseudo
  IPv4 note, advice to accept only Cloudflare addresses).
- [R4] nginx, "Module ngx_http_realip_module":
  https://nginx.org/en/docs/http/ngx_http_realip_module.html
  (`set_real_ip_from`, `real_ip_header`, `real_ip_recursive`,
  `$realip_remote_addr`; not built by default from source).
- [R5] Cloudflare, Authenticated Origin Pulls:
  https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/
- [R6] Cloudflare Tunnel:
  https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
- [R7] RFC 5952, "A Recommendation for IPv6 Address Text Representation".
