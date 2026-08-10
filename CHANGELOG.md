# Changelog

## 0.1.0 — 2026-08-10

First release. Extracted from cbx-joomla, where the design was built and proven in use.

- `grove status` / `cert` / `install`.
- One wildcard certificate per **zone**, shared by every project under it — a second project issues
  nothing and installs no timer, it registers against what is already there.
- **Rootless mode**: site blocks in a directory you own, applied over Caddy's admin API. After a
  one-time two-line edit to the machine's Caddyfile, no operation needs root.
- Falls back to editing the root Caddyfile where that setup has not been done.
- Bootstraps a machine with no Caddy at all, and joins one that already has it by claiming a host
  matcher inside the existing zone block.
- Config is staged and parsed before it replaces anything live.
- Dependency checks with install hints; macOS-only, enforced at load.
