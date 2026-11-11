# Security policy

This tool decides which addresses nginx trusts to report the visitor's
address. A bug that widens that list, writes an untested file, or runs
something it should not is a security bug.

## Reporting

Email **hello@indianopinion.org** with a description, the version
(`cloudflare-realip-nginx --version`) and steps to reproduce. Please do not
open a public issue for a security problem.

We acknowledge reports within 3 working days and aim to ship a fix or a
mitigation within 30 days, sooner for anything that widens trust. We will
credit you in the release notes unless you ask us not to.

## Supported versions

Only the latest release receives security fixes.

## Scope notes

- The tool never touches a firewall. An origin that answers the whole
  internet can be reached around Cloudflare; see the README section "Lock
  the origin to Cloudflare".
- The config file is parsed as data. Reports of code execution through it
  are in scope.
