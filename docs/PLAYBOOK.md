---
name: worktree-sites
description: Give every git worktree its own isolated dev site on one shared container stack — own database, own docroot, own hostname — and publish them all on real public HTTPS subdomains behind one wildcard certificate. Use when setting up (or debugging, or porting to another project) per-worktree dev sites, per-branch preview URLs, a wildcard TLS certificate for a local stack, DNS-01 certificate automation, or a reverse proxy that fronts a local dev environment on a real domain.
---

# Per-worktree dev sites on real public hostnames

A git worktree isolates **code**. It does not isolate the **site** — every worktree points at the same
database and the same uploads, which makes worktrees useless for exactly what they are best at: trying
a migration, changing settings to see what breaks, seeding data, pointing an E2E run somewhere.

This builds the missing half: one shared container stack serving **N sites**, one per worktree, each with
its own schema, docroot and hostname — and every one of them reachable from the internet on a real
certificate.

```
https://myfeature-myproject.ddev.site          local,  dev-tool certificate
https://myfeature-myproject.dev.example.com    public, Let's Encrypt wildcard
```

Assumes a PHP app with a database, in a container stack (DDEV is the common case), plus optionally
another service or two (memcached, redis, a search engine). Nothing here is specific to Joomla,
WordPress, Magento or Laravel — the app only shows up in one place, §8.

---

## 1. The rule that decides the whole design

**DNS and TLS wildcards match exactly one label.**

`*.dev.example.com` covers `foo.dev.example.com`. It does **not** cover `foo.bar.dev.example.com`.
Neither the DNS record nor the certificate will match it.

So hostnames are **flat**:

```
✅  myfeature-myproject.dev.example.com     one wildcard covers every worktree of every project
❌  myfeature.myproject.dev.example.com     needs a wildcard DNS record AND a cert SAN per project
```

Get this wrong and every new project needs a DNS change and a certificate re-issue. Get it right and
**one** DNS record plus **one** certificate cover everything you will ever add. The same applies to the
local hostname if your dev tool's wildcard is single-label (`*.ddev.site` is).

This is the single highest-leverage decision here. Confirm the naming with the user before building.

---

## 2. The invariants

Four facts explain everything else. If a change breaks one of them, it is the wrong change.

1. **One web server, one `server` block per site**, selected by the `Host` header. A worktree is a vhost
   file.
2. **One database server, one schema per site**, plus a DB user granted on that schema only.
3. **One PHP-FPM master, one on-demand pool per site** (optional but cheap — an idle worktree then costs
   zero processes). Skip it and every site shares the main pool; that is fine to start.
4. **Two wildcards do all the routing and neither is ever touched again.** Locally
   `*.<project>.<devtld>`; publicly `*.dev.example.com`. Both already resolve and are already certified,
   so **creating a worktree is writing a file and reloading** — no restart, no port allocation, no DNS,
   no certificate, no privileged operation.

**The test of a correct build: `worktree create` needs no `sudo` and no secret.** If it does, something
has drifted from this model — almost always because a hostname was published individually instead of
being covered by the wildcard.

### What is and is not isolated

| | Isolated per worktree | Shared by all sites |
|---|---|---|
| | schema + DB user, docroot, hostname, uploads/data dir, FPM pool | the database server, the FPM master, the containers, one restart takes everything down |

Be honest about what this protects. Isolation is now **configuration**, not a container boundary — the
right schema name in the app config, the right docroot in the vhost. The guard rails that remain:

- **A per-worktree DB user granted only on its own schema.** A worktree that somehow points at the main
  database gets *access denied* instead of silently writing to it. This is the main remaining guard rail
  and the reason the per-worktree user is worth the trouble.
- **A guard that refuses starting a second stack from inside a worktree** (see §7).
- **A catch-all vhost** so an unclaimed hostname can never reach the main site.

---

## 3. Decide these first

