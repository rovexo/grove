#!/usr/bin/env bash
# shellcheck disable=SC2034   # a profile exists to SET defaults; the engine is what reads them
#
# Profile: joomla — Joomla 4/5, served from a docroot/ subdirectory.
#
# Sourced BEFORE the project's .grove.conf, so everything here is a default the project overrides by
# assignment or extends with `+=`.

GROVE_DOCROOT="docroot"

# The file grove_profile_write_config rewrites per worktree. Declared so grove never counts its own
# rewrite as the session's work — otherwise a project that TRACKS this file has every worktree read
# as permanently dirty, and the remove hook then refuses to release the slot for ever.
GROVE_CONFIG_FILE="docroot/configuration.php"

GROVE_PATHS=(
	# Media the site serves and the session may add to. Big, and free on APFS.
	"docroot/images:clone"

	# Created, never copied — and each for its own reason. A cloned cache holds the OTHER site's
	# compiled absolute paths. tmp holds its half-finished uploads, sessions and locks, some of which
	# Joomla treats as real state. Logs are the worst of the three: the first thing anyone does with a
	# fresh site is read the log to find out why it misbehaves, and entries from another site,
	# timestamped before this worktree existed, send you debugging a problem that was never yours.
	"docroot/cache:empty"
	"docroot/tmp:empty"
	"docroot/logs:empty"
	"docroot/administrator/cache:empty"
	"docroot/administrator/logs:empty"
)

# Joomla names its database in configuration.php, which is gitignored and therefore absent from a
# fresh worktree.
grove_profile_main_db() { # <main-root>
	sed -nE "s/^[[:space:]]*public \\\$db = '([^']*)'.*/\1/p" "$1/docroot/configuration.php" 2>/dev/null | head -1
}

# configuration.php carries the database name AND absolute paths, so it is rewritten rather than
# copied: same install, different database, different docroot inside the container. The sitename gets
# the worktree's name appended so the admin UI says out loud which site you are looking at.
grove_profile_write_config() { # <main-root> <wt-path> <name> <db> <local-host> <container-dir>
	local main_root="$1" wt="$2" name="$3" db="$4" container_dir="$6"
	[ -f "$main_root/docroot/configuration.php" ] || return 1
	sed -E \
		-e "s|^([[:space:]]*public \\\$db = ')[^']*(';)|\1$db\2|" \
		-e "s|$CONTAINER_ROOT/$GROVE_DOCROOT|$container_dir/$GROVE_DOCROOT|g" \
		-e "s|^([[:space:]]*public \\\$sitename = ')([^']*)(';)|\1\2 [$name]\3|" \
		"$main_root/docroot/configuration.php" >"$wt/docroot/configuration.php" 2>/dev/null
}

# Joomla's SEF rewrites plus its REST API endpoint. Kept deliberately close to a stock Joomla vhost so
# a worktree site behaves exactly like the real one.
grove_profile_nginx_locations() {
	cat <<'EOF'
    location / {
        absolute_redirect off;
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    # Joomla 4+ REST API
    location /api/ {
        try_files $uri $uri/ /api/index.php?$query_string;
    }
EOF
}
