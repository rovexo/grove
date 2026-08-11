#!/usr/bin/env bash
# shellcheck disable=SC2034   # a profile exists to SET defaults; the engine is what reads them
#
# Profile: magento2 — served from pub/, with the build output kept out of the file sync.
#
# This is the profile the `container` strategy was designed for, so the reasoning is worth having in
# front of you, measured rather than assumed. The two Magento checkouts this was built against carry
# 90,093 and 79,252 files in vendor/.
#
# "Copy-on-write makes it free" is HALF TRUE and the half that is false is the expensive half: `cp -c`
# shares the data blocks, but it still has to create 79k directory entries and inodes, which timed at
# 52-60 SECONDS — not the "instant" the first draft of this design claimed. And that is only the
# beginning of the cost, because those 79k files then enter the file sync's watch set, per worktree,
# for as long as the worktree exists.
#
# Copying them inside the container instead timed at 45 seconds for the same tree — comparable up
# front, and it adds NOTHING to the sync set. That ongoing difference is the whole argument; the
# one-off numbers are close enough to be a wash.
#
# The exclusion is not configured separately; grove derives it from the two `container` lines below.
#
# EVERY PATH IS RELATIVE TO $GROVE_APP — the application root, as a prefix. Magento is not always at
# the repository root: one project here is a Magento checkout, another keeps Magento under docroot/
# with the repo holding tests and tooling alongside it. That single prefix is the whole difference
# between them, and it has to be a variable or this profile is wrong for one of the two:
#
#     GROVE_APP_ROOT="docroot"     # in .grove.conf, for the nested layout. Default: the repo root.

GROVE_DOCROOT="${GROVE_APP}pub"
GROVE_CONFIG_FILE="${GROVE_APP}app/etc/env.php"

GROVE_PATHS=(
	"${GROVE_APP}pub/media:clone"

	# Created, never copied: a cloned var/cache holds the other site's compiled configuration and
	# absolute paths, and pub/static holds its deployed theme files under content-hashed names.
	"${GROVE_APP}var/cache:empty"
	"${GROVE_APP}var/log:empty"
	"${GROVE_APP}var/page_cache:empty"
	"${GROVE_APP}var/session:empty"
	"${GROVE_APP}var/report:empty"
	"${GROVE_APP}pub/static:empty"

	# The two that earn the design. Copied INSIDE the container and excluded from sync.
	#
	# Set "vendor:fresh" in a project's .grove.conf to run `composer install` in the worktree instead.
	# The copy is fast and almost always right; it does couple the worktree to whatever the main
	# checkout had at that moment, which occasionally matters.
	"${GROVE_APP}vendor:container"
	"${GROVE_APP}generated:container"

	"${GROVE_APP}node_modules:link"
)

# Magento names its database in app/etc/env.php.
grove_profile_main_db() { # <main-root>
	sed -nE "s/.*'dbname'[[:space:]]*=>[[:space:]]*'([^']*)'.*/\1/p" "$1/${GROVE_APP}app/etc/env.php" 2>/dev/null | head -1
}

# env.php is rewritten for the database name only. Magento keeps its base URLs in core_config_data,
# which grove_db_seed already rewrote while the dump went past — so there is nothing else here that
# points at the main site.
#
# The cache and session prefixes ARE rewritten too where present: two Magento sites sharing one Redis
# or Memcached with the same prefix read each other's cached configuration, which presents as a
# worktree mysteriously serving the main site's settings.
grove_profile_write_config() { # <main-root> <wt-path> <name> <db> <local-host> <container-dir>
	local main_root="$1" wt="$2" name="$3" db="$4"
	local src="$main_root/${GROVE_APP}app/etc/env.php"
	[ -f "$src" ] || return 1
	mkdir -p "$wt/${GROVE_APP}app/etc" 2>/dev/null
	sed -E \
		-e "s|('dbname'[[:space:]]*=>[[:space:]]*')[^']*(')|\1$db\2|" \
		-e "s|('id_prefix'[[:space:]]*=>[[:space:]]*')[^']*(')|\1${name}_\2|" \
		"$src" >"$wt/${GROVE_APP}app/etc/env.php" 2>/dev/null
}

grove_profile_nginx_locations() {
	cat <<'EOF'
    location / {
        absolute_redirect off;
        try_files $uri $uri/ /index.php?$query_string;
    }

    location /static/ {
        # Magento's static content is versioned in the path; strip the version and let the front
        # controller generate the file on first request.
        location ~ ^/static/version\d*/ {
            rewrite ^/static/version\d*/(.*)$ /static/$1 last;
        }
        try_files $uri $uri/ /static.php?resource=$uri&$query_string;
    }

    location /media/ {
        try_files $uri $uri/ /get.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
EOF
}