| Decision | Recommendation |
|---|---|
| Hostname shape | Flat: `<worktree>-<project>.dev.example.com`. See §1. |
| Worktree names | Fixed slots (`wt1…wt5`) are simpler to reason about and cap concurrency deliberately; free-form names need a wildcard local hostname and no pre-registration. Either works. |
| DB seeding | Clone the main schema by default; offer `--db none` for an empty one. |
| Uploads/large assets | Copy-on-write clone where the filesystem supports it (APFS `cp -c`, btrfs/ZFS). Offer `--assets none` for back-end-only work. |
| Public exposure | Every worktree public by default, or an allowlist. Default-public is what keeps creation unprivileged; the alternative makes publishing a per-name root operation. **Ask** — it means a production-seeded copy on a guessable public name. |
| Certificate automation | DNS-01 with a scoped API token → fully unattended. Without API access, expect a manual TXT paste every ~90 days. |

---

## 4. Build order

Each phase is independently verifiable. Do not start the next one until the current one is proven.

### Phase 1 — one isolated site, locally

Per worktree, create: a vhost (docroot → the worktree), a schema + DB user, a copy of the app config
pointing at that schema, and cloned uploads. Reload the web server. Nothing here needs root.

**Never copy `cache`, `tmp` or `logs`. Create them empty.** A new worktree must start with nothing in
any of the three, and the way to guarantee that is to leave them out of the clone entirely rather than
copy and then clean:

```bash
# Copy the runtime dirs the site genuinely needs (uploads, per-install data)…
copy_local "<uploads-dir>"
copy_local "<app-data-dir>"

# …and CREATE these, never copy them. Listed explicitly so the guarantee survives someone
# later adding a parent directory to the copy list above.
mkdir -p "$WT/<cache>" "$WT/<tmp>" "$WT/<logs>" "$WT/<admin-cache>" "$WT/<admin-logs>"
```

Each of the three is wrong to inherit for its own reason:

- **logs** — the first thing anyone does with a fresh site is read the log to find out why it
  misbehaves. Entries from another site, timestamped before the worktree existed, are worse than no
  log at all: they send you debugging a problem that was never yours.
- **cache** — a cloned cache holds the *other* site's compiled paths and absolute filenames. It will
  either be silently wrong or fail in a way that points nowhere near the cause.
- **tmp** — half-finished uploads, session files and lock files from another site, some of which the
  app will treat as real state.

There is a size argument too (these are usually the bulk of a data dir), but correctness is the reason.

If a parent directory has to be copied wholesale, exclude the three in the copy and recreate them —
and if the app writes logs somewhere non-obvious as well (a per-subsystem directory, a framework log
outside the data dir), cover those too. Verify with step 7 in §6, which fails on any non-empty file.

**Build the site lazily, on the first file change.** Seeding the database is the only slow step here,
and most sessions never need a site — they answer a question, read code, or edit a doc and end. Do the
cheap parts at creation (they are what make the worktree a working *checkout*), leave a marker, and
seed on the first `Edit`/`Write` from a post-tool hook. A question-only session then pays nothing and
a working session pays once. Two details make it safe: an atomic `mkdir` lock, so two quick edits
cannot both start a seed against the same database; and leaving the marker in place when the stack is
down, so the next edit retries instead of the worktree silently never getting a site.

**Then make the deferred build observable, because deferring it split one fact into four.** Once the
site is built later, "this worktree has a URL" stops meaning "that URL serves anything", and a reader
needs to tell apart *not built yet*, *building right now*, *finished*, and *tried and failed*. Two
files carry all four — the pending marker, whose contents describe the last failed attempt, and the
lock directory, holding the builder's pid, its start time and the step it is on. Everything that
reports (`list`, `info`, the worktree's own note, the hook's message back to the session) derives its
answer from those, so they cannot disagree.

Three things this gets wrong if you do not think about them:

- **Clear the marker only on success.** Clearing it either way makes a failed build read as a
  finished one everywhere, *and* silently disables the retry — the next edit finds no marker and does
  nothing. A build that never came up then looks exactly like one that did.
