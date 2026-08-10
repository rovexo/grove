#!/usr/bin/env bash
# shellcheck disable=SC2034   # this file exists to SET variables; every reader is a different file
#
# Loads the consuming project's .grove.conf and derives everything else.
#
# THE PACKAGE CONTAINS NO PROJECT NAMES, ZONES OR PORTS. Everything that differs between projects
# lives in one file at the project root, which is what makes this installable rather than copied.
#
# Sourced by bin/grove. Sets: PROJECT ZONE UPSTREAM_PORT ACME_EMAIL DNS_PROVIDER
# CADDYFILE CADDY_LABEL CADDY_PLIST SECRETS CERT_DIR LEGO_DIR CRT KEY DAEMON_LABEL DAEMON_PLIST
# RENEW_SCRIPT REAL_USER REAL_HOME — and the worktree half: PLATFORM DOCROOT WORKTREES_DIR NAMING
# SLOTS PROVISION STACK SUBMODULE CONTAINER_ROOT LOCAL_ZONE DB_SEED DB_GRANT, plus the GROVE_PATHS
# and GROVE_POST_CREATE arrays.

# --- platform ------------------------------------------------------------------------------------
# macOS only, and said out loud rather than discovered through a confusing failure: the daemons are
# launchd plists and the address lookup is ipconfig/ifconfig. A Linux port means systemd units and
# `ip -o -4 addr`; nothing else here would have to change.
if [ "$(uname -s)" != "Darwin" ]; then
	printf 'error: grove is macOS-only (launchd + ipconfig). Detected: %s\n' "$(uname -s)" >&2
	exit 1
fi

# --- where the project is -------------------------------------------------------------------------
# Walk up from the caller until a .grove.conf turns up, so the tool works from any subdirectory
# (and from vendor/bin, which is a symlink into the package).
grove_find_project_root() {
	local dir="${1:-$PWD}"
	while [ "$dir" != "/" ]; do
		[ -f "$dir/.grove.conf" ] && { printf '%s\n' "$dir"; return 0; }
		dir="$(dirname "$dir")"
	done
	return 1
}

PROJECT_ROOT="$(grove_find_project_root "${GROVE_PROJECT_ROOT:-$PWD}")" || {
	printf 'error: no .grove.conf found in this directory or any parent.\n' >&2
	printf '       Copy the template:  cp "$(brew --prefix grove)/templates/grove.conf.example" .grove.conf\n' >&2
	exit 1
}

# --- the platform profile, sourced BEFORE the project file ----------------------------------------
# Profiles are ordinary shell files that ship with grove and set a platform's defaults. Sourcing one
# first and the project's file second is the whole inheritance mechanism: overriding is plain
# assignment, extending is `+=`, and LATER WINS because that is what shell does. There are no merge
# semantics to specify and no precedence rules to document.
#
# Which profile to load is itself a setting in the project file, so it is read first — in a SUBSHELL,
# so a config with a side effect in it does not run that side effect twice.
GROVE_PLATFORM="$(. "$PROJECT_ROOT/.grove.conf" >/dev/null 2>&1; printf '%s' "${GROVE_PLATFORM:-plain}")"

# Declared before anything appends to them: `GROVE_PATHS+=(…)` in a profile or a project file must
# extend a real array, and `${#GROVE_PATHS[@]}` on a never-declared name is an error under `set -u`
# in the bash 3.2 that macOS still ships.
GROVE_PATHS=()
GROVE_POST_CREATE=()

if [ -n "${PKG_DIR:-}" ] && [ -f "$PKG_DIR/profiles/${GROVE_PLATFORM}.sh" ]; then
	# shellcheck source=/dev/null
	. "$PKG_DIR/profiles/${GROVE_PLATFORM}.sh"
elif [ "$GROVE_PLATFORM" != "plain" ]; then
	printf 'error: no profile named %s (looked in %s/profiles/)\n' "$GROVE_PLATFORM" "${PKG_DIR:-?}" >&2
	printf '       shipped profiles: %s\n' "$(ls -1 "${PKG_DIR:-.}/profiles/" 2>/dev/null | sed 's/\.sh$//' | tr '\n' ' ')" >&2
	exit 1
fi

# shellcheck source=/dev/null
. "$PROJECT_ROOT/.grove.conf"

