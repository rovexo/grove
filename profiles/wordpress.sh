#!/usr/bin/env bash
# shellcheck disable=SC2034   # a profile exists to SET defaults; the engine is what reads them
#
# Profile: wordpress — served from a docroot/ subdirectory.
#
# Sourced BEFORE the project's .grove.conf, so everything here is a default.

GROVE_DOCROOT="docroot"
GROVE_CONFIG_FILE="docroot/wp-config.php"

GROVE_PATHS=(
	# The media library: whatever the site has been given, which a session may add to.
	"docroot/wp-content/uploads:clone"

	# Created, never copied. A cloned page cache serves the other site's fully-rendered HTML —
	# including its URLs — which reads as "my worktree is showing the wrong site".
	"docroot/wp-content/cache:empty"
	"docroot/wp-content/upgrade:empty"
)

grove_profile_main_db() { # <main-root>
	sed -nE "s/^[[:space:]]*define\([[:space:]]*'DB_NAME'[[:space:]]*,[[:space:]]*'([^']*)'.*/\1/p" \
		"$1/docroot/wp-config.php" 2>/dev/null | head -1
}

# wp-config.php names the database. WP_HOME and WP_SITEURL are rewritten too WHEN THEY ARE THERE:
# defining them wins over whatever is in the options table, so a worktree that inherits the main
# site's pair redirects straight back to the main site — the exact cross-contamination the isolation
# exists to prevent. Sites that do not define them are served by the seeded wp_options rows, which
# grove_db_seed already rewrote on the way through.
grove_profile_write_config() { # <main-root> <wt-path> <name> <db> <local-host> <container-dir>
	local main_root="$1" wt="$2" db="$4" local_host="$5"
	[ -f "$main_root/docroot/wp-config.php" ] || return 1
	sed -E \
		-e "s|(define\([[:space:]]*'DB_NAME'[[:space:]]*,[[:space:]]*')[^']*(')|\1$db\2|" \
		-e "s|(define\([[:space:]]*'WP_HOME'[[:space:]]*,[[:space:]]*')[^']*(')|\1https://$local_host\2|" \
		-e "s|(define\([[:space:]]*'WP_SITEURL'[[:space:]]*,[[:space:]]*')[^']*(')|\1https://$local_host\2|" \
		"$main_root/docroot/wp-config.php" >"$wt/docroot/wp-config.php" 2>/dev/null
}

grove_profile_nginx_locations() {
	cat <<'EOF'
    location / {
        absolute_redirect off;
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
EOF
}
