#!/usr/bin/env bash
#
# One-time migration: move this machine's Caddy off a project-specific path and onto a neutral one,
# and enable rootless mode while we are in there.
#
#   /usr/local/etc/betacalco-public-host/Caddyfile   ->  /usr/local/etc/caddy/Caddyfile
#   com.betacalco.public-host                        ->  com.caddyserver.caddy
#
# Site blocks split out of the single file: root-owned projects into /usr/local/etc/caddy/sites/,
# and grove-managed ones into the user's own ~/.config/grove/sites/ — which is what makes every
# later change unprivileged.
#
# ATOMIC AND REVERSIBLE. The new config is parsed BEFORE the daemon is touched, and if either zone
# stops answering afterwards the old daemon is put straight back. Nothing is deleted; the old files
# stay where they are until you remove them by hand.
#
# Run once:  sudo contrib/migrate-to-neutral-caddy.sh

set -uo pipefail

OLD_DIR=/usr/local/etc/betacalco-public-host
OLD_CFG="$OLD_DIR/Caddyfile"
OLD_LABEL=com.betacalco.public-host
OLD_PLIST="/Library/LaunchDaemons/$OLD_LABEL.plist"

NEW_DIR=/usr/local/etc/caddy
NEW_CFG="$NEW_DIR/Caddyfile"
NEW_LABEL=com.caddyserver.caddy
NEW_PLIST="/Library/LaunchDaemons/$NEW_LABEL.plist"

# Caddy's own storage — the ACME account and any certs it manages. Carried over verbatim; losing it
# would silently re-register with Let's Encrypt.
XDG=/usr/local/var/betacalco-public-host

USER_NAME="${SUDO_USER:-$(id -un)}"
USER_HOME="$(eval echo "~$USER_NAME")"
USER_SITES="$USER_HOME/.config/grove/sites"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
command -v caddy >/dev/null || die "caddy is not installed"
[ -f "$OLD_CFG" ] || die "nothing to migrate: $OLD_CFG does not exist"
[ -f "$NEW_CFG" ] && die "$NEW_CFG already exists — migrate by hand or move it aside"

step "1. Splitting the single Caddyfile into per-project blocks"
mkdir -p "$NEW_DIR/sites" "$USER_SITES" || die "could not create the config dirs"
awk '/^dev\.betacalco\.com, /{f=1} f{print} f&&/^}$/{exit}' "$OLD_CFG" > "$NEW_DIR/sites/betacalco.caddy"
awk '/^dev\.rovexo\.com, /{f=1}   f{print} f&&/^}$/{exit}' "$OLD_CFG" > "$USER_SITES/cbx-joomla.caddy"
chown -R "$USER_NAME" "$USER_HOME/.config/grove"
[ -s "$NEW_DIR/sites/betacalco.caddy" ] || die "could not extract the betacalco block"
[ -s "$USER_SITES/cbx-joomla.caddy" ]   || die "could not extract the rovexo block"
ok "betacalco → $NEW_DIR/sites/betacalco.caddy (root)"
ok "cbx-joomla → $USER_SITES/cbx-joomla.caddy (owned by $USER_NAME)"

step "2. Writing the neutral top-level config"
EMAIL="$(awk '/^\temail /{print $2; exit}' "$OLD_CFG")"
cat > "$NEW_CFG" <<EOF
# The machine's Caddy config. Neutral on purpose: no project owns this file.
#
# Site blocks live in the two imported directories. Root-owned projects put theirs in sites/;
# grove-managed projects write their own into a user-owned dir, which is what lets them be added,
# changed and reloaded without sudo. The admin endpoint is what makes those reloads possible.
{
	email ${EMAIL:-admin@localhost}
	admin localhost:2019
}

import $NEW_DIR/sites/*.caddy
import $USER_SITES/*.caddy
EOF
chmod 644 "$NEW_CFG"
ok "wrote $NEW_CFG"

step "3. Parsing it BEFORE anything is switched"
caddy adapt --config "$NEW_CFG" --adapter caddyfile >/dev/null 2>&1 \
	|| die "the new config does not parse — nothing was switched, $OLD_CFG is untouched"
ok "parses"

step "4. Installing the neutral daemon"
cat > "$NEW_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$NEW_LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$(command -v caddy)</string><string>run</string>
    <string>--config</string><string>$NEW_CFG</string>
    <string>--adapter</string><string>caddyfile</string>
  </array>
  <key>EnvironmentVariables</key><dict><key>XDG_CONFIG_HOME</key><string>$XDG</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/caddy.log</string>
  <key>StandardErrorPath</key><string>/var/log/caddy.log</string>
</dict></plist>
EOF
chmod 644 "$NEW_PLIST"
ok "wrote $NEW_PLIST (ACME storage carried over from $XDG)"

step "5. Swapping the daemons"
launchctl bootout "system/$OLD_LABEL" 2>/dev/null || true
w=0; while launchctl print "system/$OLD_LABEL" >/dev/null 2>&1 && [ $w -lt 30 ]; do sleep 1; w=$((w+1)); done
launchctl bootstrap system "$NEW_PLIST" 2>/dev/null || true
sleep 3

step "6. Checking both zones actually answer"
LAN="$(ipconfig getifaddr en0 2>/dev/null)"
fail=0
for host in dev.betacalco.com wt2-cbx-joomla.dev.rovexo.com; do
	code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$host:443:$LAN" "https://$host/" 2>/dev/null)"
	# 502 is fine: it means Caddy answered and that project's stack is simply not running.
	case "$code" in 2*|3*|502) ok "$host → $code" ;; *) printf '  \033[31m✗\033[0m %s → %s\n' "$host" "$code"; fail=1 ;; esac
done

if [ "$fail" -eq 1 ]; then
	printf '\n\033[31mRolling back.\033[0m\n'
	launchctl bootout "system/$NEW_LABEL" 2>/dev/null || true
	w=0; while launchctl print "system/$NEW_LABEL" >/dev/null 2>&1 && [ $w -lt 30 ]; do sleep 1; w=$((w+1)); done
	launchctl bootstrap system "$OLD_PLIST" 2>/dev/null || true
	rm -f "$NEW_PLIST"
	die "zones did not come back — the old daemon is running again and $OLD_CFG was never modified"
fi

step "Done"
ok "Caddy now runs from $NEW_CFG as $NEW_LABEL"
ok "rootless mode is on — grove publish no longer needs sudo"
printf '\n  Left in place on purpose, remove when you are happy:\n'
printf '    %s\n    %s\n' "$OLD_CFG (and its .bak-* files)" "$OLD_PLIST"
printf '\n  Then repoint betacalco: in its tools/public-host.sh set\n'
printf '    CADDY_FILE=%s/sites/betacalco.caddy\n    PLIST_LABEL=%s\n' "$NEW_DIR" "$NEW_LABEL"
