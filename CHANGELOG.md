# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-11

### Added

- `cloudflare-realip-nginx`: fetches Cloudflare's IPv4 and IPv6 lists over
  HTTPS with retries, redirect checks and host pinning; validates syntax,
  family, host bits, never-trusted space, prefix floor, counts and shrink;
  renders a deterministic nginx real-IP snippet; tests the candidate alone,
  installs it by atomic rename, runs the full `nginx -t`, restores on
  failure, and reloads only on change.
- Modes: update, `--dry-run` (with `--test`), `--diff` (exit 10 on change),
  `--rollback` with a hold and `--release`, `--verify`, `--status`.
- Options for `X-Forwarded-For` or another header, `real_ip_recursive`, and
  extra trusted addresses in their own block.
- Non-root operation through `sudo -n` for four fixed commands, with a
  sudoers example.
- State file, `flock` locking, recovery from an interrupted run, staleness
  warning, syslog logging, optional Prometheus textfile metrics.
- Hardened systemd service and daily timer, cron and busybox periodic
  templates, and `install.sh` with `--uninstall` and `--purge`.
- bats suite with stand-in commands, integration tests against real nginx,
  and CI with shellcheck, containers and a weekly live check.

[Unreleased]: https://github.com/IndianOpinion/cloudflare-realip-nginx/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/IndianOpinion/cloudflare-realip-nginx/releases/tag/v0.1.0