# --- required ---------------------------------------------------------------------------------
# Only the project's own name is required unconditionally. The public half (zone, port, ACME email)
# is checked by grove_require_public, called by the commands that actually need it — a project that
# uses grove ONLY for worktrees on a local stack has no zone and should not be made to invent one.
if [ -z "${GROVE_PROJECT:-}" ]; then
	printf 'error: GROVE_PROJECT is not set in %s/.grove.conf\n' "$PROJECT_ROOT" >&2
	exit 1
fi

PROJECT="$GROVE_PROJECT"
ZONE="${GROVE_ZONE:-}"
UPSTREAM_PORT="${GROVE_UPSTREAM_PORT:-}"
ACME_EMAIL="${GROVE_ACME_EMAIL:-}"

grove_require_public() {
	local _req _missing=0
	for _req in GROVE_ZONE GROVE_UPSTREAM_PORT GROVE_ACME_EMAIL; do
		if [ -z "$(eval "printf '%s' \"\${$_req:-}\"")" ]; then
			printf 'error: %s is not set in %s/.grove.conf\n' "$_req" "$PROJECT_ROOT" >&2
			_missing=1
		fi
	done
	[ "$_missing" -eq 0 ] || exit 1
}

# --- optional, with defaults --------------------------------------------------------------------
DNS_PROVIDER="${GROVE_DNS_PROVIDER:-cloudflare}"
SECRETS="$PROJECT_ROOT/${GROVE_SECRETS_FILE:-.claude/secrets/credentials.env}"

# The machine's single reverse proxy. Defaulted, because on a machine that already has one the
# correct answer is "the one that is already there" — see the multi-project note in the playbook.
CADDYFILE="${GROVE_CADDYFILE:-/usr/local/etc/caddy/Caddyfile}"
CADDY_LABEL="${GROVE_CADDY_LABEL:-com.caddyserver.caddy}"
CADDY_PLIST="${GROVE_CADDY_PLIST:-/Library/LaunchDaemons/${CADDY_LABEL}.plist}"

# Everything that contributes to the served configuration for this project: the machine's Caddyfile,
# plus our own imported site file.
#
# BOTH, always. In rootless mode the zone block does not live in the Caddyfile at all — it lives in
# the imported site file, and the Caddyfile holds nothing but an `import` line. A check that read
# only the first reported "caddy site block missing" for a project that was serving perfectly, and
# told the reader to run `sudo grove publish` to fix a problem that did not exist.
grove_caddy_cat() {
	cat "$CADDYFILE" 2>/dev/null
	[ -f "$SITE_FILE" ] && cat "$SITE_FILE" 2>/dev/null
	return 0
}

# The port the zone block's DEFAULT reverse_proxy points at — i.e. which project owns the zone when
# no matcher applies. Used by status (is this project routed at all?) and by install (is it already
# the default, in which case it needs no matcher).
caddyfile_default_port() {
	grove_caddy_cat | awk -v z="^${ZONE//./\\.}[ ,]" '
		$0 ~ z {inz = 1}
		inz && /^[[:space:]]*reverse_proxy [^@]/ {
			if (match($0, /127\.0\.0\.1:[0-9]+/)) { print substr($0, RSTART + 10, RLENGTH - 10); exit }
		}
		inz && /^}/ {inz = 0}
	' 2>/dev/null
}

# --- derived --------------------------------------------------------------------------------
# Whose home holds the certificate. NOT $HOME: this runs as you, under sudo, and from a root timer
# via `sudo -u you`. In that last case sudo sets SUDO_USER to *root*, so the naive
# ${SUDO_USER:-$(id -un)} would put the renewed certificate in /var/root while the proxy served the
# old path — invisible until expiry. Trust SUDO_USER only when actually running as root.
REAL_USER="${GROVE_USER:-}"
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
CERT_DIR="$REAL_HOME/.local/share/grove/$ZONE"
LEGO_DIR="$CERT_DIR/lego"
CRT="$CERT_DIR/certs/_.${ZONE}.crt"
KEY="$CERT_DIR/certs/_.${ZONE}.key"

DAEMON_LABEL="com.rovexo.grove.renew.${ZONE}"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
RENEW_SCRIPT="$CERT_DIR/renew.sh"


# --- per-project behaviour knobs ------------------------------------------------------------------
# These change what the binary WRITES for this project, without touching the zone-wide parts.