- **A held lock is not a running build.** The on-edit hook has a timeout and that timeout is a hard
  kill, so a lock outliving its owner is ordinary, not exotic. Check the recorded pid: alive means
  wait, gone means the build was cut off. A lock whose owner has died must be breakable or one
  timeout costs the worktree its site permanently — but log it loudly, because the container-side
  child it spawned (composer, `di:compile`) outlives the parent and may still be running.
- **A retry that survives failure retries on *every* edit.** Count the failed attempts in the marker
  and stop after a couple, naming the manual command instead. Otherwise a build that fails
  reproducibly costs minutes per keystroke — the cure being worse than the disease it replaced.

Also add a **catch-all vhost** that refuses unknown hostnames. Do not implement it as `default_server`
if your dev tool generates its own vhost — that tool will regenerate the file, reclaim the token, and
the web server will die on a duplicate default server. Match by **regex `server_name`** instead: the
resolution order is exact name → leading wildcard → trailing wildcard → **first matching regex** →
`default_server`, so a regex catch-all always wins without claiming anything.

**Verify:** a marker file only that worktree's docroot contains is served under its hostname, and is a
404 on the main site. Proving the hostname *responds* proves nothing — the main site responds too.

### Phase 2 — the local wildcard hostname

Register `*.<project>` (or the fixed slot names) with the dev tool so its router and its certificate
cover them. This usually needs one restart, and then never again.

### Phase 3 — public DNS

```
dev.example.com     A      <your public IP>
*.dev.example.com   CNAME  dev.example.com
```

Router forwards inbound **80 and 443** to the machine, and give the machine a DHCP reservation — the
proxy binds a specific LAN IP and a new lease breaks both the listener and the forward.

**Verify before any certificate exists**, by asking the web server directly with a Host header:

```bash
curl -sk -H "Host: myfeature-myproject.dev.example.com" https://127.0.0.1/
```

The Host header **is** the test. Without it you are talking to the default server.

### Phase 4 — the reverse proxy

A proxy terminates TLS on 443 and forwards everything under the zone to the stack; the web server then
routes by `Host`. Caddy is the easy choice.

```
dev.example.com, *.dev.example.com {
    bind <LAN IP>
    header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet"
    tls <cert path> <key path>
    reverse_proxy 127.0.0.1:<pinned stack port> {
        header_up Host {host}
        header_up X-Forwarded-Proto https
        transport http { tls tls_insecure_skip_verify }
    }
}
```

Three things here are load-bearing, each of which has cost someone a debugging session:

- **`header_up Host {host}`** — proxies rewrite `Host` to the upstream address by default, and the app
  then builds every link and redirect against `127.0.0.1:<port>`.
- **`header_up X-Forwarded-Proto https`** — an HTTPS hop upstream is **not** enough; apps read the scheme
  from this header. Without it you get `http://` links and redirect loops.
- **`X-Robots-Tag: noindex`** — this is production-seeded data on a subdomain of a real domain. Without
  it, it gets indexed and competes with the real site.

**A second project in the SAME zone does not get its own block.** Caddy will not accept two site
blocks both claiming `*.dev.example.com` — and the wildcard is the whole point, so you do not want a
zone per project either. Route inside one block with host matchers, one per project, each to that
project's pinned port:

```
dev.example.com, *.dev.example.com {
    tls <cert> <key>
    header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet"

    @projectb host *-projectb.dev.example.com
    reverse_proxy @projectb 127.0.0.1:33643 { … }

    reverse_proxy 127.0.0.1:33543 { … }          # default: the first project
}
```

This is why the flat `<worktree>-<project>` shape pays off twice: it needs no new DNS or certificate
*and* it gives the proxy a clean suffix to match on. Setup tooling should therefore add or update a
**matcher**, not append a block — and adding project number two means editing the shared config, so
it is another one-time privileged step.

Pin a **stable upstream port** for the stack. Two other notes:

- **Do not use the dev tool's own Let's Encrypt / bind-all-interfaces options.** They are global: they
  expose *every* project on the machine, including each one's mail catcher and profiler UI.
- **One proxy per machine.** A second cannot bind the same IP:443. If one already runs (for another
  project), **extend its config** with another site block — back it up first and never touch the other
  project's block.

### Phase 5 — the certificate, renewed unattended

A wildcard can **only** be issued over DNS-01. Use a token scoped to that one zone.

If the proxy has a DNS provider plugin, let it do everything. If it does not — and rebuilding the proxy
binary would disturb another project that depends on it — use a standalone ACME client (`lego`,
`certbot`) with its own provider plugin, write the certificate to a stable path the proxy points at, and
have a **daily timer** renew it.

The renewal job must do three things, and the middle one is the one people forget:

1. renew (a no-op until due),
2. **apply it** — restart or reload the proxy, otherwise you fetch a fresh certificate every 90 days and
   serve the expired one,
3. only bother the proxy when the certificate actually changed, so a daily no-op does not restart your
   only TLS front end 365 times a year.

### Phase 6 — taking a project back off

The inverse is not symmetrical with the install, and its steps only work in one order. Build it as a
command rather than leaving it to be done by hand: every step below is easy to do, and easy to do in
the wrong order or forget entirely, and two of them fail silently when you do.

1. **Remove the project's matcher, then reload.** Stage and validate first, exactly as the install
   does — a removal can produce an unparseable config as easily as an addition can.
2. **Remove its row from whatever registry says who is on the zone**, in the same run. A registry that
   still lists a project the proxy no longer routes is what makes the next teardown ambiguous.
3. **If the project owned the DEFAULT upstream, something else has to take that position** — or every
   name under the zone that is not one of the remaining matchers starts 404ing out of the proxy
   itself. Promote another project by *moving* its block, not by generating a new one from a template:
   only the block knows that project's real scheme, headers and transport.
4. **Put the promoted default at the END of the site block.** A `reverse_proxy` with no matcher
   matches every request and is terminal, so a promoted default sitting above another project's
   matcher swallows that project's traffic completely — the same 200-with-the-wrong-site failure as a
   matcher that matches nothing.
5. **Only when the zone is empty: unload the renewal timer BEFORE deleting its plist.** `launchctl`
   works from the label, not from the file. Delete the plist first and the job stays loaded until the
   machine reboots — firing nightly into a renewal script that no longer exists.
6. **Then the certificate store.** Never before the site block is gone: the block's `tls` line points
   into that directory, and a proxy that cannot read its certificate does not come up at the next
   restart — taking every other project on the machine with it, hours later, for a reason nothing on
   screen connects to this.
7. **Leave DNS alone.** The wildcard record is the user's, and one pointing at a private LAN address
   serves nothing and costs nothing to keep.

**Only step 5 needs root, and check that claim before you believe it about the others.** A root-owned
file inside a directory you own is *yours to delete*: unlinking is a write to the **directory**, not
to the file, so the renewal log root wrote does not make the certificate store a privileged removal.
The daemon plist genuinely is one — `/Library/LaunchDaemons` is root's — so gate that step alone, do
everything else unprivileged, and have the command name the one thing it could not finish. What it
must never do is *assume* the removal worked: a store whose subdirectories were created by root (a
`sudo` run of the ACME client, once) survives an unprivileged `rm -rf`, and reporting success over a
certificate that is still on disk is worse than reporting the failure.

---

## 5. Traps, with their symptoms

Every one of these has actually happened. They are listed by how long they take to diagnose.

