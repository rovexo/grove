#!/usr/bin/env bash
#
# Loads the consuming project's .cbx-sites.conf and derives everything else.
#
# THE PACKAGE CONTAINS NO PROJECT NAMES, ZONES OR PORTS. Everything that differs between projects
# lives in one file at the project root, which is what makes this installable rather than copied.
#
# Sourced by bin/cbx-public-host. Sets: PROJECT ZONE UPSTREAM_PORT ACME_EMAIL DNS_PROVIDER
# CADDYFILE CADDY_LABEL CADDY_PLIST SECRETS CERT_DIR LEGO_DIR CRT KEY DAEMON_LABEL DAEMON_PLIST
# RENEW_SCRIPT REAL_USER REAL_HOME.

# --- platform ------------------------------------------------------------------------------------
# macOS only, and said out loud rather than discovered through a confusing failure: the daemons are
# launchd plists and the address lookup is ipconfig/ifconfig. A Linux port means systemd units and
# `ip -o -4 addr`; nothing else here would have to change.
if [ "$(uname -s)" != "Darwin" ]; then
	printf 'error: cbx-worktree-sites is macOS-only (launchd + ipconfig). Detected: %s\n' "$(uname -s)" >&2
	exit 1
fi

# --- where the project is -------------------------------------------------------------------------
# Walk up from the caller until a .cbx-sites.conf turns up, so the tool works from any subdirectory
# (and from vendor/bin, which is a symlink into the package).
cbx_find_project_root() {
	local dir="${1:-$PWD}"
	while [ "$dir" != "/" ]; do
		[ -f "$dir/.cbx-sites.conf" ] && { printf '%s\n' "$dir"; return 0; }
		dir="$(dirname "$dir")"
	done
	return 1
}

PROJECT_ROOT="$(cbx_find_project_root "${CBX_PROJECT_ROOT:-$PWD}")" || {
	printf 'error: no .cbx-sites.conf found in this directory or any parent.\n' >&2
	printf '       Copy the template:  cp vendor/rovexo/cbx-worktree-sites/templates/cbx-sites.conf.example .cbx-sites.conf\n' >&2
	exit 1
}

# shellcheck source=/dev/null
. "$PROJECT_ROOT/.cbx-sites.conf"

# --- required ---------------------------------------------------------------------------------
for _req in CBX_PROJECT CBX_ZONE CBX_UPSTREAM_PORT CBX_ACME_EMAIL; do
	if [ -z "$(eval "printf '%s' \"\${$_req:-}\"")" ]; then
		printf 'error: %s is not set in %s/.cbx-sites.conf\n' "$_req" "$PROJECT_ROOT" >&2
		exit 1
	fi
done
unset _req

PROJECT="$CBX_PROJECT"
ZONE="$CBX_ZONE"
UPSTREAM_PORT="$CBX_UPSTREAM_PORT"
ACME_EMAIL="$CBX_ACME_EMAIL"

# --- optional, with defaults --------------------------------------------------------------------
DNS_PROVIDER="${CBX_DNS_PROVIDER:-cloudflare}"
SECRETS="$PROJECT_ROOT/${CBX_SECRETS_FILE:-.claude/secrets/credentials.env}"

# The machine's single reverse proxy. Defaulted, because on a machine that already has one the
# correct answer is "the one that is already there" — see the multi-project note in the playbook.
CADDYFILE="${CBX_CADDYFILE:-/usr/local/etc/caddy/Caddyfile}"
CADDY_LABEL="${CBX_CADDY_LABEL:-com.caddyserver.caddy}"
CADDY_PLIST="${CBX_CADDY_PLIST:-/Library/LaunchDaemons/${CADDY_LABEL}.plist}"

# The port the zone block's DEFAULT reverse_proxy points at — i.e. which project owns the zone when
# no matcher applies. Used by status (is this project routed at all?) and by install (is it already
# the default, in which case it needs no matcher).
caddyfile_default_port() {
	awk -v z="^${ZONE//./\\.}[ ,]" '
		$0 ~ z {inz = 1}
		inz && /^[[:space:]]*reverse_proxy [^@]/ {
			if (match($0, /127\.0\.0\.1:[0-9]+/)) { print substr($0, RSTART + 10, RLENGTH - 10); exit }
		}
		inz && /^}/ {inz = 0}
	' "$CADDYFILE" 2>/dev/null
}

# --- derived --------------------------------------------------------------------------------
# Whose home holds the certificate. NOT $HOME: this runs as you, under sudo, and from a root timer
# via `sudo -u you`. In that last case sudo sets SUDO_USER to *root*, so the naive
# ${SUDO_USER:-$(id -un)} would put the renewed certificate in /var/root while the proxy served the
# old path — invisible until expiry. Trust SUDO_USER only when actually running as root.
REAL_USER="${CBX_PUBLIC_HOST_USER:-}"
if [ -z "$REAL_USER" ]; then
	if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
		REAL_USER="$SUDO_USER"
	else
		REAL_USER="$(id -un)"
	fi