# The host pattern this project claims. Defaults to the flat form; override only if a project needs
# to answer on something else (a bare vanity name, say). Must still be ONE label under the zone.
HOST_PATTERN="${GROVE_HOST_PATTERN:-*-${PROJECT}.${ZONE}}"

# How the proxy talks to this stack. DDEV terminates TLS on its own port, so https is the default;
# a plain-http stack sets this to http and the transport block is omitted.
UPSTREAM_SCHEME="${GROVE_UPSTREAM_SCHEME:-https}"

# Worktrees are seeded copies of a real site on a guessable public name. Kept on by default; turn it
# off only for a project that is genuinely meant to be indexed.
NOINDEX="${GROVE_NOINDEX:-1}"

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
# It costs one root edit, once, ever — see `grove status`, which prints it.
SITES_DIR="${GROVE_SITES_DIR:-$REAL_HOME/.config/grove/sites}"
SITE_FILE="$SITES_DIR/${PROJECT}.caddy"
ADMIN="${GROVE_CADDY_ADMIN:-localhost:2019}"

# Does the machine's Caddyfile pull in our directory?
caddy_imports_sites() { grep -qsF "import $SITES_DIR/" "$CADDYFILE" 2>/dev/null; }

# Is the admin API answering? Without it a reload means restarting the daemon, which needs root.
caddy_admin_up() { curl -s -o /dev/null --max-time 2 "http://${ADMIN}/config/" 2>/dev/null; }

# Rootless is available only when BOTH hold — otherwise fall back to the privileged path.
rootless_ready() { caddy_imports_sites && caddy_admin_up; }

# --- the worktree half --------------------------------------------------------------------------
# Defaults for everything the worktree engine reads. A profile has already had its say by the time
# this runs, and so has the project file, so every one of these is "what is left when neither said
# anything".

# Which platform profile was loaded. Kept as a plain name for messages and for `info`.
PLATFORM="$GROVE_PLATFORM"

# Where the served document root sits inside a checkout, relative to its root. Empty means the
# checkout root IS the docroot, which is the common case outside PHP CMSes.
DOCROOT="${GROVE_DOCROOT:-}"

# Where worktrees are made. Inside the project on purpose: a stack that mounts the project directory
# then sees every worktree without a second mount, which is what lets one container serve them all.
WORKTREES_REL="${GROVE_WORKTREE_DIR:-.claude/worktrees}"

# slots — worktrees are named wt1…wtN, so ONE static vhost (hostname regex -> path) serves them all
#         and there is no per-worktree routing state to reconcile.
# free   — worktrees are named after the session. No fixed hostname set, so a site only happens
#          where routing can be wildcarded; without that they are isolated checkouts, which for a
#          project with no stack at all is exactly right.
NAMING="${GROVE_NAMING:-slots}"
SLOTS="${GROVE_SLOTS:-5}"

# lazy  — build the site (database, site config, post-create) on the first file change, because most
#         sessions never load a site and a dump-and-import on every one of them is the wrong default.
# eager — build it during create.
PROVISION="${GROVE_PROVISION:-lazy}"

# What runs this project's site. `none` is a first-class answer: worktrees, paths, branches and
# merges all work without any container, there is simply no database or URL to hand out.
STACK="${GROVE_STACK:-ddev}"
CONTAINER_ROOT="${GROVE_CONTAINER_ROOT:-/var/www/html}"
LOCAL_ZONE="${GROVE_LOCAL_ZONE:-ddev.site}"

# A submodule that must become a LINKED WORKTREE rather than a clone — see the long note in
# lib/worktree.sh. Empty for the projects that have none.
SUBMODULE="${GROVE_SUBMODULE:-}"

DB_SEED="${GROVE_DB_SEED:-clone}"      # clone | empty | none
DB_GRANT="${GROVE_DB_GRANT:-shared}"   # shared (the stack's own user) | own (per-worktree user)

BRANCH_PREFIX="${GROVE_BRANCH_PREFIX:-worktree-}"

# The one-time root change that switches this machine over.
rootless_setup_hint() {
	printf '  Add these two to %s (one sudo, once):\n\n' "$CADDYFILE"
	printf '      {\n          admin %s      # replaces: admin off\n      }\n' "$ADMIN"
	printf '      import %s/*.caddy\n\n' "$SITES_DIR"
	printf '  Then reload once as root, and every change after that is unprivileged.\n'
}
