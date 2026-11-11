# Contributing

Thank you for helping. Bug reports, fixes and documentation improvements are
all welcome.

## Setup

You need bash 4.2 or later, coreutils, curl, util-linux (`flock`),
[bats-core](https://github.com/bats-core/bats-core) 1.5 or later and
[shellcheck](https://www.shellcheck.net/). nginx is only needed for the
integration tests.

```sh
git clone https://github.com/IndianOpinion/cloudflare-realip-nginx.git
cd cloudflare-realip-nginx
```

## Tests

```sh
bats tests                                   # unit suite, no network, no nginx
CFRN_INTEGRATION=1 bats tests/integration.bats   # needs a real nginx
shellcheck -x bin/cloudflare-realip-nginx install.sh examples/*.sh tests/helpers/shims/*
```

The unit suite replaces curl, nginx, systemctl, sudo, id, logger and mktemp
with stand-ins from `tests/helpers/shims`. Each stand-in records its call in
`$SHIM_DIR/calls.log` and takes its result from environment variables
documented at the top of the file. `examples/offline-demo.sh` shows them in
action. Every test runs in its own temporary root.

The integration tests only ever run `nginx -t` and `nginx -T` against
throwaway configurations; they never reload a running nginx.

Every behaviour case in `docs/PRD.md` section 4 has a test. A change in
behaviour needs a test that fails without it.

## Style

- bash with `set -euo pipefail`, tabs for indentation, shellcheck clean.
- No `eval`, no sourcing of configuration, no command built from a string.
  Commands are arrays.
- Quote every expansion. Prefer parameter expansion to subshells in loops.
- Messages: short, plain, British spelling, no em dashes. Say what failed
  and what to do next.

## Pull requests

- One change per pull request, with tests and a CHANGELOG entry under
  Unreleased.
- CI must be green.
- The snippet's first line is a contract (`docs/ARCHITECTURE.md`); do not
  change it in a minor release.
- A sign-off line (DCO) is not required.
