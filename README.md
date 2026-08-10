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

| | |
|---|---|
| `grove status` | what is in place and what is not. No root. |
| `grove cert` | issue or renew the zone's wildcard over DNS-01. No root. |
| `sudo grove install` | claim this project's hosts in the proxy + install the renewal timer. **One sudo, once.** |

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

## Not yet packaged

The worktree lifecycle — slot allocation, per-worktree database and vhost, the create/remove hooks —
still lives in each project, copy-pasted four times and already diverged.

[`docs/CONCEPT-worktrees.md`](docs/CONCEPT-worktrees.md) is the design for absorbing it: every path
declares *how* it exists in a worktree (`clone`, `empty`, `link`, `container`, `skip`) rather than
appearing on one of two hardcoded lists, which turns Magento's "vendor copied container-side and
excluded from file sync" from a special case into one word — and lets grove derive the sync-ignore
list from it instead of having the same fact written down twice.
