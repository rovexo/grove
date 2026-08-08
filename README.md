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

## Not yet packaged

The worktree lifecycle itself — slot allocation, per-worktree database and vhost, the create/remove
hooks — still lives in each project. `docs/PLAYBOOK.md` §4 Phase 1 describes it; folding it in behind
a `cbx-worktree` binary is the obvious next step.