fi
REAL_HOME="$(eval echo "~${REAL_USER}")"

# One certificate store per ZONE, not per project — the whole point of the wildcard is that every
# project under the zone shares it. A second project finds the certificate already issued.
CERT_DIR="$REAL_HOME/.local/share/cbx-worktree-sites/$ZONE"
LEGO_DIR="$CERT_DIR/lego"
CRT="$CERT_DIR/certs/_.${ZONE}.crt"
KEY="$CERT_DIR/certs/_.${ZONE}.key"

DAEMON_LABEL="com.cbx.worktree-sites.renew.${ZONE}"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
RENEW_SCRIPT="$CERT_DIR/renew.sh"


# --- per-project behaviour knobs ------------------------------------------------------------------
# These change what the binary WRITES for this project, without touching the zone-wide parts.

# The host pattern this project claims. Defaults to the flat form; override only if a project needs
# to answer on something else (a bare vanity name, say). Must still be ONE label under the zone.
HOST_PATTERN="${CBX_HOST_PATTERN:-*-${PROJECT}.${ZONE}}"

# How the proxy talks to this stack. DDEV terminates TLS on its own port, so https is the default;
# a plain-http stack sets this to http and the transport block is omitted.
UPSTREAM_SCHEME="${CBX_UPSTREAM_SCHEME:-https}"

# Worktrees are seeded copies of a real site on a guessable public name. Kept on by default; turn it
# off only for a project that is genuinely meant to be indexed.
NOINDEX="${CBX_NOINDEX:-1}"

# --- the zone registry ------------------------------------------------------------------------
# CERT MANAGEMENT IS CENTRAL, PER ZONE — not per project. One certificate, one renewal timer, one
# ACME account, shared by every project under the wildcard; a second project finds them already
# there and registers itself rather than duplicating them. This file is what makes that visible, and
# what lets `status` tell you who else is on the zone.
ZONE_REGISTRY="$CERT_DIR/projects.tsv"

zone_register() { # <project> <port> <host-pattern>
	mkdir -p "$CERT_DIR" 2>/dev/null
	touch "$ZONE_REGISTRY" 2>/dev/null
	# Rewrite this project's row rather than appending, so a changed port does not leave two.
	local tmp; tmp="$(mktemp)" || return 1
	grep -v "^$1	" "$ZONE_REGISTRY" 2>/dev/null > "$tmp"
	printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$tmp"
	sort -o "$tmp" "$tmp" && mv "$tmp" "$ZONE_REGISTRY"
	chmod 644 "$ZONE_REGISTRY" 2>/dev/null
}

zone_projects() { [ -f "$ZONE_REGISTRY" ] && cut -f1 "$ZONE_REGISTRY" | tr '\n' ' '; }

# --- rootless mode ---------------------------------------------------------------------------
# Site blocks in a directory YOU own, pulled into the machine's Caddyfile by one `import` line, and
# applied through Caddy's admin API instead of a daemon restart. Between them those two facts remove
# every root requirement from day-to-day use: adding a project, adding a worktree and renewing a
# certificate all become ordinary file writes plus a localhost POST.
#
# It costs one root edit, once, ever — see `cbx-public-host status`, which prints it.
SITES_DIR="${CBX_SITES_DIR:-$REAL_HOME/.config/cbx-worktree-sites/sites}"
SITE_FILE="$SITES_DIR/${PROJECT}.caddy"
ADMIN="${CBX_CADDY_ADMIN:-localhost:2019}"

# Does the machine's Caddyfile pull in our directory?
caddy_imports_sites() { grep -qsF "import $SITES_DIR/" "$CADDYFILE" 2>/dev/null; }

# Is the admin API answering? Without it a reload means restarting the daemon, which needs root.
caddy_admin_up() { curl -s -o /dev/null --max-time 2 "http://${ADMIN}/config/" 2>/dev/null; }

# Rootless is available only when BOTH hold — otherwise fall back to the privileged path.
rootless_ready() { caddy_imports_sites && caddy_admin_up; }

# The one-time root change that switches this machine over.
rootless_setup_hint() {
	printf '  Add these two to %s (one sudo, once):\n\n' "$CADDYFILE"
	printf '      {\n          admin %s      # replaces: admin off\n      }\n' "$ADMIN"
	printf '      import %s/*.caddy\n\n' "$SITES_DIR"
	printf '  Then reload once as root, and every change after that is unprivileged.\n'
}
