# Concept: grove takes over worktree management

> Status: **built and shipped in grove 0.2.** This document is kept as the design record — the
> reasoning behind the strategies is still the best explanation of why the code looks the way it
> does. Section 8 records what building it changed.

Today grove owns the *public* half — one wildcard per zone, one proxy block per project. The worktree
half lives in each project, and it has been copy-pasted four times: cbx-joomla, cbx-wordpress,
cbx-magento and efka-configurator all solve the same problem, have already diverged (cbx-joomla and
cbx-wordpress are 223–381 diff lines apart on files that started identical), and every fix has to be
made four times or forgotten three times.

This absorbs it.

---

## 1. The idea: every path declares HOW it exists, not whether it is copied

The four projects differ in a small, enumerable way: **which directories a worktree gets, and how
each one comes to be there**. Every existing implementation encodes that as two hardcoded lists — one
of things to `cp`, one of things to `mkdir` — and then bolts exceptions onto the side.

Make it one list where each entry names a **strategy**:

| Strategy | What happens | For |
|---|---|---|
| `clone` | copy-on-write clone, host-side (`cp -c`) | uploads, media, product images — big, and free on APFS |
| `empty` | directory created, contents never copied | cache, tmp, logs — inheriting another site's is worse than having none |
| `link` | relative symlink to the main checkout | `node_modules` — identical, huge, read-only in practice |
| `container` | copied **inside** the container, and excluded from file sync | `vendor/`, `generated/` |
| `skip` | not created at all | anything the platform rebuilds on demand |

`container` is the one that earns the design. The Magento requirement — *vendor mutagen-ignored and
copied container-side* — stops being a special case and becomes `vendor: container`. And the sync
exclusion is **derived**, not configured twice: grove writes the mutagen ignore list from whichever
paths declare `container`. You cannot get the two out of step, because there is only one fact.

Why it matters beyond tidiness: a Magento `vendor/` is ~80k files. Cloning it host-side is instant on
APFS but then mutagen has to notice and propagate 80k files into the container — that is the actual
cost, and it is paid on every worktree. Copying it container-side, where it already lives, and telling
the sync to ignore it entirely, removes both the propagation and the ongoing watch overhead.

---

## 2. What a project file looks like

`.grove.conf` at the project root — **sourceable shell, no parser, no dependency**. The same file the
public half already reads, grown a second half rather than gaining a sibling. Paths carry
slashes so they cannot be variable names; a bash array of `path:strategy` pairs handles that without
inventing a syntax.

```sh
# .grove.conf — cbx-magento (worktree half; the public half is in the same file)
GROVE_PROJECT="cbx-magento"
GROVE_ZONE="dev.rovexo.com"
GROVE_UPSTREAM_PORT="33643"

GROVE_PLATFORM="magento2"        # sourced first; everything below overrides it
GROVE_DOCROOT="docroot/pub"      # the only thing efka differs on

GROVE_NAMING="slots"             # slots (wt1…wtN) | free (needs a wildcard local hostname)
GROVE_SLOTS=5
GROVE_PROVISION="lazy"           # lazy = build the site on first file change | eager

GROVE_PATHS+=(
    "vendor:container"           # <- the ask: copied in-container, excluded from sync
    "generated:container"
)

GROVE_DB_SEED="clone"            # clone | empty
GROVE_DB_GRANT="own"             # own = per-worktree user scoped to its schema | shared

GROVE_POST_CREATE+=(
    "bin/magento setup:di:compile"
    "bin/magento cache:flush"
)
```

**Profiles are just shell files, sourced first.** `profiles/magento2.sh` ships with grove and sets the
platform defaults — `pub/media:clone`, `var/cache:empty`, the `app/etc/env.php` rewrite. The project
file is sourced after it, so overriding is ordinary assignment and extending is `+=`. No merge
semantics to specify, no precedence rules to document: **later wins, because that is what shell does.**

For the arrays, grove resolves **last entry per path wins**, so a project can override one line of a
profile without restating the list:

```sh
GROVE_PATHS+=( "vendor:fresh" )   # profile said container; this project wants composer install
```

That is the whole format. It is `source`-able by the existing script, needs nothing installed, and
survives grove staying a single dependency-free file — which is most of why it is easy to install.

## 3. The four projects, side by side

This is the test of whether the abstraction is real.

