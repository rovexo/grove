# Migrating an existing hand-rolled setup onto the package

Written from doing it to cbx-joomla, whose public hosting predated the package.

## The one that bites: two certificate stores

The package keys its store by **zone** (`~/.local/share/grove/<zone>/`) because the
certificate is shared by every project under the wildcard. A hand-rolled setup almost certainly keyed
it by project. If you just run `cert`, you get a second certificate and a second ACME registration
for a zone that already had one.

**Copy, do not re-issue.** Bring the lego state across — the `accounts/` directory is the ACME
account, so copying it keeps renewals on the same registration and spends no Let's Encrypt request:

```bash
OLD=~/.local/share/<old-name>
NEW=~/.local/share/grove/<zone>
mkdir -p "$NEW" && cp -a "$OLD/lego" "$OLD/certs" "$NEW/"
<project>/tools/public-host.sh status        # → cert present, with its real expiry
```

## Then the timer, which needs the one sudo

The old renewal daemon still points at the old paths, so it renews into a directory the package no
longer reads. Nothing breaks immediately — and that is the problem, because it surfaces as an expired
certificate months later. Install the zone-wide timer and remove the old one:

```bash
sudo <project>/tools/public-host.sh install     # zone-wide timer, registers the project
sudo launchctl bootout system/<old-label>
sudo rm /Library/LaunchDaemons/<old-label>.plist
```

Verify there is exactly one:

```bash
launchctl list | grep -i renew
```

## Check the proxy block, once

`install` claims a host matcher inside the zone's existing block. If your hand-rolled block already
routes the whole zone to this project, that is still correct — the project stays the default upstream
and the matcher is only needed once a SECOND project joins the zone.

## What you should end up with

```
grove status
  ✓ DNS · ✓ port pinned · ✓ cert · ✓ caddy block · ✓ renewal timer (zone-wide)
  on this zone   <every project sharing the wildcard>
```

One certificate, one ACME account, one timer, N projects.
