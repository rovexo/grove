# Changelog

## 0.2.0 — 2026-08-10

grove absorbs worktree management. The lifecycle that lived in four projects — slot allocation,
per-worktree database and vhost, the create/remove hooks — is now the package's, driven by one
declarative list per project.

- **Every path declares a strategy** — `clone`, `empty`, `link`, `container`, `fresh`, `skip` —
  replacing the two hardcoded lists (things to copy, things to create) every implementation carried.
  Last entry per path wins, so a project overrides one line of a profile with one line.
- **Profiles**: `joomla`, `wordpress`, `magento2`, `plain`. Shell files sourced before the project's
  `.grove.conf`, so overriding is assignment and extending is `+=` — no merge semantics to invent.
- **Derived, not configured**: the sync-ignore list comes from whichever paths say `container`, the
  vhost from the docroot, the hostname list from the slot count. `grove wire` writes them.
- **Hook entry points** — `grove hook create|remove|context|on-edit` — because a session never types
  `grove create`: the tool is fired by Claude Code and has to tell the session where it landed.
- `grove create list info shell provision sync-db merge remove prune-merged wire`.
- The public half no longer requires a zone or an ACME email from a project that only wants
  worktrees. `grove status` now reads the imported site file too, so rootless mode stopped reporting
  a missing site block for a project that was serving fine.
- Paths grove creates are written into the repository's local git excludes, and `merge` refuses to
  carry one across — without both, a `link` path committed by `git add -A` replaces the main
  checkout's real directory with a symlink pointing at itself.
- Container-side copies are purged when a worktree is released and before a slot is reused: the file
  sync cannot delete what it has been told to ignore, so it strands the whole worktree otherwise.

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
