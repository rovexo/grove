# Changelog

## 0.2.2 — 2026-08-11

- **`status` now checks WHERE the wildcard points, not just that it resolves.** A home connection's
  WAN address moves; when it does the record keeps resolving perfectly to an address that is no
  longer yours, and every public URL on the zone dies from the outside while this machine still looks
  healthy — valid certificate, Caddy serving, local names fine. A silent, total outage that presents
  as nothing at all. Found by setting up a second zone next to one that had been stale for a while.
- The worktree note warns that a file can be in HEAD before it is on disk: the checkout fills in
  behind a session, and on a synced stack the container's view lags the host's. An edit failing with
  "file does not exist" for something HEAD clearly has is that, not a broken worktree.
- The formula is a plain archive URL again — the repository is public, so no token and no auth header.

## 0.2.1 — 2026-08-10

Found by standing the whole tool up on a second zone (dev.configbox.at) with a real app on it.

- **`sudo grove publish-timer`** — status told you to run this and it was not a command. The renewal
  timer genuinely needs root (a LaunchDaemon), but it is per ZONE and needed once ever, so splitting
  it out lets rootless mode keep its no-sudo story for everything else.
- **The worktree is told its own database and URL.** `DB`, `URL` and `LOCAL_URL` join `.grove-meta`.
  A platform profile rewrites the config file it knows; a plain project has none, and without this it
  serves its own docroot out of the main database — isolation that is not.
- `status` no longer says "run `sudo grove publish`" where rootless mode is active and no sudo is
  needed, and no longer reports rootless mode unavailable because the admin API took longer than two
  seconds to answer on a busy machine.
- The Homebrew formula fetches through the API, since the repository is private and Homebrew does not
  authenticate against plain archive URLs — and current Homebrew has dropped the private-repo
  download strategies that used to cover it.

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