| | cbx-joomla | cbx-wordpress | cbx-magento | efka-configurator |
|---|---|---|---|---|
| profile | `joomla` | `wordpress` | `magento2` | `magento2` |
| docroot | `docroot` | `docroot` | `docroot/pub` | `pub` |
| config rewritten | `configuration.php` | `wp-config.php` | `app/etc/env.php` | `app/etc/env.php` |
| `clone` | `data/`, `docroot/images` | `wp-content/uploads` | `pub/media` | `pub/media` |
| `empty` | `cache tmp logs`, `administrator/{cache,logs}` | `wp-content/cache` | `var/{cache,log,page_cache}`, `pub/static` | same |
| `container` | — | — | `vendor`, `generated` | `vendor`, `generated` |
| `link` | `tests/node_modules` | `tests/node_modules` | `node_modules` | `node_modules` |
| submodule worktree | `com_configbox` | plugin dir | `cbx/` | — |
| post-create | — | — | `di:compile`, `cache:flush` | same |

Two things this exposes. **The two Magento projects differ only in `docroot`** — so the profile does
almost all the work and efka's file is three lines. And **`container` is empty for the two PHP-app
projects**, which is right: Joomla and WordPress have no build-output directory worth the complexity.
The strategy exists for the case that needs it and costs the others nothing.

---

## 4. Command surface — and who actually calls it

An audit of what the existing tooling exposes, against what an AI session actually invokes, found the
concept's first draft aimed at the wrong caller. **A session never types `grove create`.** Claude Code
fires a `WorktreeCreate` hook; the session is *moved* into a worktree and has to be *told* where it
landed. Five wirings exist in cbx-joomla today and every one of them is machine-triggered:

| Event | Does what |
|---|---|
| `WorktreeCreate` | build the worktree + site. Its stdout **is** the worktree path — nothing else may print |
| `WorktreeRemove` | drop schema, user, vhost, pool, worktree |
| `SessionStart` | tell the session its URL, database and branches |
| `PostToolUse[EnterWorktree]` | same, for a background session moved mid-flight (no SessionStart fires) |
| `PostToolUse[Edit|Write]` | build the site on first file change, when provisioning is lazy |

So grove ships **hook entry points**, and a project wires those into `settings.json` instead of
carrying five scripts:

```
grove hook create | remove | context | on-edit
```

That is the interface that matters. The CLI below is the human one.

```
grove create <name>          branch + worktree + site.   No sudo. No prompts.
grove list                   worktrees: branch, URL, database, idle time
grove info <name>            paths, URL, schema, table count, commits ahead
grove shell <name> [cmd]     run in that worktree, inside the container
grove provision <name>       give a site-less worktree its site after the fact
grove sync-db <name>         re-seed its schema from the main one
grove merge <name> [--keep]  land the work: merge the branch AND the submodule branch,
                             bump the pointer, then release the slot unless --keep
grove remove <name> [-f]     release without merging
grove prune-merged           delete worktree-* branches whose commits are all merged
grove wire                   write everything section 5 derives, and print the hook wiring
```

`wire` was not in the first draft and had to exist: section 5's derived artifacts are real files in
the project, and something has to write them. It is also the migration entry point — run it once per
project, restart the stack, delete the old scripts.

`merge` and `prune-merged` were missing from the first draft and are the two an agent leans on most —
`merge` is how a session's work gets back, and it is the fiddliest thing in the existing tooling
(submodule branch, pointer bump, refusing while the tree is dirty, stopping cleanly on conflict).
Absorbing it is most of the value; leaving it out would mean every project keeps a script anyway.

### Telling the session where it landed

Worth calling out because it is not a command and it is easy to forget: a worktree nobody knows about
is useless. The existing implementation writes the note **twice** — `WORKTREE-SITE.md` at the worktree
root, and the same content as `CLAUDE.local.md`, which Claude Code auto-loads as project memory. The
second is load-bearing: a session inside a worktree reads that worktree's *committed*
`.claude/settings.json`, so hook config that only exists uncommitted never fires there. grove has to
carry that, or the context hook silently does nothing in exactly the case it exists for.

## 5. What grove derives rather than asks for

The point of one declaration per path is that everything downstream follows from it:

- **The sync ignore list** — every `container` path, written into `.ddev/mutagen/mutagen.yml`.
- **The vhost** — from `docroot` + the profile's rewrite rules, one server block covering all slots.
- **The FPM pool** — on-demand, so an idle worktree costs zero processes.
- **The schema, user and grant** — from `GROVE_DB_SEED` and `GROVE_DB_GRANT`.
- **The container-side copy commands** — `container` paths, executed after the stack is up.
- **The hostnames** — `<name>-<project>.<zone>` publicly, already covered by the wildcard, plus the
  local one. Neither needs DNS or a certificate, which is what keeps `create` unprivileged.

---

## 6. Migration

