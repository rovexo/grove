#!/usr/bin/env bash
#
# Second half of the neutral-Caddy move: everything the first pass left pointing at the old
# project-specific tree.
#
#   certs, ACME storage and betacalco's state files  ->  the neutral tree
#   betacalco's own tools/public-host.sh             ->  repointed at it
#   the dead sites/dev.betacalco.com.caddy           ->  removed
#
# Doing these together is deliberate. Moving the certs alone would diverge from betacalco's tooling,
# which still writes the old paths — the next run of it would quietly undo half of this. So the
# script that moves the files is the script that repoints the tool.
#
# COPIES, then verifies, then reloads. Nothing is deleted from the old tree; if the reload fails the
# config is put back and the old files are still exactly where they were.
#
# Run once:  sudo contrib/finish-neutral-caddy.sh [path-to-betacalco-checkout]

set -uo pipefail

OLD_ETC=/usr/local/etc/betacalco-public-host
OLD_VAR=/usr/local/var/betacalco-public-host
NEW_ETC=/usr/local/etc/caddy
NEW_VAR=/usr/local/var/caddy
BLOCK="$NEW_ETC/sites/betacalco.caddy"
LABEL=com.caddyserver.caddy
PLIST="/Library/LaunchDaemons/$LABEL.plist"

USER_NAME="${SUDO_USER:-$(id -un)}"
USER_HOME="$(eval echo "~$USER_NAME")"
BC="${1:-$USER_HOME/PhpstormProjects/betacalco}"
BC_TOOL="$BC/tools/public-host.sh"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -f "$BLOCK" ] || die "$BLOCK not found — run migrate-to-neutral-caddy.sh first"
command -v caddy >/dev/null || die "caddy is not installed"

BACKUP="$BLOCK.bak-$(date +%Y%m%d-%H%M%S)"
cp "$BLOCK" "$BACKUP"

step "1. Certificates and state into the neutral tree"
mkdir -p "$NEW_ETC/certs"
for f in "$OLD_ETC"/certs/*; do [ -e "$f" ] && cp -p "$f" "$NEW_ETC/certs/"; done
ok "certs → $NEW_ETC/certs"
for f in email zone hosts.tsv; do
	[ -f "$OLD_ETC/$f" ] && cp -p "$OLD_ETC/$f" "$NEW_ETC/$f" && ok "$f → $NEW_ETC/$f"
done

step "2. ACME storage"
if [ -d "$OLD_VAR" ] && [ ! -d "$NEW_VAR" ]; then
	cp -Rp "$OLD_VAR" "$NEW_VAR"
	# The account key lives in here. Copied, not moved, so a bad reload can fall straight back.
	ok "storage → $NEW_VAR (account key carried over)"
	/usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:XDG_CONFIG_HOME $NEW_VAR" "$PLIST" 2>/dev/null \
		&& ok "daemon now points at $NEW_VAR" || warn "could not update XDG_CONFIG_HOME — check $PLIST"
else
	ok "storage already in place"
fi

step "3. Repointing the site block"
sed -i '' "s|$OLD_ETC/certs|$NEW_ETC/certs|g" "$BLOCK"
grep -q "$OLD_ETC" "$BLOCK" && warn "still references $OLD_ETC:" && grep -n "$OLD_ETC" "$BLOCK"
ok "tls paths rewritten"

step "4. Parsing before reloading"
caddy adapt --config "$NEW_ETC/Caddyfile" --adapter caddyfile >/dev/null 2>&1 || {
	cp "$BACKUP" "$BLOCK"
	die "config does not parse — reverted, nothing reloaded"
}
ok "parses"

step "5. Reloading"
launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || warn "kickstart failed — check: launchctl print system/$LABEL"
sleep 3
LAN="$(ipconfig getifaddr en0 2>/dev/null)"
fail=0
for h in dev.betacalco.com wt2-cbx-joomla.dev.rovexo.com; do
	code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$h:443:$LAN" "https://$h/" 2>/dev/null)"
	case "$code" in 2*|3*|502) ok "$h → $code" ;; *) printf '  \033[31m✗\033[0m %s → %s\n' "$h" "$code"; fail=1 ;; esac
done
if [ "$fail" -eq 1 ]; then
	cp "$BACKUP" "$BLOCK"
	launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1
	die "a zone stopped answering — block reverted and reloaded; the old tree is untouched"
fi

step "6. Repointing betacalco's own tooling"
if [ -f "$BC_TOOL" ]; then
	cp "$BC_TOOL" "$BC_TOOL.bak-$(date +%Y%m%d-%H%M%S)"
	sed -i '' \
		-e "s|^readonly CADDY_ETC=.*|readonly CADDY_ETC=\"$NEW_ETC\"|" \
		-e "s|^readonly CADDY_FILE=.*|readonly CADDY_FILE=\"\${CADDY_ETC}/sites/betacalco.caddy\"|" \
		-e "s|^readonly PLIST_LABEL=.*|readonly PLIST_LABEL=\"$LABEL\"|" \
		"$BC_TOOL"
	chown "$USER_NAME" "$BC_TOOL"
	bash -n "$BC_TOOL" && ok "repointed $BC_TOOL (backup alongside)" || warn "syntax error after edit — restore the .bak"
	printf '     CADDY_ETC=%s\n     CADDY_FILE=${CADDY_ETC}/sites/betacalco.caddy\n     PLIST_LABEL=%s\n' "$NEW_ETC" "$LABEL"
	warn "that is a tracked file — review and commit it in the betacalco repo"
else
	warn "betacalco checkout not found at $BC — repoint its tools/public-host.sh by hand:"
	printf '     CADDY_ETC=%s\n     CADDY_FILE=${CADDY_ETC}/sites/betacalco.caddy\n     PLIST_LABEL=%s\n' "$NEW_ETC" "$LABEL"
fi

step "7. Dead file"
[ -f "$OLD_ETC/sites/dev.betacalco.com.caddy" ] && rm -f "$OLD_ETC/sites/dev.betacalco.com.caddy" \
	&& ok "removed the unused $OLD_ETC/sites/dev.betacalco.com.caddy"

step "Done"
ok "nothing outside $NEW_ETC is referenced any more"
printf '\n  Still on disk, safe to remove once you are happy:\n    %s\n    %s\n' "$OLD_ETC" "$OLD_VAR"
printf '\n  Check:  grep -rn betacalco-public-host %s %s\n' "$NEW_ETC" "$PLIST"
