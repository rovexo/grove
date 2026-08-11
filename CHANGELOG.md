# Changelog

## 0.2.6 — 2026-08-11

Both found by checking the public hostnames end to end after 0.2.5's matcher fix.

- **`publish` now applies a changed slot count.** It saw its own matcher already present and stopped,
  so raising `GROVE_SLOTS` never reached the proxy: the new slots stayed unclaimed and were answered
  by whichever project owns the zone default — a 200 with another project's site. Its own block is
  now stripped and rewritten, making publish idempotent AND able to apply changes.
- **`status` checks that the published slots match the configured ones**, which a code comment had
  claimed for a release without it being true. It names the gap (`wt4…wt5 would answer with whichever
  project owns the zone default`) rather than leaving it to be discovered.

## 0.2.5 — 2026-08-11

Found by standing up a real Magento 2.4.7 store from scratch — composer install, `setup:install`,
OpenSearch, `vendor/` kept out of the file sync — and putting a second project on an already-served
zone. **Multi-project-per-zone had never actually worked**, and its failure was silent.

- **The proxy matcher matched nothing.** Caddy's `host` matcher supports a wildcard only as an entire
  leading label, so `*-project.zone.tld` parses and then matches no request at all: everything fell
  through to whichever project served the zone by default. The second project on a zone answered
  **200 with the first project's site** — a working-looking setup serving the wrong thing. grove now
  enumerates the concrete slot hostnames, which Caddy matches exactly.
- **And it could not have claimed one anyway**: a mid-label wildcard is not a valid certificate
  subject, so `*-project.zone.tld` as a site address is rejected outright — even with the certificate
  supplied explicitly.
- **Site blocks are per ZONE, not per project.** Caddy permits one definition of a site, so two
  projects each owning a file redefined it and the whole config was rejected with "ambiguous site
  definition". Existing installs are migrated by finding the file that defines the zone and renaming
  it; projects then share that block and add matchers to it.
- **A project could not see the other projects on its machine.** The config reader took the machine
  Caddyfile plus the project's OWN site file — so a second project could not tell the zone was
  already served, and generated a colliding block. It now reads every imported site file.
- **A profile can act on what the platform keeps in its DATABASE**, via a new post-seed hook. Magento
  stores its base URLs there and redirects anything that does not match: a worktree inherited the main
  store's local hostname and answered every public request with a 302 to a name that resolves only on
  the machine. Up and unreachable at once.
- **Magento static assets 404'd.** `pub/static` is an `empty` path, so every asset is generated on
  demand by `static.php` — which wants the resource without the `/static/` prefix or version segment.
  The locations now follow Magento's own nginx sample.

## 0.2.4 — 2026-08-11

Everything here was found by running the `magento2` profile for the first time, against a checkout
carrying a real 79,252-file `vendor/`. The profile had never been loaded before; three of these four
bugs make it useless on Magento specifically, and every one of them is invisible with a single
`container` path.

- **`GROVE_APP_ROOT`.** Magento is not always at the repository root — one project here is the Magento
  checkout, another keeps it under `docroot/`. Every profile path now hangs off that prefix. Without
  it the profile looked for an `app/etc/env.php` that does not exist and copied a `vendor` that does
  not exist. The concept's "they differ only in docroot" was simply wrong.
- **Only the first `container` path was ever copied.** `ddev exec` reads stdin, and the loop feeds its
  list in on stdin — so the exec swallowed the remaining paths and the loop ended after one. Magento
  always has two (`vendor` and `generated`), so this broke exactly the platform the strategy exists
  for, while working perfectly with one path.
- **The sync-ignore splice silently did nothing with more than one path.** `awk -v` cannot carry an
  embedded newline; it aborts with "newline in string". Same shape as above: fine with one path,
  broken with two.
- **A tracked platform config file made every worktree permanently dirty**, so the remove hook would
  never release the slot. Profiles now declare the file they rewrite, and grove never counts its own
  rewrite as the session's work. (All three real projects gitignore it, so this was latent.)
- The magento2 profile also rewrites Redis/cache `id_prefix` per worktree — two Magento sites sharing
  a prefix read each other's cached configuration.

Measured, since the design rested on an unmeasured claim: a host-side CoW clone of 79k files is
**52-60s**, not "instant" — copy-on-write shares the data but still creates 79k inodes. The
container-side copy is **45s** for the same tree. Comparable up front; the difference is that the
container copy adds nothing to the sync's watch set, per worktree, for the worktree's life.

## 0.2.3 — 2026-08-11

**The renewal timer has never renewed anything.** It called `$PROJECT_ROOT/grove cert` — a path from
when grove was a script inside the project. Once it became an installed binary that path stopped
existing, and the failure took the worst possible shape: the timer fires nightly, the command is not
found, and nothing else happens. Both zones on this machine were on course to serve expired
certificates in November with no warning anywhere. Found by checking what the timer actually runs,
after installing one.

- The renewal script now calls the real binary (resolved at write time, preferring the wrapper on
  PATH) and passes `GROVE_PROJECT_ROOT` — without which a LaunchDaemon starting in `/` cannot find a
  `.grove.conf` and so cannot tell which zone it is renewing.
- It refuses loudly rather than silently if that binary is gone.
- `status` verifies the whole chain — plist, script, and the binary the script calls — because a
  timer that exists is not a timer that works.
- Repairing a timer needs no root: the daemon is root's, but the script it runs is yours. It is
  replaced rather than overwritten, since a root-installed script cannot be written through by its
  owner — only unlinked and rewritten — and it is handed back to you afterwards.
- Writing that script is now checked. An earlier version reported success over a failed write.

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
