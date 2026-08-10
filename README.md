# grove

Per-worktree dev sites on one shared container stack, published on real HTTPS subdomains behind a
single wildcard certificate.

```
https://myfeature-myproject.ddev.site          local
https://myfeature-myproject.dev.example.com    public, real certificate
```

**Creating or removing a worktree needs no DNS, no certificate, no proxy change and no sudo.** One
wildcard record and one wildcard certificate cover every worktree of every project, forever. That is
the whole design, and `docs/PLAYBOOK.md` is why it works and where it bites.

## Install

```bash
brew install rovexo/tap/grove
cd your-project
cp "$(brew --prefix grove)/templates/grove.conf.example" .grove.conf
$EDITOR .grove.conf
grove status          # names anything still missing
```

**Why Homebrew and not Composer or npm.** grove is a *machine-level* CLI, not a per-project library:
one wildcard certificate and one proxy serve every project on the host, so installing a copy per
repository is the wrong shape. Homebrew also expresses the real dependencies — `caddy` and `lego` are
binaries, not packages in any language ecosystem — and puts a single command on `PATH` without
dragging in a PHP or Node runtime that a bash tool has no use for.

From a clone, for development:

```bash
git clone https://github.com/rovexo/grove ~/grove
~/grove/bin/grove status
```

## Use

**Public hosting** — one wildcard per zone, one proxy block per project:

| | |
|---|---|
| `grove status` | what is in place and what is not. No root. |
| `grove cert` | issue or renew the zone's wildcard over DNS-01. No root. |
| `sudo grove publish` | claim this project's hosts in the proxy + install the renewal timer. **One sudo, once.** |

**Worktrees** — one isolated checkout, database and URL per session:

| | |
|---|---|
| `grove create <name>` | branch + worktree + site. No sudo, no prompts. |
| `grove list` | every worktree: branch, URL, database, idle time |
| `grove info <name>` | paths, URL, database, commits still to land |
| `grove shell <name> [cmd]` | run in that worktree, inside the container |
| `grove provision <name>` | give a site-less worktree its site after the fact |
| `grove sync-db <name>` | re-seed its database from the main one |
| `grove merge <name> [--keep]` | land the work; release the slot unless `--keep` |
| `grove remove <name> [-f]` | release without merging |
| `grove prune-merged` | delete worktree branches whose commits have all landed |
| `grove wire` | derive the vhost, the hostnames and the sync-ignore list |

**But an AI session never types any of those.** Claude Code fires a hook, and the session is *moved*
into a worktree and has to be *told* where it landed — so grove ships the hook entry points and
`grove wire` prints the four lines that go in `.claude/settings.json`:

```
grove hook create | remove | context | on-edit
```

## What is project-specific

Nothing in this package. It is all in `.grove.conf` at the project root: the project slug, the
zone, this stack's upstream port, the ACME contact, and where the machine's proxy lives.

## Two rules worth knowing before you start

**Hostnames are flat.** `<worktree>-<project>.<zone>`, never `<worktree>.<project>.<zone>` — DNS and
TLS wildcards match exactly one label, so the deep form is covered by neither the record nor the
certificate.

**There is one proxy per machine.** A second cannot bind the same address:443. If another project
already has one, point `GROVE_CADDYFILE`/`GROVE_CADDY_LABEL` at it: `install` then claims a host matcher
inside its existing block for the zone instead of adding a competing block.

## Requirements

macOS (launchd + `ipconfig`); the tool refuses to run elsewhere rather than failing obscurely. A
Linux port means systemd units and `ip -o -4 addr` — nothing else would change. Needs `caddy`,
`lego`, `dig`, `openssl` and `awk`; each subcommand checks the ones it uses and says what to install.

`install` bootstraps a machine that has **no** Caddy at all — it writes the Caddyfile and the daemon
— and joins one that already has it, claiming a host matcher inside the existing zone block.

Nothing is edited in place: the new Caddyfile is staged in a temp file and adapted by Caddy first,
so a config that does not parse never reaches the live proxy.

## Every path declares how it exists

A worktree is not a checkout: it needs the uploads directory, an empty cache, the dependencies and a
database. Rather than two hardcoded lists — things to copy, things to create — each path names a
**strategy**, and everything else is derived from that one declaration.

```sh
GROVE_PATHS+=(
    "pub/media:clone"       # copy-on-write clone, host-side — free on APFS
    "var/cache:empty"       # created, never copied
    "node_modules:link"     # relative symlink to the main checkout
    "vendor:container"      # copied INSIDE the container, excluded from file sync
    "generated:fresh"       # a GROVE_POST_CREATE command produces it
)
```

`container` is the one that earns it. A Magento `vendor/` is ~80k files: cloning it host-side is
instant, and then the file sync has to propagate all 80k into the container and watch them forever.
Copying it where it already lives and excluding it from sync removes both — and grove writes that
exclusion **from this list**, so the copy and the exclusion cannot drift apart.

Platform defaults come from a **profile** (`joomla`, `wordpress`, `magento2`, `plain`), which is just
a shell file sourced before your `.grove.conf`. Overriding is plain assignment, extending is `+=`,
later wins — because that is what shell does. Two Magento projects here differ only in `docroot`.

[`docs/CONCEPT-worktrees.md`](docs/CONCEPT-worktrees.md) is the full design record, including the
four things that only turned up once it was built and run.
