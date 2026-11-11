# cloudflare-realip-nginx

Keeps nginx's real-IP trust list in step with Cloudflare's published IPv4 and IPv6 ranges, so nginx, your logs and your rate limits see the visitor's address instead of a Cloudflare edge. It fetches both lists over HTTPS, checks them strictly, tests the new snippet with nginx before installing it, swaps it in atomically, and reloads nginx only when the content changed.

Measured result: on the origin this tool came out of, the login rate limit turns away about 1,300 brute-force attempts a day from a single address; keyed on the edge address instead, those attempts would share a bucket with every reader coming through the same Cloudflare data centre.

This project came out of the work on indianopinion.org and is written from scratch; it is independent of and not affiliated with any third-party plugin it integrates with.

## Contents

- [Lock the origin to Cloudflare](#lock-the-origin-to-cloudflare)
- [Install](#install)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Prove it works](#prove-it-works)
- [Running without root](#running-without-root)
- [Rollback](#rollback)
- [Limitations](#limitations)
- [FAQ](#faq)
- [Licence](#licence)

## Lock the origin to Cloudflare

Read this before anything else.

1. Real-IP only changes what nginx believes about connections that come from Cloudflare's ranges. Connections from anywhere else keep their own address, so a correct snippet cannot be spoofed through the header by a direct visitor. But a direct visitor still skips the WAF, edge rate limits, bot rules and DDoS protection. And one wrong step turns direct access into address spoofing: an over-wide `set_real_ip_from`, an application that reads `CF-Connecting-IP` itself, or a log format that logs the header instead of `$remote_addr`.
2. So accept ports 80 and 443 only from Cloudflare's ranges, at the host firewall or the cloud provider's security group. Keep SSH on its own rule. Examples below; you run them by hand. `examples/firewall-commands.sh ufw` (or `nft`) prints the commands for today's lists without running anything.
3. The firewall list goes stale like the snippet does. Refreshing it is a separate job and out of scope here; this tool never touches a firewall. A refresh that only adds ranges never removes retired ones, so rebuild the whole set each time.
4. Traps:
   - Closing port 80 to the world breaks HTTP-01 certificate renewal (for example certbot's default) silently, months later, when the certificate expires. Switch to DNS-01 or a Cloudflare origin certificate first.
   - Closing IPv4 while leaving IPv6 open leaves the origin exposed. Do both families.
5. Cloudflare's ranges are shared by every Cloudflare customer. An allowlist stops the open internet, but not traffic sent through someone else's Cloudflare account. For that, use [Authenticated Origin Pulls](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/) (mutual TLS) or [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/). This tool configures neither.
6. If Pseudo IPv4 is set to "Overwrite Headers" in Cloudflare, IPv6 visitors arrive with a pseudo address from `240.0.0.0/4` ([Cloudflare docs](https://developers.cloudflare.com/support/troubleshooting/restoring-visitor-ips/restoring-original-visitor-ips/)).

**ufw** (Ubuntu, Debian):

```sh
# keep SSH first
ufw allow OpenSSH
for r in $(curl -fsS https://www.cloudflare.com/ips-v4) $(curl -fsS https://www.cloudflare.com/ips-v6); do
  ufw allow proto tcp from "$r" to any port 80,443 comment cloudflare
done
ufw status numbered   # then delete any "80", "443" or "Nginx Full" ALLOW Anywhere rule
```

**nftables**: `examples/firewall-commands.sh nft` prints a table with two interval sets (`cf4`, `cf6`) that accepts 80 and 443 from them and drops the rest. Load it with `nft -f`.

**Cloud security group** (AWS, GCP, Azure and so on): one inbound rule per range for TCP 80 and 443, for both lists, and no `0.0.0.0/0` or `::/0` rule on those ports. Keep SSH on a separate rule limited to your own address.

## Install

Needs bash 4.2 or later, coreutils, curl 7.52 or later, `flock` (util-linux), `logger`, `diff`, and nginx 1.18 or later with `ngx_http_realip_module` (built in on Debian, Ubuntu, RHEL, nginx.org and OpenResty packages; not built by default from source). No Python, no jq.

On Alpine: `apk add bash curl flock nginx`.

With systemd (Debian, Ubuntu, RHEL and rebuilds):

```sh
git clone https://github.com/IndianOpinion/cloudflare-realip-nginx.git
cd cloudflare-realip-nginx
sudo ./install.sh
```

The installer copies the tool to `/usr/local/sbin`, the config to `/etc/default/cloudflare-realip-nginx` (an existing config is kept; the new default goes next to it as `.new`), the units to `/etc/systemd/system`, creates the state directory, runs `--dry-run --test`, and only then enables the timer. Running it again changes nothing and says so.

| Flag | Effect |
|---|---|
| `--no-timer` | Install, but do not enable the timer |
| `--cron` | Install `/etc/cron.d/cloudflare-realip-nginx` instead of the timer |
| `--prefix DIR` | Put the tool in `DIR/sbin` (default `/usr/local`) |
| `--destdir DIR` | Stage everything under `DIR` (packaging); service commands are skipped |
| `--uninstall` | Remove the tool, units, cron file and lock; keep the snippet, backup and config |
| `--uninstall --purge` | Also remove the snippet, state and config, test nginx and reload |

Without systemd (Alpine, containers) the installer uses `/etc/cron.d`, or `/etc/periodic/daily` for busybox crond, and says so. The run time is picked at random so a fleet does not hit Cloudflare at the same second.

Uninstall leaves the snippet in place on purpose: removing it changes every logged client address at the next reload, so that is a separate, deliberate step (`--purge`). If another file still includes the snippet by path, `--purge` finds that `nginx -t` fails, puts the snippet back and tells you to remove the include first.

Without the installer: copy `bin/cloudflare-realip-nginx` anywhere on root's `PATH`, create `/var/lib/cloudflare-realip-nginx` (mode 0750), and schedule `cloudflare-realip-nginx --quiet` once a day.

Containers are not packaged. Run the tool on the host and bind mount the snippet into the container, or run it as a side job with `CFRN_RELOAD_COMMAND` set to whatever reloads your nginx.

## Quick start

```sh
cloudflare-realip-nginx --dry-run          # fetch, validate, print the snippet; change nothing
cloudflare-realip-nginx --dry-run --test   # also run nginx's syntax test on it
cloudflare-realip-nginx --diff             # unified diff against the live snippet; exit 10 if different
sudo cloudflare-realip-nginx               # update: write, test, reload if changed
cloudflare-realip-nginx --status           # last run, last success, counts, hash
sudo cloudflare-realip-nginx --verify      # one line per check, exit 0 only if all pass
```

The default output, `/etc/nginx/conf.d/cloudflare-realip.conf`, is included inside `http { }` by the Debian, Ubuntu, RHEL and nginx.org packages already. Check with `nginx -T | grep cloudflare-realip.conf`. If it is not included, the tool warns after every write and prints the line to add. Include it once, in the `http` context, before any `limit_req_zone`, `geo` or `map` keyed on the client address (see `examples/nginx-include.conf`).

The snippet looks like this:

```nginx
# Generated by cloudflare-realip-nginx. Do not edit: changes are overwritten.
# Tool: cloudflare-realip-nginx 0.1.0
# Source: https://www.cloudflare.com/ips-v4
# Source: https://www.cloudflare.com/ips-v6
...
# Cloudflare IPv4 ranges
set_real_ip_from 103.21.244.0/22;
...
# Cloudflare IPv6 ranges
set_real_ip_from 2400:cb00::/32;
...
real_ip_header CF-Connecting-IP;
```

When did it last succeed? `cloudflare-realip-nginx --status`, or `journalctl -t cloudflare-realip-nginx -g 'updated|unchanged' -n 1`.

## Configuration

Settings come from `/etc/default/cloudflare-realip-nginx` (plain `KEY=value`, parsed as data and never sourced), then environment variables with the same names, then flags. Later wins. Unknown keys are an error, so a typo stops the run.

| Setting | Default | Notes |
|---|---|---|
| `CFRN_OUTPUT` / `--output` | `/etc/nginx/conf.d/cloudflare-realip.conf` | Absolute path, not a symlink |
| `CFRN_STATE_DIR` | `/var/lib/cloudflare-realip-nginx` | Backup, state file, lock |
| `CFRN_STAGING_DIR` | hidden directory beside the output directory, for example `/etc/nginx/.cloudflare-realip-nginx` | Same filesystem as the output; never the include directory |
| `CFRN_URL_V4` | `https://www.cloudflare.com/ips-v4` | HTTPS only |
| `CFRN_URL_V6` | `https://www.cloudflare.com/ips-v6` | HTTPS only |
| `CFRN_PIN_HOST` | `yes` | URLs and redirects must be on `www.cloudflare.com`; `no` warns every run |
| `CFRN_HEADER` / `--header` | `CF-Connecting-IP` | Letters, digits and hyphens only |
| `CFRN_RECURSIVE` / `--recursive` | `no` | Adds `real_ip_recursive on` |
| `CFRN_EXTRA_TRUSTED` / `--extra-trusted` | none | Space separated CIDRs or `unix:`, own block |
| `CFRN_MIN_COUNT_V4` / `_V6` | `10` / `3` | Fewer ranges fails the run |
| `CFRN_MAX_COUNT` | `200` | Per family |
| `CFRN_MIN_PREFIX_V4` / `_V6` | `8` / `16` | Wider prefixes are refused |
| `CFRN_MAX_SHRINK_PERCENT` | `50` | Larger removals need `--force` |
| `CFRN_CONNECT_TIMEOUT` / `CFRN_TOTAL_TIMEOUT` | `10` / `30` s | Per attempt |
| `CFRN_ATTEMPTS` / `CFRN_RETRY_DELAY` | `3` / `2` s | Delay doubles each retry |
| `CFRN_MAX_BODY_BYTES` | `65536` | Real lists are under 1 KiB |
| `CFRN_NGINX` | `nginx` | Binary |
| `CFRN_TEST_COMMAND` | `nginx -t` | Full test |
| `CFRN_DUMP_COMMAND` | `nginx -T` | Used to check the snippet is included |
| `CFRN_RELOAD_COMMAND` | `systemctl reload nginx`, else `nginx -s reload` | Auto-detected |
| `CFRN_SERVICE_NAME` | `nginx` | For example `openresty` |
| `CFRN_SERVICE_MANAGER` | `auto` | `systemd` or `none` (then `CFRN_PID_FILE` tells whether nginx runs) |
| `CFRN_PID_FILE` | `/run/nginx.pid` | |
| `CFRN_PRIV_HELPER` | `auto` | None as root, `sudo -n` otherwise; `none` to disable |
| `CFRN_STALE_DAYS` | `14` | Warn when the last success is older |
| `CFRN_HOLD_DAYS` | `7` | Hold after `--rollback` |
| `CFRN_SYSLOG` / `--no-syslog` | `yes` | |
| `CFRN_SYSLOG_TAG` | `cloudflare-realip-nginx` | |
| `CFRN_METRICS_DIR` | empty (off) | Writes `cloudflare_realip_nginx.prom` for node_exporter's textfile collector |

Other flags: `--force` (allow a large shrink, or replace a snippet this tool did not write), `--quiet` (print only warnings and errors), `--config FILE`.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Success: updated, unchanged, nginx stopped, or held after rollback |
| 1 | Usage, configuration, permission or local write error; `--verify` found a failure |
| 2 | Fetch failure |
| 3 | Validation failure |
| 4 | nginx configuration test failed; previous state restored |
| 5 | Reload failed; the new, valid snippet stays and the next run retries the reload |
| 6 | Another run holds the lock |
| 10 | `--diff` only: differences found |

### Other headers

`X-Forwarded-For`: Cloudflare appends to any `X-Forwarded-For` the visitor sent. Without `real_ip_recursive on`, nginx takes the last entry, which is the address Cloudflare saw. With it, nginx walks back past trusted addresses. Prefer `CF-Connecting-IP`, which carries exactly one address; `--recursive` has no effect with it and the tool says so. `True-Client-IP` (Enterprise) works with `--header True-Client-IP`.

## How it works

Every run does these steps in order and stops at the first failure:

1. Read and validate settings. Take an exclusive `flock` in the state directory (a second run exits 6 at once).
2. Preflight: nginx found, target directory exists, not a symlink, writable (or the helper allows the four commands).
3. Fetch the IPv4 list, then the IPv6 list. HTTPS only, certificate checks always on, at most 3 redirects, HTTPS to the pinned host only, size capped. Timeouts, DNS errors, 429 and 5xx are retried with backoff; TLS errors and other 4xx are not.
4. Validate both lists. `text/plain` only. Each line must be a CIDR of the right family with no leading zeros, no host bits set, no overlap with private, loopback, link-local, multicast, documentation, carrier-grade NAT or IPv4-mapped space, no default route, and no prefix wider than the floor. CRLF, a byte order mark, blank lines and surrounding spaces are tolerated; nothing else is. Duplicates are dropped with a warning. IPv6 is written in RFC 5952 form and both lists are sorted, so a reordering by Cloudflare is not a change. Counts must be in bounds, and a run that removes more than half of either family needs `--force`. If either family fails, nothing is written.
5. Render the snippet. No timestamp, so the same lists always give the same bytes.
6. Compare with the live snippet. Identical: log `unchanged`, done, no reload. `--dry-run` and `--diff` stop here.
7. Write the candidate to a dot-named temp file in the staging directory (same filesystem as the snippet, so the rename is atomic and the file gets the right SELinux label; outside the include directory, so no include glob can see it).
8. Test the candidate alone with `nginx -t` in a throwaway configuration (no root needed).
9. Copy the live snippet to the backup in the state directory. Rename the temp file over the live snippet.
10. Run the full `nginx -t`. On failure, put the backup back (or remove the new file on a first run), test again, do not reload, exit 4. If it still fails, the log says the configuration was already broken before this run.
11. Reload nginx (skipped with a notice if nginx is not running). Record the result in the state file and log one summary line, for example `updated: 15 IPv4, 7 IPv6 (+1 -0), nginx reloaded`. Every added and removed range is logged on its own line.

A stale but valid trust list is far safer than a wrong one, so any failure before step 9 leaves the live snippet, the backup and nginx exactly as they were. A run killed between steps 9 and 10 is caught by the next run, which tests first and restores the backup if needed.

Logs go to stdout (warnings and errors to stderr) and to syslog at matching priorities. There is no log file of the tool's own. Under systemd: `journalctl -t cloudflare-realip-nginx`.

More detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Requirements: [docs/PRD.md](docs/PRD.md).

## Prove it works

`--verify` checks that the snippet exists, was written by this tool, is included (`nginx -T`), passes `nginx -t`, and that the last success is within 14 days. `examples/monitoring-check.sh` wraps `--verify` and `--diff` as a Nagios-style check.

Then check a live request:

1. Add the log format from `examples/log-format.conf` to `http { }`:

   ```nginx
   log_format realip_check '$time_iso8601 remote_addr=$remote_addr '
                           'realip_remote_addr=$realip_remote_addr '
                           'cf_connecting_ip="$http_cf_connecting_ip"';
   access_log /var/log/nginx/realip-check.log realip_check;
   ```

2. Find your own public address: open `https://<any proxied hostname>/cdn-cgi/trace` and read the `ip=` line.
3. Request your site through Cloudflare and read the log. `remote_addr` must be your address. `realip_remote_addr` must be a Cloudflare address.

Spoof check. From a host outside Cloudflare, send a request straight to the origin address with a forged header, using a documentation address:

```sh
curl -sk https://ORIGIN_IP/ -H 'Host: example.com' -H 'CF-Connecting-IP: 203.0.113.7'
```

With the firewall in place the connection must fail. Without it, the logged `remote_addr` must be the sender's real address. If `203.0.113.7` appears, real-IP is misconfigured. Look for an over-wide `set_real_ip_from` (another file, or an `--extra-trusted` that covers the internet), or a log format or application that reads the raw `CF-Connecting-IP` header instead of `$remote_addr`.

Remove the check log format afterwards.

## Running without root

Set up a user (here `cfrealip`) that owns `/var/lib/cloudflare-realip-nginx`, install `examples/sudoers` with `visudo -f /etc/sudoers.d/cloudflare-realip-nginx`, and run the tool as that user. It then uses `sudo -n` for exactly four commands with fixed arguments: `nginx -t`, `nginx -T`, `systemctl reload nginx`, and `install -m 0644 /var/lib/cloudflare-realip-nginx/staged.conf /etc/nginx/conf.d/cloudflare-realip.conf`. The candidate syntax test runs without sudo.

The full `nginx -t` is never run without the helper, because it usually fails as non-root: TLS private keys and log files are root-only. If sudo would ask for a password, or does not allow one of the four commands, the run stops at preflight with exit 1 and names the command.

Two differences from a root run: the final copy uses `install`, which is not an atomic rename, and on a failed first run the new file cannot be deleted, so it is replaced by a header-only snippet that trusts nothing (nginx treats it like no file).

The shipped systemd unit runs as root with a sandbox: `ProtectSystem=strict`, write access only to the snippet directory, the staging and state directories and the nginx log and cache directories.

## Rollback

```sh
sudo cloudflare-realip-nginx --rollback   # swap backup and live, nginx -t, reload
sudo cloudflare-realip-nginx --rollback   # again: undoes the first
sudo cloudflare-realip-nginx --release    # let scheduled runs update again
```

A rollback holds scheduled runs (they log `held after rollback` and exit 0 without fetching) until `--release`, or for 7 days, after which runs warn and carry on. Without the hold, the next timer run would undo the rollback. One previous version is kept, in the state directory, never next to the snippet.

## Limitations

- Cloudflare only. It does not fetch other CDNs' lists; add a load balancer with `--extra-trusted`.
- nginx only (including OpenResty). Not Apache, Caddy, HAProxy or Traefik.
- No Cloudflare API calls. The China network ranges are not on the public lists and are not included.
- It never touches a firewall, `nginx.conf`, a server block or a `log_format`. It writes one file.
- IPv6 is always fetched and trusted. Trusting ranges you never see costs nothing, and skipping them breaks the day IPv6 is added.
- No Windows. Containers are documented, not packaged.

## FAQ

**Why not a ten-line cron script?** The usual one writes over the live file before testing it, reloads on every run, checks only the IPv4 count, and accepts any line with a slash in it. Each of those has broken a site somewhere.

**Why does it refuse my snippet?** It only overwrites files whose first line is its own header. Use `--force` once to take over a hand-written file; the old one goes to the backup.

**The list shrank and the run failed with exit 3.** More than half of a family would be removed. Check the diff (`--diff`) and Cloudflare's [IP ranges page](https://www.cloudflare.com/ips/); if it is real, run once with `--force`.

**Is the `Last-Modified` header used?** No. It changes between consecutive fetches, so the tool compares content.

**Does it work with SELinux enforcing?** Yes. The temp file is created on the same filesystem under `/etc/nginx`, so it gets nginx's configuration label and keeps it through the rename.

**The run says the snippet is not included.** nginx does not read it yet. Add `include /etc/nginx/conf.d/cloudflare-realip.conf;` once inside `http { }`.

**Can I run it in a monitoring check?** `--diff` exits 10 when Cloudflare's list changed but the snippet has not, and `--verify` exits 0 only when everything is right.

## Licence

MIT. See [LICENSE](LICENSE).
