#!/usr/bin/env bash
# shellcheck disable=SC2034   # a profile exists to SET defaults; the engine is what reads them
#
# Profile: magento2 — served from pub/, with the build output kept out of the file sync.
#
# This is the profile the `container` strategy was designed for, so the reasoning is worth having in
# front of you: a Magento vendor/ is around 80 thousand files. Cloning it host-side is instant on
# APFS — and then the file sync has to notice all 80k, propagate them into the container, and watch
# them for the life of the worktree. THAT is the real cost of a Magento worktree, and it is paid per
# worktree. Copying vendor/ and generated/ where they already live (inside the container) and
# excluding them from the sync removes both the propagation and the ongoing watch.
#
# The exclusion is not configured separately; grove derives it from these two lines.

GROVE_DOCROOT="pub"

GROVE_PATHS=(
	"pub/media:clone"

	# Created, never copied: a cloned var/cache holds the other site's compiled configuration and
	# absolute paths, and pub/static holds its deployed theme files under content-hashed names.
	"var/cache:empty"
	"var/log:empty"
	"var/page_cache:empty"
	"var/session:empty"
	"pub/static:empty"

	# The two that earn the design. Copied INSIDE the container and excluded from sync.
	#
	# Set "vendor:fresh" in a project's .grove.conf to run `composer install` in the worktree instead.
	# The copy is fast and almost always right; it does couple the worktree to whatever the main
	# checkout had at that moment, which occasionally matters.
	"vendor:container"
	"generated:container"

	"node_modules:link"
)

# Magento names its database in app/etc/env.php.
grove_profile_main_db() { # <main-root>
	sed -nE "s/.*'dbname'[[:space:]]*=>[[:space:]]*'([^']*)'.*/\1/p" "$1/app/etc/env.php" 2>/dev/null | head -1
}

# env.php is rewritten for the database name only. Magento keeps its base URLs in core_config_data,
# which grove_db_seed already rewrote while the dump went past — so there is nothing else here that
# points at the main site.
grove_profile_write_config() { # <main-root> <wt-path> <name> <db> <local-host> <container-dir>
	local main_root="$1" wt="$2" db="$4"
	[ -f "$main_root/app/etc/env.php" ] || return 1
	mkdir -p "$wt/app/etc" 2>/dev/null
	sed -E "s|('dbname'[[:space:]]*=>[[:space:]]*')[^']*(')|\1$db\2|" \
		"$main_root/app/etc/env.php" >"$wt/app/etc/env.php" 2>/dev/null
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
