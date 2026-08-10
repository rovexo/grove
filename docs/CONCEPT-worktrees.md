# Concept: grove takes over worktree management

> Status: proposal. Nothing implemented. Targets grove 0.2.

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

`grove.yaml` at the project root, replacing `.grove.conf` (which stays readable for the public half).

```yaml
project: cbx-magento
zone: dev.rovexo.com
upstream_port: 33643

platform: magento2          # a built-in profile — everything below is an override

worktrees:
  naming: slots             # slots (wt1…wtN, fixed hostnames) | free (needs a wildcard local host)
  slots: 5
  provision: lazy           # lazy = build the site on first file change | eager

  paths:
    vendor:       container   # <- the ask
    generated:    container
    pub/static:   empty
    var/cache:    empty
    var/log:      empty
    pub/media:    clone
    node_modules: link

  database:
    seed: clone             # clone | empty
    grant: own              # own = per-worktree user, scoped to its schema | shared

  hooks:
    post_create:            # run in the container, in the worktree, after the site exists
      - bin/magento setup:di:compile
      - bin/magento cache:flush
```

**The profile carries the platform knowledge**, so a project file is short. `platform: magento2`
already knows about `vendor`, `generated`, `var/*`, `pub/media` and the `app/etc/env.php` rewrite —
cbx-magento's file above is mostly re-stating defaults for clarity, and could be four lines.

---

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

## 4. Command surface

```
grove create <name>          branch + worktree + site.   No sudo. No prompts.
grove list                   every worktree: branch, URL, database, idle time
grove info <name>            paths, URL, schema, table count, commits ahead
grove shell <name> [cmd]     run in that worktree, inside the container
grove sync-db <name>         re-seed its schema from the main one
grove remove <name>          drop schema + user, vhost, pool, worktree
```

alongside today's `status`, `cert`, `publish`. The split stays legible: **`publish` is per project and
runs once; `create` is per worktree and runs constantly.**

---

## 5. What grove derives rather than asks for

The point of one declaration per path is that everything downstream follows from it:

- **The sync ignore list** — every `container` path, written into `.ddev/mutagen/mutagen.yml`.
- **The vhost** — from `docroot` + the profile's rewrite rules, one server block covering all slots.
- **The FPM pool** — on-demand, so an idle worktree costs zero processes.
- **The schema, user and grant** — from `database:`.
- **The container-side copy commands** — `container` paths, executed after the stack is up.
- **The hostnames** — `<name>-<project>.<zone>` publicly, already covered by the wildcard, plus the
  local one. Neither needs DNS or a certificate, which is what keeps `create` unprivileged.

---

## 6. Migration

Per project: write `grove.yaml`, run `grove create` once into a spare slot, compare against a
worktree the old hook made, then delete the four `.claude/hooks/worktree-*.sh` and `tools/worktree-site.sh`.

Order matters. **cbx-magento first, not cbx-joomla** — it is the one with the requirement that shaped
the design, so it fails fastest if `container` is wrong. cbx-joomla last: it is the most-used and has
the most bespoke behaviour to lose.

---

## 7. Risks worth deciding before building

- **A sync-ignored `vendor/` is invisible to the IDE.** PhpStorm indexes the host filesystem; if
  `vendor/` only exists in the container, autocomplete and go-to-definition break *in that worktree*.
  Probably acceptable (index the main checkout, which keeps its own vendor) — but it is a real cost of
  the thing being asked for, and it should be a per-path opt-in rather than a profile default.
- **`container` needs a source.** Copying from the main checkout's in-container path is fast and
  correct, but couples the worktree to whatever the main checkout had at that moment. `composer
  install` in the worktree is correct and slow. Default to the copy; offer `container:fresh`.
- **Post-create hooks make `create` slow again.** `di:compile` is minutes. It should respect
  `provision: lazy` — deferred to first use, like the database already is.
- **One config format, two consumers.** The public half reads `.grove.conf` (shell). Adding YAML means
  a parser; bash has none. Either keep everything in shell syntax and lose nesting, or accept a
  dependency (`yq`), or generate. **My preference: keep it shell-source-able** — `GROVE_PATH_vendor=container`
  is ugly next to YAML but keeps grove a single dependency-free script, which is most of why it is
  easy to install.

That last one is the real decision. Everything else here is mechanical.