| Symptom | Cause |
|---|---|
| Renewal "works" for months, then the site serves an expired certificate | The renewal job fetched but never applied. See Phase 5 step 2. |
| `caddy reload` → `connection refused` on :2019 | The proxy runs with `admin off`. Reload goes through the admin API; **restart the daemon** instead. |
| Daemon restart leaves *nothing* running | `launchctl bootout` returns before the job is gone; bootstrapping into that gap fails. Wait for the label to disappear, then bootstrap. |
| A setup script says "no certificate yet" for a certificate that exists | The script has a user half and a `sudo` half, and used `$HOME` — which is root's under sudo. Resolve the invoking user's home instead. |
| Renewal runs clean for 90 days, then the certificate expires anyway | `${SUDO_USER:-$(id -un)}` is **not** enough. A root timer running `sudo -u you …` sets `SUDO_USER=root`, so the renewed certificate lands in `/var/root/…` while the proxy serves the old path. Trust `SUDO_USER` only when `id -u` is 0, and pass an explicit override from the timer. |
| Everything is suddenly unreachable from outside, and DNS looks fine | DHCP moved the machine. The proxy's `bind <ip>` and the router's forward both point at the old address. Give the machine a reservation, and have `status` compare the bound address to the current one. |
| The proxy is listening on every interface | The address lookup returned empty and `bind` was written with no argument. Treat an empty LAN address as fatal, and do not assume the interface is `en0`. |
| Certificate issuance fails "time limit exceeded" long after the DNS record is published | The ACME client verifies propagation through the **system** resolvers, one of which never returns the record. Pin public resolvers (`--dns.resolvers 1.1.1.1:53,8.8.8.8:53`). |
| `flag provided but not defined: -email` | `lego` 5 moved flags onto the subcommand (`lego run --email …`) and dropped `renew` — `run` is "get or renew". |
| A timer works by hand and silently fails on schedule | A system daemon gets a minimal `PATH`. Use absolute paths for every binary. |
| Site renders with `127.0.0.1:<port>` in links | Missing `header_up Host {host}`. |
| Redirect loop, or `http://` links on an HTTPS site | Missing `header_up X-Forwarded-Proto https`. |
| An unclaimed hostname serves the **main** site | No catch-all vhost, or it was written as `default_server` and the dev tool reclaimed it. |
| Everything 502s after a reboot | The proxy came back (it is a system daemon); the container stack did not. Most dev tools do not auto-start. |
|  A brand-new worktree's log, cache or tmp holds another site's content |  Those three were copied instead of created. Never copy them (Phase 1). |
| A slot hostname 404s | Usually the worktree is simply gone. Check `git worktree list` before suspecting routing. |
| After removing a project, every unclaimed name 404s from the proxy | The removed project owned the zone's **default** upstream. Promote another project into that position (Phase 6). |
| After removing a project, a *different* project starts serving another's traffic | The promoted default was written above that project's matcher. A matcher-less `reverse_proxy` matches everything; it belongs at the end. |
| A removed zone's renewal job still fires every night | The plist was deleted before `launchctl bootout`. It works from the label, so the job stays loaded until reboot. Bootout first. |
| The proxy fails to start days after a zone was removed | Its certificate directory was deleted while a site block still pointed at it. Remove the block first. |
| A teardown reports the certificate store removed, and it is still there | `rm -rf` cannot empty a subdirectory owned by root (an ACME client once run under `sudo`). It fails per entry and carries on; check that the directory is gone rather than trusting the command. |
| Adding a project/provider/hostname breaks a `--check` build step | Some generated artifact enumerates them. Regenerate and commit; it is a two-step change. |

---

## 6. Verification checklist

Run these in order; each one fails for a different reason.

