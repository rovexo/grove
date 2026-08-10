# cbx-worktree-sites

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
composer config repositories.cbx-worktree-sites path ../cbx-worktree-sites   # until it is published
composer require rovexo/cbx-worktree-sites

cp vendor/rovexo/cbx-worktree-sites/templates/cbx-sites.conf.example .cbx-sites.conf
$EDITOR .cbx-sites.conf
vendor/bin/cbx-public-host status      # names anything still missing
```

## Rootless mode (recommended)

Two lines in the machine's Caddyfile, added once with sudo, and **no operation ever needs root again**:

```
{
    admin localhost:2019          # replaces: admin off
}
import ~/.config/cbx-worktree-sites/sites/*.caddy
```

Site blocks then live in a directory you own, and changes apply through Caddy's admin API — a POST to
localhost — instead of a daemon restart. Those are the only two things that made root necessary.

`status` reports which mode a machine is in and prints the change if it is still privileged. Without
the setup, `install` falls back to editing the root Caddyfile, so existing machines keep working.

Port 443 is untouched: the already-running root daemon still binds it, so URLs stay clean and moving
the machine to another network costs one DNS record and no router rule.

**The trade, stated plainly:** Caddy runs as root and now reads config you can write, and the admin
API is unauthenticated on localhost. On a single-user machine both sit inside a boundary anything
with write access to your home directory already crosses — but they are real, and the privileged mode
is genuinely tighter.

## Use

| | |
|---|---|
| `cbx-public-host status` | what is in place and what is not. No root. |
| `cbx-public-host cert` | issue or renew the zone's wildcard over DNS-01. No root. |
| `sudo cbx-public-host install` | claim this project's hosts in the proxy + install the renewal timer. **One sudo, once.** |

## What is project-specific

Nothing in this package. It is all in `.cbx-sites.conf` at the project root: the project slug, the
zone, this stack's upstream port, the ACME contact, and where the machine's proxy lives.

## Two rules worth knowing before you start

**Hostnames are flat.** `<worktree>-<project>.<zone>`, never `<worktree>.<project>.<zone>` — DNS and
TLS wildcards match exactly one label, so the deep form is covered by neither the record nor the
certificate.

**There is one proxy per machine.** A second cannot bind the same address:443. If another project
already has one, point `CBX_CADDYFILE`/`CBX_CADDY_LABEL` at it: `install` then claims a host matcher
inside its existing block for the zone instead of adding a competing block.

## Requirements

macOS (launchd + `ipconfig`); the tool refuses to run elsewhere rather than failing obscurely. A
Linux port means systemd units and `ip -o -4 addr` — nothing else would change. Needs `caddy`,
`lego`, `dig`, `openssl` and `awk`; each subcommand checks the ones it uses and says what to install.

`install` bootstraps a machine that has **no** Caddy at all — it writes the Caddyfile and the daemon
— and joins one that already has it, claiming a host matcher inside the existing zone block.

Nothing is edited in place: the new Caddyfile is staged in a temp file and adapted by Caddy first,
so a config that does not parse never reaches the live proxy.

## Not yet packaged

The worktree lifecycle itself — slot allocation, per-worktree database and vhost, the create/remove
hooks — still lives in each project. `docs/PLAYBOOK.md` §4 Phase 1 describes it; folding it in behind
a `cbx-worktree` binary is the obvious next step.