Per project: write the worktree keys into `.grove.conf`, run `grove create` once into a spare slot, compare against a
worktree the old hook made, then replace the five hook scripts with `grove hook …` lines in `settings.json` and delete
`tools/worktree-site.sh`.

Order matters. **cbx-magento first, not cbx-joomla** — it is the one with the requirement that shaped
the design, so it fails fastest if `container` is wrong. cbx-joomla last: it is the most-used and has
the most bespoke behaviour to lose.

---

## 7. Risks worth deciding before building

- ~~A sync-ignored `vendor/` is invisible to the IDE.~~ **Decided: acceptable.** It only affects the
  worktree; the main checkout keeps its own `vendor/` and that is what gets indexed. So `container`
  can be a profile default for Magento rather than a per-project opt-in.
- **`container` needs a source.** Copying from the main checkout's in-container path is fast and
  correct, but couples the worktree to whatever the main checkout had at that moment. `composer
  install` in the worktree is correct and slow. Default to the copy; offer `vendor:fresh`.
- **Post-create hooks make `create` slow again.** `di:compile` is minutes. It should respect
  `GROVE_PROVISION="lazy"` — deferred to first use, like the database already is.
- ~~One config format, two consumers.~~ **Decided: shell.** `.grove.conf` grows the worktree keys
  rather than gaining a second file in another language. Arrays of `path:strategy` cover the one place
  nesting seemed necessary, and sourced profiles give inheritance for free.

Both open decisions are settled; what remains above is mechanical. The next step is
`profiles/magento2.sh` and `grove create`, proven against cbx-magento first — it carries the
requirement that shaped the design, so it fails fastest if `container` is wrong.

---

## 8. What building it changed

The design above survived implementation intact — the strategies, the shell config, the profiles and
the hook-first command surface are all as written. What building it *added* was four things no amount
of reasoning had surfaced, every one of them found by running the thing against a throwaway project
rather than by reading it.

**A `link` path is a loaded gun pointed at the main checkout.** A session runs `git add -A`, the
symlink is staged, the merge lands it — and the main checkout's real `node_modules` is replaced by a
symlink pointing at itself. The reason it is not caught by the obvious defence is worth remembering:
`/node_modules/` in a `.gitignore` has a trailing slash, which matches a **directory** and not a
**symlink**, so the ignore rule that looks like it covers this does not. grove now writes a managed
block into the repository's local git excludes *before* any strategy runs, and `merge` refuses
outright to carry a managed path across. Two independent defences, because the failure destroys work.

**Everything grove creates must be invisible to the "is this worktree still busy?" check.** That
check is what makes `WorktreeRemove` refuse to release a worktree holding unfinished work — so
anything grove itself creates that reads as work occupies a slot forever and nothing gives it back.
The subtlety is that the exclusion has to be limited to entries git reports as UNTRACKED; otherwise a
project that genuinely tracks a file under a declared path would have real edits silently ignored.

**`container` needs a matching teardown, and this is a correctness bug rather than housekeeping.**
The sync is told to ignore those paths — so it will not carry their *deletion* either, and it refuses
to remove a directory tree still holding ignored content. Removing a worktree host-side therefore
strands the **entire** worktree inside the container. The obvious cost is garbage (one Magento
`vendor/` per abandoned worktree, forever). The sharp cost is that the vhost goes on serving that
stale copy at its URL, so the next session handed the same slot sees the previous session's files.
grove purges the container-side directory on remove, and again on create for a reused slot.

And the purge has to happen **before** the checkout, not after. The sync is bidirectional: deleting
the container's copy of a path that exists on the host propagates that deletion straight back, so a
purge run after `git worktree add` deletes the files git has just checked out. The same asymmetry
makes the container-side copy itself conditional — it is only safe *because* the path is excluded
from sync, so grove verifies that against the file it wrote rather than assuming it, and refuses the
copy otherwise. On a bind-mounted stack there is no exclusion to be had at all: container-side and
host-side are the same files, and an `rm -rf` in the container is an `rm -rf` on the host.

**A generated file has to know the generator's rules.** ddev marks the files it owns with
`#ddev-generated` and rewrites them on every restart, so the sync-exclusion this design depends on
would have survived exactly until the next `ddev restart` — silently. grove takes ownership by
dropping the marker. It also cannot *mention* the marker in a comment, because the scan that looks
for it does not care that it is inside one.

The pattern common to all four: **the strategies were right, and their lifecycles were missing.**
Declaring how a path comes into existence turned out to be only half of it — every strategy also owes
an answer to what happens when the worktree goes away, and what git and the file sync each believe
about the path in the meantime.