```bash
# 1. The web server routes the name to the RIGHT docroot (before DNS or certs exist).
echo marker > <worktree>/docroot/_probe.txt
curl -sk -H "Host: <name>" https://127.0.0.1/_probe.txt      # → marker
curl -sk -H "Host: <main site>" https://127.0.0.1/_probe.txt # → 404, NOT the marker

# 2. An unclaimed name is refused, not silently served by the main site.
curl -sk -o /dev/null -w '%{http_code}\n' -H "Host: nonesuch.dev.example.com" https://127.0.0.1/

# 3. Public DNS resolves the wildcard.
dig +short A probe-$$.dev.example.com

# 4. Real certificate, validated — note the absence of -k.
curl -sI https://<name>.dev.example.com/

# 5. The app builds PUBLIC urls, not loopback ones.
curl -sL https://<name>.dev.example.com/ | grep -oE '<base href="[^"]*"'
curl -sL https://<name>.dev.example.com/ | grep -c '127.0.0.1'   # → 0

# 6. Isolation is real: the worktree's DB user cannot read the main schema.
#    Expect ERROR 1044 (access denied).

# 7. A new worktree's cache, tmp and logs are EMPTY — nothing inherited from the main site.
find <worktree>/{cache,tmp,logs} <worktree>/<admin>/{cache,logs} -type f -size +0c   # → no output

# 8. Restart safety.
<devtool> restart && curl -sI https://<name>.dev.example.com/    # still 200/301
```

Then the one people skip: **create a brand-new worktree and time it.** It must need no prompt, no
`sudo`, no DNS change and no certificate work, and its public URL must answer immediately.

---

## 7. Root, secrets, and what must never need them

| Needs root | Only what lives outside your own directories: the proxy site block until reloads go through the admin API, and the renewal timer's plist — installing it, and unloading it at the end. |
|---|---|
| Needs a secret | Once: the DNS provider API token, in a gitignored local file. Never in the repo. |
| **Needs neither** | **Creating, using and removing a worktree — forever. Publishing and unpublishing a project. And deleting the zone's whole certificate store, root-owned log included.** |

That last row is the whole point. Make setup a single idempotent command (`status` / `cert` / `install`)
so the privileged part is one reviewable step, and make `status` print exactly what is still missing.

The teardown deserves the same treatment, and for a sharper reason: it is done rarely, under time
pressure, on a config shared with every other project on the machine — which is exactly when a
half-remembered sequence of hand edits does damage. Give it a command, and keep its one privileged
step (Phase 6, steps 5–6) separate so the common case stays unprivileged.

Also add a **guard that refuses starting a second container stack from inside a worktree**. There is one
stack; a worktree that starts its own gets port conflicts and a second database that nothing points at.

---

## 8. Porting to another project

Only these change:

1. **Project name** — in hostnames, schema prefix, vhost filenames.
2. **The app config file** the per-worktree copy rewrites, and the connection settings in it
   (`configuration.php`, `wp-config.php`, `app/etc/env.php`, `.env` — this is the only app-specific part).
3. **Language runtime paths** in the FPM pool/reload logic (`/etc/php/8.4/fpm/pool.d`, the pid file).
4. **Extra services.** memcached/redis/search are *shared*, like the database server. If a worktree needs
   isolation there, give it a key prefix or a separate logical DB index — not another container.
5. **A distinct pinned upstream port**, so two projects' proxies do not collide.
6. **The public zone**, if different. If the same zone, the existing wildcard already covers the new
   project — that is the payoff of the flat naming in §1: nothing to do in DNS or TLS.

### Doing it in a new project

1. **Read §1 and §3. Confirm the hostname shape and the exposure decision with the user before
   writing anything** — both are hard to change later and one of them is a security call.
2. Find out what already exists. Two things decide most of the work: does the project already have
   per-worktree sites (many do, partially), and **is there already a reverse proxy on this machine's
   :443?** If another project put one there, extend its config; you cannot run a second.
3. Work through §4 in order. Verify each phase with §6 before starting the next — every phase has a
   test that does not depend on the phase after it, which is what stops a DNS problem from looking
   like a certificate problem.
4. Expect exactly **one** privileged step and **one** secret (§7). If you find yourself needing either
   a second time, or per worktree, stop and re-read §2 — the design has drifted.
5. Finish by creating a throwaway worktree and timing it. No prompt, no `sudo`, working public URL.
   Then delete it.

**What "done" looks like:** a new worktree gets a working private *and* public site with one command
and no privileged operation; an unclaimed hostname 404s instead of serving the main site; the
certificate renews with nobody watching; and `status` names anything still missing in one line.
