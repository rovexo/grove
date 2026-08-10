#!/usr/bin/env bash
#
# The worktree engine: build, list, land and release per-worktree dev sites.
#
# Sourced by bin/grove after lib/config.sh, so every GROVE_* setting and every profile default is
# already resolved by the time anything here runs.
#
# THE ONE IDEA. Every path a worktree needs declares HOW it comes to exist — not whether it is
# copied. Five strategies cover what four hand-written implementations used to express as two
# hardcoded lists (things to `cp`, things to `mkdir`) plus exceptions bolted on the side:
#
#   clone      copy-on-write clone from the main checkout (`cp -c`), host-side
#   empty      the directory is created, its contents are never copied
#   link       a RELATIVE symlink to the main checkout
#   container  copied INSIDE the container, and excluded from file sync
#   fresh      not created; a GROVE_POST_CREATE command produces it
#   skip       not created at all
#
# `container` is the one that earns the design. A Magento vendor/ is ~80k files: cloning it host-side
# is instant on APFS, but then the file sync has to notice and propagate all 80k into the container,
# and watch them forever after. Copying it where it already lives and excluding it from sync removes
# both costs — and because the exclusion is DERIVED from the strategy rather than configured next to
# it, the two cannot drift apart.

# --- where things are -----------------------------------------------------------------------------

# The MAIN checkout, even when grove is invoked from inside a worktree. `--git-common-dir` points at
# the shared .git in every worktree, so its parent is the main working tree — unlike --show-toplevel,
# which answers the worktree you happen to be standing in.
#
# EVERY git and stack call below runs against this, never against $PWD. That is what makes `grove
# merge` safe to run from inside the worktree it is landing, which is where a session naturally is.
grove_main_root() {
	local common
	common="$(git -C "${1:-$PROJECT_ROOT}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
		printf '%s' "$PROJECT_ROOT"; return 0
	}
	[ -n "$common" ] || { printf '%s' "$PROJECT_ROOT"; return 0; }
	(cd "$(dirname "$common")" && pwd)
}

MAIN_ROOT="$(grove_main_root "$PROJECT_ROOT")"
WORKTREES_DIR="$MAIN_ROOT/$WORKTREES_REL"

# Both the stack CLI and git resolve "which project?" from the caller's working directory. Run from
# a sibling repo's directory they silently target THAT project — a list run with the wrong cwd once
# read another project's MySQL and reported this project's databases missing. Pin it, once.
cd "$MAIN_ROOT" 2>/dev/null || true

# --- logging --------------------------------------------------------------------------------------
# Hook stdout is reserved (WorktreeCreate's stdout IS the worktree path) and hook stderr surfaces in
# the session as an error, so a log file is the only place a trace can go without either breaking the
# contract or alarming the user.
GROVE_LOG_FILE="$MAIN_ROOT/${GROVE_LOG:-gitignored/grove-worktrees.log}"

grove_log() {
	mkdir -p "$(dirname "$GROVE_LOG_FILE")" 2>/dev/null || return 0
	printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${GROVE_TAG:-grove}" "$*" >>"$GROVE_LOG_FILE" 2>/dev/null || true
}

# --- naming -----------------------------------------------------------------------------------------
# A worktree's name is the single input every other name is derived from. With NAMING="slots" it is
# wt1…wtN, which is what lets one static vhost serve every worktree: the name is in the hostname and
# the path, so routing needs no per-worktree state. The session's own descriptive name survives on
# the branch.

grove_wt_dir()   { printf '%s/%s' "$WORKTREES_DIR" "$1"; }
grove_wt_docroot() { if [ -n "$DOCROOT" ]; then printf '%s/%s' "$(grove_wt_dir "$1")" "$DOCROOT"; else grove_wt_dir "$1"; fi; }

# The container's view of a worktree. Worktrees live inside the project directory, which the stack
# already mounts, so this needs no extra mount and no symlink.
grove_wt_container_dir() { printf '%s/%s/%s' "$CONTAINER_ROOT" "$WORKTREES_REL" "$1"; }

# Public: one label under the zone. NOT wt1.project.zone — DNS and TLS wildcards match exactly one
# label, so a two-level name is reachable by neither the wildcard record nor the wildcard
# certificate. Everything flat, always.
grove_wt_host()  { printf '%s-%s.%s' "$1" "$PROJECT" "$ZONE"; }
grove_wt_local_host() { printf '%s-%s.%s' "$PROJECT" "$1" "$LOCAL_ZONE"; }
grove_wt_url()   { if [ -n "$ZONE" ]; then printf 'https://%s' "$(grove_wt_host "$1")"; else printf 'https://%s' "$(grove_wt_local_host "$1")"; fi; }

# MySQL identifiers cannot carry a hyphen unquoted, and free-form worktree names can. Sanitise once,
# here, so no caller has to remember to quote.
grove_wt_db() { printf '%s%s' "${GROVE_DB_PREFIX:-}" "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9_' '_')"; }

grove_main_host() { printf '%s.%s' "$PROJECT" "$LOCAL_ZONE"; }

# Is this directory an actual worktree of this repository, or just a directory sitting where one used
# to be?
#
# THE DIRECTORY EXISTING IS NOT THE SAME AS THE SLOT BEING TAKEN. Removing a worktree deletes the
# directory, but anything watching the filesystem recreates it moments later — PhpStorm has done
# exactly that, writing .idea/workspace.xml into a path that had just been torn down. Keying "in use"
# off `-d` then costs that slot permanently.
#
# `git worktree list --porcelain` is the authority. Matching the WHOLE line keeps `wt1` from matching
# `wt10`.
grove_is_worktree() {
	local dir="$1"
	[ -d "$dir" ] || return 1
	git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $dir"
}

# Does this worktree still hold work? Prints every dirty entry, or nothing when it is clean.
#
# THIS IS LOAD-BEARING, not cosmetic. The WorktreeRemove hook refuses to release a worktree that
# still holds work — so anything grove ITSELF created that reads as "work" occupies a slot forever
# and nothing ever gives it back.
#
# Three groups are excluded, each for its own reason:
#
#   grove's own files   the two notes, the provisioning marker, the metadata, and the hook config it
#                       syncs in from the main checkout.
#   declared paths      every path in GROVE_PATHS, but ONLY when git reports it as untracked (`??`).
#                       grove created those, so they are not the session's doing. Restricting the
#                       exclusion to untracked entries is what keeps it honest: if a project declares
#                       a path that is actually tracked, a real modification inside it still counts.
#                       (The symlink a `link` strategy makes is the case that forced this — a
#                       .gitignore of `/node_modules/` matches a directory and NOT a symlink, so the
#                       link grove just made showed up as the session's untracked work.)
#   the submodule path  always reads as modified from the outer worktree: it holds a LINKED WORKTREE
#                       of the submodule repo, not the checkout the gitlink expects. The submodule's
#                       own status is checked separately by the caller.
grove_worktree_dirty() {
	local wt="$1" line status path rel keep

	git -C "$wt" status --porcelain 2>/dev/null | while IFS= read -r line; do
		[ -n "$line" ] || continue
		status="$(printf '%s' "$line" | cut -c1-2)"
		path="$(printf '%s' "$line" | cut -c4-)"
		path="${path%/}"

		case "$path" in
		WORKTREE-SITE.md|CLAUDE.local.md|.grove-meta|.grove-provision-pending|.grove-provision-lock) continue ;;
		.claude/settings.json|.claude/hooks|.claude/hooks/*) continue ;;
		esac
		if [ -n "$SUBMODULE" ] && [ "$path" = "$SUBMODULE" ]; then continue; fi

		if [ "$status" = "??" ]; then
			keep=1
			while IFS= read -r rel; do
				[ -n "$rel" ] || continue
				case "$path" in "$rel"|"$rel"/*) keep=0; break ;; esac
			done <<EOF
$(grove_each_path | cut -f1)
EOF
			[ "$keep" -eq 0 ] && continue
		fi

		printf '%s\n' "$line"
	done
}

# --- the path strategies ------------------------------------------------------------------------
# GROVE_PATHS is an array of "path:strategy" because paths carry slashes and therefore cannot be
# variable names. LAST ENTRY PER PATH WINS, so a project overrides one line of a profile by
# appending one line — no merge semantics, no restating the list.

# Prints "path<TAB>strategy" for each path, de-duplicated to the last entry, in declaration order so
# a parent is always created before its child. Index-addressed rather than "${arr[@]}"-expanded:
# bash 3.2 errors on expanding an empty array under `set -u`.
grove_each_path() {
	local n i j p s dup
	n="${#GROVE_PATHS[@]}"
	i=0
	while [ "$i" -lt "$n" ]; do
		p="${GROVE_PATHS[$i]%%:*}"
		s="${GROVE_PATHS[$i]#*:}"
		dup=0
		j=$((i + 1))
		while [ "$j" -lt "$n" ]; do
			[ "${GROVE_PATHS[$j]%%:*}" = "$p" ] && { dup=1; break; }
			j=$((j + 1))
		done
		[ "$dup" -eq 0 ] && [ -n "$p" ] && [ "$p" != "$s" ] && printf '%s\t%s\n' "$p" "$s"
		i=$((i + 1))
	done
}

# Every path declared `container`. The sync exclusion is generated from this and nothing else, which
# is the point: one fact, one place, impossible to get out of step with the copy that needs it.
grove_container_paths() { grove_each_path | awk -F'\t' '$2 == "container" { print $1 }'; }

# --- keeping grove's own creations out of git -------------------------------------------------------
#
# NOT optional, and not tidiness. Every path grove creates is local runtime data — but git does not
# know that, so an ordinary `git add -A` in a worktree stages it and the next merge carries it into
# the MAIN CHECKOUT. For a `link` path that is destructive rather than merely untidy: the merge
# replaces the main checkout's real directory with a symlink pointing at itself.
#
# The trap is easy to walk into because a .gitignore usually looks like it covers this already —
# `/node_modules/` with a trailing slash matches a DIRECTORY and not the SYMLINK grove puts there,
# so the one path where the consequence is worst is the one most likely to slip through.
#
# So grove states the rules itself, in git's own mechanism for local ignores. The block is written to
# the SHARED info/exclude (all worktrees and the main checkout resolve to the same file), which is
# right: these paths are local data in every checkout, not just in a worktree. Ignore rules never
# affect TRACKED files, so a project that genuinely tracks something under a declared path is
# unaffected.
GROVE_EXCLUDE_BEGIN="# >>> grove: paths grove creates in worktrees. Managed block — do not edit inside the markers."
GROVE_EXCLUDE_END="# <<< grove"

grove_write_excludes() {
	local ex tmp rel
	ex="$(git -C "$MAIN_ROOT" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null)" || return 0
	[ -n "$ex" ] || return 0
	mkdir -p "$(dirname "$ex")" 2>/dev/null

	tmp="$(mktemp)" || return 0
	# Drop any previous block, then append the current one — so a changed path list replaces rather
	# than accumulates.
	if [ -f "$ex" ]; then
		awk -v b="$GROVE_EXCLUDE_BEGIN" -v e="$GROVE_EXCLUDE_END" '
			$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }
		' "$ex" >"$tmp"
	fi
	{
		printf '%s\n' "$GROVE_EXCLUDE_BEGIN"
		printf '/%s/\n' "${WORKTREES_REL#/}"
		printf '/WORKTREE-SITE.md\n/CLAUDE.local.md\n/.grove-meta\n/.grove-provision-pending\n/.grove-provision-lock\n'
		while IFS= read -r rel; do
			[ -n "$rel" ] || continue
			printf '/%s\n' "$rel"
		done <<EOF
$(grove_each_path | cut -f1)
EOF
		printf '%s\n' "$GROVE_EXCLUDE_END"
	} >>"$tmp"
	cat "$tmp" >"$ex" 2>/dev/null
	rm -f "$tmp"
	grove_log "refreshed the managed ignore block in $ex"
}

# Would merging this branch change a path grove manages? If so the merge must not proceed: those
# paths hold each checkout's OWN local data, and carrying one checkout's copy into another is at best
# meaningless and at worst destructive (see grove_write_excludes). This catches the case the ignore
# block cannot — a branch that already committed such a path before grove was wired in.
grove_merge_touches_managed() { # <branch>  -> prints the offending paths
	local branch="$1" changed rel
	changed="$(git -C "$MAIN_ROOT" diff --name-only "HEAD...$branch" 2>/dev/null)"
	[ -n "$changed" ] || return 0
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		printf '%s\n' "$changed" | awk -v p="$rel" '$0 == p || index($0, p "/") == 1 { print }'
	done <<EOF
$(grove_each_path | cut -f1)
EOF
}

# Apply one path's strategy into a freshly created worktree. Never fatal: a worktree missing an
# upload directory is a degraded site, not a broken checkout.
grove_apply_path() { # <wt-path> <rel> <strategy>
	local wt="$1" rel="$2" strategy="$3" src="$MAIN_ROOT/$2" dst="$1/$2"

	case "$strategy" in
	clone)
		[ -e "$src" ] || { grove_log "clone: $rel does not exist in the main checkout — skipped"; return 0; }
		if [ -d "$src" ]; then
			mkdir -p "$dst" 2>/dev/null
			# The `src/.` form MERGES into an existing destination. A plain `cp -R src dst` would
			# nest src INSIDE dst when dst already exists — which is how a port once lost its
			# credentials file. -c asks APFS for a copy-on-write clone, so a 60 MB directory is
			# free; it is ignored on filesystems that cannot do it, hence the plain-cp fallback.
			cp -Rc "$src/." "$dst/" 2>/dev/null || cp -R "$src/." "$dst/" 2>/dev/null \
				|| grove_log "WARN: could not clone $rel"
		else
			mkdir -p "$(dirname "$dst")" 2>/dev/null
			cp -c "$src" "$dst" 2>/dev/null || cp "$src" "$dst" 2>/dev/null \
				|| grove_log "WARN: could not clone $rel"
		fi
		;;
	empty)
		mkdir -p "$dst" 2>/dev/null || grove_log "WARN: could not create $rel"
		# Belt and braces: if some parent path's clone dragged content in, empty it rather than ship
		# a worktree that lies about its own history. Inheriting a cache means the other site's
		# compiled absolute paths; inheriting tmp means its half-finished uploads and locks; and
		# inheriting logs is the worst of the three, because the first thing anyone does with a fresh
		# site is read the log to find out why it misbehaves — entries from another site, timestamped
		# before this worktree existed, send you debugging a problem that was never yours.
		# Truncate rather than delete, so ownership and permissions survive.
		find "$dst" -type f ! -name 'index.html' ! -name '.htaccess' ! -name '.gitkeep' \
			-exec sh -c ': > "$1"' _ {} \; 2>/dev/null
		;;
	link)
		[ -e "$src" ] || { grove_log "link: $rel does not exist in the main checkout — skipped"; return 0; }
		[ -e "$dst" ] && return 0
		mkdir -p "$(dirname "$dst")" 2>/dev/null
		# RELATIVE, always. File sync carries symlinks verbatim, so an absolute /Users/... target is
		# broken the moment it is read inside the container.
		local up depth i
		depth="$(printf '%s' "$WORKTREES_REL/x/$rel" | awk -F/ '{print NF-1}')"
		up=""; i=0
		while [ "$i" -lt "$depth" ]; do up="../$up"; i=$((i + 1)); done
		ln -s "${up}${rel}" "$dst" 2>/dev/null || grove_log "WARN: could not link $rel"
		;;
	container)
		# Host-side: nothing at all, deliberately. The copy happens inside the container, and the
		# sync is told to ignore the path so it never carries those files either way.
		mkdir -p "$dst" 2>/dev/null
		;;
	fresh)
		# Produced by a GROVE_POST_CREATE command (composer install and friends) rather than copied.
		;;
	skip) ;;
	*)
		grove_log "WARN: unknown strategy '$strategy' for $rel — treated as skip"
		;;
	esac
}

# --- the stack ------------------------------------------------------------------------------------
# One indirection over "what runs this project's site", so `none` is a real answer rather than a
# broken one: worktrees, branches and merges work identically without a container; there is simply no
# database to seed and no URL to hand out.

grove_stack_running() {
	case "$STACK" in
	ddev)
		command -v ddev >/dev/null 2>&1 || return 1
		[ "$(ddev describe -j 2>/dev/null | jq -r '.raw.status // empty' 2>/dev/null)" = "running" ]
		;;
	none) return 1 ;;
	*)    return 1 ;;
	esac
}

# Run a command inside the stack's web container.
grove_stack_exec() { # <shell command>
	case "$STACK" in
	ddev) (cd "$MAIN_ROOT" && ddev exec bash -c "$1") ;;
	*)    return 1 ;;
	esac
}

# --- databases --------------------------------------------------------------------------------------
#
# Every call goes through the stack's own export/import/mysql with host-side pipes and stdin. That is
# not a style preference: `ddev exec bash -c "mysql -e \"…\`db\`…\""` puts three shells between here
# and MySQL, and the backticks MySQL wants around an identifier are command substitution to two of
# them. A hook lost its database to exactly that.

# The database the MAIN site uses. A profile that can read it from the platform's config file defines
# grove_profile_main_db; otherwise the stack's default database name is the right answer.
grove_main_db() {
	if command -v grove_profile_main_db >/dev/null 2>&1; then
		local db; db="$(grove_profile_main_db "$MAIN_ROOT")"
		[ -n "$db" ] && { printf '%s' "$db"; return 0; }
	fi
	printf '%s' "${GROVE_MAIN_DB:-db}"
}

grove_db_exists() { # <name>
	case "$STACK" in
	ddev)
		[ "$(printf "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='%s';\n" "$1" \
			| (cd "$MAIN_ROOT" && ddev mysql -uroot -proot -N 2>/dev/null) | tr -d '[:space:]')" = "1" ]
		;;
	*) return 1 ;;
	esac
}

# Copy the main site's database into a worktree's own, rewriting the site's hostname on the way
# through. Platforms store their own base URL in the database (Joomla/ConfigBox in a settings table,
# WordPress in wp_options, Magento in core_config_data); left alone, the worktree site would send
# visitors — and tests — straight back to the shared site.
grove_db_seed() { # <name>
	local wt="$1" db main_db
	db="$(grove_wt_db "$wt")"; main_db="$(grove_main_db)"

	case "$DB_SEED" in
	none) return 0 ;;
	empty)
		case "$STACK" in
		ddev) printf 'CREATE DATABASE IF NOT EXISTS %s;\n' "$db" | (cd "$MAIN_ROOT" && ddev mysql -uroot -proot >/dev/null 2>&1) ;;
		*) return 1 ;;
		esac
		return $?
		;;
	esac

	# The hostname rewrites, built up rather than written inline: the PUBLIC one only exists when this
	# project has a zone. Without that guard a worktree-only project (no GROVE_ZONE) would substitute
	# on the pattern "project." — where the trailing dot is a regex ANY-CHARACTER — and rewrite every
	# occurrence of the project's name throughout the dump. A corrupted database is a bad way to find
	# out that a setting was empty.
	local rewrite pub
	rewrite="s/$(grove_re "$(grove_main_host)")/$(grove_wt_local_host "$wt")/g"
	if [ -n "$ZONE" ]; then
		pub="${GROVE_MAIN_PUBLIC_HOST:-$PROJECT.$ZONE}"
		rewrite="$rewrite;s/$(grove_re "$pub")/$(grove_wt_host "$wt")/g"
	fi

	case "$STACK" in
	ddev)
		(cd "$MAIN_ROOT" && ddev export-db --database="$main_db" --gzip=false 2>/dev/null) \
			| sed -e "$rewrite" \
			| (cd "$MAIN_ROOT" && ddev import-db --database="$db" >/dev/null 2>&1)
		;;
	*) return 1 ;;
	esac
}

grove_db_drop() { # <name>
	case "$STACK" in
	ddev) printf 'DROP DATABASE IF EXISTS %s;\n' "$(grove_wt_db "$1")" | (cd "$MAIN_ROOT" && ddev mysql -uroot -proot >/dev/null 2>&1) ;;
	*) return 1 ;;
	esac
}

# --- container-side work ----------------------------------------------------------------------------

# Is this path genuinely excluded from the stack's file sync? Checked against the file grove itself
# writes, so the answer is about what the stack is actually configured to do rather than what the
# .grove.conf intended. A stack with no sync at all (a plain bind mount) answers no, correctly: there
# the container and the host are the same files and nothing can be excluded from anything.
grove_sync_excluded() { # <rel>
	case "$STACK" in
	ddev)
		[ -f "$MAIN_ROOT/.ddev/mutagen/mutagen.yml" ] || return 1
		grep -qF "\"/$WORKTREES_REL/*/$1\"" "$MAIN_ROOT/.ddev/mutagen/mutagen.yml" 2>/dev/null
		;;
	*) return 1 ;;
	esac
}

# Delete a worktree's whole directory INSIDE the container.
#
# Removing the worktree host-side is not enough, and the reason is the `container` strategy itself:
# the file sync has been told to ignore those paths, so it will not carry their deletion either — and
# it refuses to remove a directory tree that still holds ignored content, which strands the ENTIRE
# worktree in the container rather than just the excluded path.
#
# Two consequences, one of them a correctness bug rather than mere waste. The obvious one is garbage:
# a Magento vendor/ per abandoned worktree, forever. The sharp one is that the vhost keeps serving
# that stale copy at its URL, and the next session handed the same slot would be looking at the
# previous session's files.
#
# The path is rebuilt here from CONTAINER_ROOT and the name rather than taken from a caller, and
# refuses anything that is not inside the worktrees directory: this is an `rm -rf` running as root
# inside a container that has the project mounted.
grove_container_purge() { # <name>
	local name="$1" cdir base
	[ -n "$name" ] || return 1
	case "$name" in */*|.|..|"") return 1 ;; esac
	grove_stack_running || return 0
	base="$CONTAINER_ROOT/$WORKTREES_REL"
	cdir="$base/$name"
	grove_stack_exec "case '$cdir' in '$base'/?*) rm -rf '$cdir' ;; *) exit 1 ;; esac" >/dev/null 2>&1 \
		|| { grove_log "WARN: could not purge the container-side copy at $cdir"; return 1; }
	grove_log "purged the container-side directory $cdir"
}

# Copy every `container` path from the main checkout's in-container location into the worktree's.
# Fast, because it never leaves the container; and the files are excluded from sync, so nothing
# propagates back out.
grove_container_copies() { # <name>
	local wt="$1" rel cdir cmd all=0
	cdir="$(grove_wt_container_dir "$wt")"
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue

		# THE COPY IS DESTRUCTIVE, AND ONLY SAFE BECAUSE THE PATH IS EXCLUDED FROM SYNC. The `rm -rf`
		# below runs inside the container; if the path is still synced, that deletion propagates
		# straight back to the host — the same mechanism that made an early version of this delete a
		# freshly checked-out worktree. And where the project directory is bind-mounted rather than
		# synced, container-side and host-side are the SAME FILES, so it deletes them outright.
		#
		# Both cases are ordinary: a project that ran `grove create` before `grove wire`, or added a
		# `container` path without re-wiring. So the exclusion is verified rather than assumed, and a
		# path that cannot be verified is skipped with an instruction rather than risked.
		if ! grove_sync_excluded "$rel"; then
			grove_log "REFUSING the container-side copy of $rel — it is not excluded from file sync"
			printf 'grove: %s is declared `container` but is not excluded from file sync.\n' "$rel" >&2
			printf '       Copying it container-side would propagate back to the host (or, on a\n' >&2
			printf '       bind-mounted stack, delete the host files outright). Run: grove wire\n' >&2
			all=1
			continue
		fi

		# Cleared first rather than merged into: a slot can be reused, and `cp -a` over a previous
		# session's tree would leave that session's files behind wherever the new one has none.
		cmd="rm -rf '$cdir/$rel' && mkdir -p '$cdir/$rel' && cp -a '$CONTAINER_ROOT/$rel/.' '$cdir/$rel/' 2>/dev/null"
		if grove_stack_exec "$cmd" >/dev/null 2>&1; then
			grove_log "container-side copy: $rel"
		else
			grove_log "WARN: container-side copy of $rel failed"
			all=1
		fi
	done <<EOF
$(grove_container_paths)
EOF
	return "$all"
}

# Create every `empty` path INSIDE the container as well.
#
# Not redundant with the host-side mkdir. A path the file sync ignores is one the sync will not
# CREATE either, so the empty directories made host-side never appear in the container — and an app
# running with no tmp and no cache fails three layers away from anything naming the sync. Cheap
# enough to do unconditionally rather than trying to work out which paths are ignored.
grove_container_runtime_dirs() { # <name>
	local wt="$1" rel cdir dirs=""
	cdir="$(grove_wt_container_dir "$wt")"
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		dirs="$dirs '$cdir/$rel'"
	done <<EOF
$(grove_each_path | awk -F'\t' '$2 == "empty" { print $1 }')
EOF
	[ -n "$dirs" ] || return 0
	grove_stack_exec "mkdir -p $dirs && chmod 0777 $dirs" >/dev/null 2>&1
}

# --- the site config -------------------------------------------------------------------------------

# A platform's own config file (configuration.php, wp-config.php, app/etc/env.php) names the database
# and, on some platforms, absolute paths — so it is REWRITTEN for the worktree, never copied. The
# profile owns the rewrite; a profile that has nothing to rewrite defines nothing and this is a no-op.
grove_write_site_config() { # <name>
	command -v grove_profile_write_config >/dev/null 2>&1 || return 0
	grove_profile_write_config \
		"$MAIN_ROOT" "$(grove_wt_dir "$1")" "$1" "$(grove_wt_db "$1")" \
		"$(grove_wt_local_host "$1")" "$(grove_wt_container_dir "$1")"
}

# --- per-worktree metadata --------------------------------------------------------------------------
# A small file at the worktree root recording what created it. `list` and `info` read it back rather
# than re-deriving facts from the filesystem, and the transcript path it carries is what lets `list`
# say how long the owning session has been idle without scraping a log.
GROVE_META=".grove-meta"

grove_meta_write() { # <wt-path> <key> <value>...
	local wt="$1"; shift
	printf '%s\n' "$*" >>"$wt/$GROVE_META" 2>/dev/null || true
}

grove_meta_get() { # <wt-path> <key>
	[ -f "$1/$GROVE_META" ] || return 1
	sed -n "s/^$2=//p" "$1/$GROVE_META" 2>/dev/null | tail -1
}

# --- create -------------------------------------------------------------------------------------
#
# Sets GROVE_NEW_NAME / GROVE_NEW_PATH / GROVE_NEW_BRANCH and prints NOTHING to stdout — the
# WorktreeCreate hook's stdout is the worktree path and must carry nothing else, so every caller
# decides for itself what to say.

grove_allocate() { # <slug> -> echoes the worktree name
	local slug="$1" i candidate

	if [ "$NAMING" != "slots" ]; then
		printf '%s' "$slug"
		return 0
	fi

	i=1
	while [ "$i" -le "$SLOTS" ]; do
		candidate="wt$i"
		# `-e` rather than grove_is_worktree: a leftover directory must not be handed out either,
		# because `git worktree add` would refuse it. `list` reports those so they can be cleared.
		if [ ! -e "$(grove_wt_dir "$candidate")" ]; then
			printf '%s' "$candidate"
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

grove_slug() { # <raw name>
	local s
	s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
	[ -n "$s" ] || s="session-$$"
	printf '%s' "$s"
}

grove_create() { # <name> [<base-ref>] [<session-id>] [<transcript>]
	local raw="${1:-}" base="${2:-HEAD}" session_id="${3:-}" transcript="${4:-}"
	local slug name wt branch lock_held=0 n add_err

	slug="$(grove_slug "$raw")"
	mkdir -p "$WORKTREES_DIR" || { grove_log "FATAL: cannot create $WORKTREES_DIR"; return 1; }

	# Keep worktrees out of Time Machine. Each is a disposable clone of the checkout and its site,
	# rebuilt on demand from tracked sources — nothing a backup should carry. The exclusion is an
	# xattr on the PARENT and therefore sticky, so every worktree made inside it is covered;
	# re-applying it here is what covers a fresh clone, where the directory did not exist until the
	# line above made it.
	command -v tmutil >/dev/null 2>&1 && tmutil addexclusion "$WORKTREES_DIR" >/dev/null 2>&1

	# Two sessions can ask for isolation in the same instant, so picking a free name and claiming it
	# has to be atomic. mkdir is the portable atomic test-and-set.
	local lock="$WORKTREES_DIR/.alloc.lock"
	n=0
	while [ "$n" -lt 120 ]; do
		if mkdir "$lock" 2>/dev/null; then lock_held=1; break; fi
		sleep 0.5
		n=$((n + 1))
	done
	[ "$lock_held" -eq 1 ] || grove_log "WARN: allocation lock timed out; proceeding without it"

	# Drop registrations whose directory is gone — a worktree removed by hand, or by Claude Code's
	# periodic sweep, which does not fire WorktreeRemove. Without this the slot looks busy forever.
	git -C "$MAIN_ROOT" worktree prune >/dev/null 2>&1
	[ -n "$SUBMODULE" ] && git -C "$MAIN_ROOT/$SUBMODULE" worktree prune >/dev/null 2>&1

	name="$(grove_allocate "$slug")" || name=""
	if [ -z "$name" ]; then
		# Every slot busy. Still give the session an isolated checkout — plenty of work (code, docs,
		# review) needs no running site — it just gets no URL and no database.
		name="noslot-$slug-$$"
		grove_log "all $SLOTS slots in use; creating $name without a site"
	fi
	wt="$(grove_wt_dir "$name")"

	# A reused slot can still hold the previous session's container-side files: the teardown that
	# should have purged them is best-effort (Claude Code's periodic sweep removes worktrees without
	# firing WorktreeRemove at all), and the file sync cannot clear what it is told to ignore.
	#
	# BEFORE the checkout, never after. The sync is bidirectional: deleting the container's copy of a
	# path that EXISTS on the host propagates that deletion straight back, and a purge run after
	# `git worktree add` therefore deletes the files git has just checked out — leaving a directory
	# holding nothing but grove's own creations and a worktree git immediately calls prunable.
	# Allocation only ever returns a name whose host directory does not exist, so here the two sides
	# already agree and there is nothing for the sync to carry.
	grove_container_purge "$name"

	branch="${BRANCH_PREFIX}${slug}"
	n=2
	while git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/heads/$branch"; do
		branch="${BRANCH_PREFIX}${slug}-$n"; n=$((n + 1))
	done

	# Stderr is captured and logged only on failure: a successful add spews checkout progress
	# ("Updating files: NN% …") there, which lands in the log as one unreadable line.
	if ! add_err="$(git -C "$MAIN_ROOT" worktree add -b "$branch" "$wt" "$base" 2>&1 >/dev/null)"; then
		printf '%s\n' "$add_err" | tr '\r' '\n' >>"$GROVE_LOG_FILE" 2>/dev/null
		[ "$lock_held" -eq 1 ] && rmdir "$lock" 2>/dev/null
		grove_log "FATAL: git worktree add failed (base=$base, path=$wt)"
		return 1
	fi
	[ "$lock_held" -eq 1 ] && rmdir "$lock" 2>/dev/null
	grove_log "created worktree $wt on $branch from $base (name=$raw)"

	# Before a single strategy runs: teach git that everything grove is about to create is local
	# data. Doing it after would leave a window in which `git add -A` could stage it.
	grove_write_excludes

	# --- the submodule ---------------------------------------------------------------------------
	# A LINKED WORKTREE of the submodule repository, never a clone. A plain `git worktree add` leaves
	# the submodule directory EMPTY, and `git submodule update --init` cannot fix it: it clones from
	# origin, which need not have the pinned commit — submodule work is often committed locally and
	# pushed rarely. The only object store that certainly has it is the main checkout's own, so we
	# link that. Objects stay shared and commits made in the worktree are visible to the main
	# checkout immediately.
	local sub_branch=""
	if [ -n "$SUBMODULE" ]; then
		local sub_main="$MAIN_ROOT/$SUBMODULE" sub_wt="$wt/$SUBMODULE" pinned
		pinned="$(git -C "$wt" rev-parse --verify --quiet "HEAD:$SUBMODULE" 2>/dev/null)"
		if [ -z "$pinned" ] || ! git -C "$sub_main" cat-file -e "${pinned}^{commit}" 2>/dev/null; then
			# The base commit pins a submodule commit this machine has never seen (someone else's
			# push). Falling back to the local submodule HEAD gives a working site; the gitlink then
			# reads as modified in the worktree, which is visible and harmless.
			grove_log "WARN: pinned submodule commit ${pinned:-<none>} not available locally; using the submodule's HEAD"
			pinned="$(git -C "$sub_main" rev-parse HEAD)"
		fi
		rmdir "$sub_wt" 2>/dev/null
		sub_branch="$branch"
		n=2
		while git -C "$sub_main" show-ref --verify --quiet "refs/heads/$sub_branch"; do
			sub_branch="$branch-$n"; n=$((n + 1))
		done
		if ! add_err="$(git -C "$sub_main" worktree add -b "$sub_branch" "$sub_wt" "$pinned" 2>&1 >/dev/null)"; then
			printf '%s\n' "$add_err" | tr '\r' '\n' >>"$GROVE_LOG_FILE" 2>/dev/null
			grove_log "FATAL: could not add the submodule worktree at $sub_wt"
			return 1
		fi
		grove_log "submodule worktree at $pinned on $sub_branch"
	fi

	# ============================================================================================
	# Past this point nothing is fatal: an unprovisioned site is a degraded session, not a broken one.
	# ============================================================================================

	local rel strategy
	while IFS="$(printf '\t')" read -r rel strategy; do
		[ -n "$rel" ] || continue
		grove_apply_path "$wt" "$rel" "$strategy"
	done <<EOF
$(grove_each_path)
EOF

	{
		printf 'NAME=%s\n' "$name"
		printf 'BRANCH=%s\n' "$branch"
		printf 'SUB_BRANCH=%s\n' "$sub_branch"
		printf 'CREATED=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
		printf 'SESSION_ID=%s\n' "$session_id"
		printf 'TRANSCRIPT=%s\n' "$transcript"
	} >"$wt/$GROVE_META" 2>/dev/null

	# Returned to the caller in variables rather than on stdout: the WorktreeCreate hook's stdout is
	# the worktree path and must carry nothing else. They are read from bin/grove and lib/hooks.sh,
	# which is not visible from inside this file — hence the disables.
	# shellcheck disable=SC2034
	GROVE_NEW_NAME="$name"
	# shellcheck disable=SC2034
	GROVE_NEW_PATH="$wt"
	# shellcheck disable=SC2034
	GROVE_NEW_BRANCH="$branch"
	# shellcheck disable=SC2034
	GROVE_NEW_SUB_BRANCH="$sub_branch"

	# --- the site ---------------------------------------------------------------------------------
	# DEFERRED BY DEFAULT. Seeding a database is the one slow step, and most sessions never need it:
	# a session that answers a question, reads code or edits a doc uses the checkout and never loads
	# the site. Paying a dump-and-import on every session — including the ones that end two messages
	# later — is the wrong default. So a marker is left instead, and the first file change builds it.
	GROVE_NEW_URL=""
	# shellcheck disable=SC2034
	GROVE_NEW_DB=""
	if grove_has_site "$name"; then
		GROVE_NEW_URL="$(grove_wt_url "$name")"
		# shellcheck disable=SC2034
		GROVE_NEW_DB="$(grove_wt_db "$name")"
		if [ "$PROVISION" = "eager" ]; then
			grove_provision "$name" || grove_log "WARN: eager provisioning failed for $name"
		else
			: >"$wt/.grove-provision-pending" 2>/dev/null
			grove_log "site deferred: builds on the first Edit/Write (marker .grove-provision-pending)"
		fi
	fi

	grove_write_note "$name"
	grove_sync_hook_config "$wt"
	grove_log "done: $wt ${GROVE_NEW_URL:+($GROVE_NEW_URL)}"
	return 0
}

# Can this worktree have a site at all? Slot naming gives it a hostname the static vhost already
# serves; a noslot-* overflow worktree and a `free`-named one have no such name, and a project whose
# stack is `none` has nowhere to serve anything.
grove_has_site() { # <name>
	[ "$STACK" != "none" ] || return 1
	[ "$NAMING" != "slots" ] && return 1
	case "$1" in wt[0-9]*) return 0 ;; *) return 1 ;; esac
}

# --- provision ---------------------------------------------------------------------------------
# Everything create deliberately deferred, and everything a worktree made while the stack was down
# never got. Idempotent by construction, so the on-edit hook, the CLI and a retry all do the same.
grove_provision() { # <name>
	local name="$1" wt rc=0
	wt="$(grove_wt_dir "$name")"

	grove_is_worktree "$wt" || { printf 'error: %s is not a worktree\n' "$name" >&2; return 1; }
	grove_has_site "$name" || { grove_log "$name has no site to build (naming=$NAMING, stack=$STACK)"; rm -f "$wt/.grove-provision-pending"; return 0; }
	grove_stack_running || { printf 'error: the %s stack is not running\n' "$STACK" >&2; return 1; }

	if [ "$DB_SEED" != "none" ]; then
		if grove_db_seed "$name"; then
			grove_log "database $(grove_wt_db "$name") seeded from $(grove_main_db)"
		else
			grove_log "WARN: database seeding failed for $(grove_wt_db "$name")"
			rc=1
		fi
	fi

	grove_write_site_config "$name" || grove_log "WARN: could not write the worktree's site config"
	# A failed `container` copy IS a failed provision, not a warning: for the platform this strategy
	# exists for, a missing vendor/ means the site cannot boot at all. Failing here keeps the marker
	# in place so the next file change retries.
	grove_container_copies "$name" || rc=1
	grove_container_runtime_dirs "$name"

	# Post-create commands run LAST and inside the container, because that is where the toolchain
	# lives. They are the slow part (a Magento di:compile is minutes), which is precisely why the
	# default is to arrive here on the first file change rather than during create.
	local i cmd cdir
	cdir="$(grove_wt_container_dir "$name")"
	i=0
	while [ "$i" -lt "${#GROVE_POST_CREATE[@]}" ]; do
		cmd="${GROVE_POST_CREATE[$i]}"
		grove_log "post-create: $cmd"
		grove_stack_exec "cd '$cdir' && $cmd" >>"$GROVE_LOG_FILE" 2>&1 \
			|| { grove_log "WARN: post-create command failed: $cmd"; rc=1; }
		i=$((i + 1))
	done

	rm -f "$wt/.grove-provision-pending"
	# The note is rewritten now that the site actually exists, so a session reading it mid-flight
	# does not see the "no site" text it was created with.
	grove_write_note "$name"
	return "$rc"
}

# --- telling the session where it landed ------------------------------------------------------------
#
# Not a command, and the easiest thing in the whole design to forget: a worktree nobody knows about is
# useless. The note is written TWICE, on purpose.
#
#   WORKTREE-SITE.md   — read by any agent that lists the worktree root, subagents included.
#   CLAUDE.local.md    — auto-loaded by Claude Code as project memory for a session whose project
#                        directory is this worktree. This channel needs no hook registration at all,
#                        which is load-bearing: a session INSIDE a worktree reads THAT WORKTREE's
#                        committed .claude/settings.json, so hook config that exists only
#                        uncommitted never fires there. Without this copy the context hook silently
#                        does nothing in exactly the case it exists for.
grove_write_note() { # <name>
	local name="$1" wt url db branch sub_branch
	wt="$(grove_wt_dir "$name")"
	[ -d "$wt" ] || return 0
	branch="$(grove_meta_get "$wt" BRANCH)"
	sub_branch="$(grove_meta_get "$wt" SUB_BRANCH)"
	[ -n "$branch" ] || branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)"

	url=""; db=""
	if grove_has_site "$name" && [ ! -f "$wt/.grove-provision-pending" ]; then
		url="$(grove_wt_url "$name")"; db="$(grove_wt_db "$name")"
	elif grove_has_site "$name"; then
		url="$(grove_wt_url "$name")"; db="$(grove_wt_db "$name")"
	fi

	{
		echo "# This worktree"
		echo
		if [ -n "$url" ]; then
			echo "You are in an isolated git worktree (\`$name\`, branch \`$branch\`) with your OWN site,"
			echo "database and data directories — a copy of the shared dev site taken when this worktree was"
			echo "created. Changing it cannot affect the main site or any other session."
			echo
			echo "| | |"
			echo "|---|---|"
			echo "| Site | $url |"
			[ "$STACK" = "ddev" ] && echo "| Local name | https://$(grove_wt_local_host "$name") |"
			echo "| Database | \`$db\` (the main site's \`$(grove_main_db)\` is off-limits) |"
			echo "| Branch | \`$branch\` |"
			[ -n "$sub_branch" ] && echo "| Submodule branch | \`$sub_branch\` (in $SUBMODULE) |"
			echo
			if [ -f "$wt/.grove-provision-pending" ]; then
				echo "**The site is not built yet.** It builds itself on your first file change (that is the"
				echo "\`.grove-provision-pending\` marker) — or run \`grove provision $name\` to do it now."
				echo
			fi
		else
			echo "You are in an isolated git worktree (\`$name\`, branch \`$branch\`) with NO site of its own."
			echo "File edits, commits and merges all work normally; there is just nothing to browser-test here."
			echo "Treat the shared dev site as READ-ONLY — do not run tests or fixtures against it."
			echo
		fi
		if [ -n "$SUBMODULE" ]; then
			echo "The submodule at \`$SUBMODULE\` is a LINKED WORKTREE of the submodule repository, not a clone."
			echo "Commit work there as usual; the main checkout sees those commits immediately. (\`git status\` at"
			echo "the worktree root always shows it as modified — that is the linked-worktree setup, not your"
			echo "doing.)"
			echo
		fi
		echo "## Rules"
		echo
		if [ "$STACK" != "none" ]; then
			echo "- **Never restart, stop or delete the stack** — one $STACK project serves the main site and"
			echo "  every other session's site. Taking it down takes all of them down."
		fi
		echo "- **Commit your work before the session ends.** Committed work survives on the branch;"
		echo "  uncommitted work keeps this worktree occupying its slot until someone force-removes it."
		echo "- **Do not run \`grove remove\` or \`grove sync-db\` on your own worktree from in here** — that is"
		echo "  main-checkout plumbing."
		echo
		echo "## When the work is finished"
		echo
		echo "Never run a bare \`git merge\` into the main branch from in here: it is checked out in the main"
		echo "checkout, and git refuses to move a branch that is checked out elsewhere. Landing goes through"
		echo "grove, whose git calls all run against the main checkout — which is what makes it safe to invoke"
		echo "from inside this worktree:"
		echo
		echo '```bash'
		echo "grove merge $name --keep   # land the work; this worktree stays fully up"
		echo '```'
		echo
		echo "\`--keep\` leaves the worktree, its branch and its site untouched, so you keep working and can"
		echo "merge again later — each run lands only the commits since the last. Without \`--keep\` the whole"
		echo "thing is released afterwards, and since that deletes the directory you are standing in, leave"
		echo "the worktree first (ExitWorktree) and run it from the main checkout."
		echo
		echo "_Written by grove. Do not edit — it is rewritten whenever the worktree's site changes._"
	} >"$wt/WORKTREE-SITE.md" 2>/dev/null || grove_log "WARN: could not write WORKTREE-SITE.md"

	cp "$wt/WORKTREE-SITE.md" "$wt/CLAUDE.local.md" 2>/dev/null || grove_log "WARN: could not write CLAUDE.local.md"
}

# Carry the MAIN checkout's current hook config into the worktree, overwriting the committed copies.
# Same reason as CLAUDE.local.md above: the session in here runs the worktree's own committed
# settings.json, and that is whatever was last committed rather than what is configured today. Once
# the config IS committed the two are identical and this is a no-op. grove_worktree_dirty excludes
# both paths, so the overwrite never reads as session work.
grove_sync_hook_config() { # <wt-path>
	[ -f "$MAIN_ROOT/.claude/settings.json" ] || return 0
	mkdir -p "$1/.claude/hooks" 2>/dev/null
	cp -p "$MAIN_ROOT/.claude/settings.json" "$1/.claude/settings.json" 2>/dev/null \
		|| grove_log "WARN: could not sync settings.json"
	if [ -d "$MAIN_ROOT/.claude/hooks" ]; then
		cp -p "$MAIN_ROOT/.claude/hooks/"* "$1/.claude/hooks/" 2>/dev/null || true
	fi
}

# --- remove ---------------------------------------------------------------------------------------
grove_remove() { # <name> [-f]
	local name="$1" force="${2:-}" wt sub_main branch sub_branch dirty
	wt="$(grove_wt_dir "$name")"
	sub_main="$MAIN_ROOT/$SUBMODULE"

	# A leftover directory git does not know as a worktree: just delete it. Running the worktree
	# machinery on it would aim at the MAIN CHECKOUT instead — `git -C` walks UP out of a plain
	# directory — so `symbolic-ref` would answer the main branch and a teardown could act on the wrong
	# repository. Refusing early is the difference between a clear message and a dangerous one.
	if [ -d "$wt" ] && ! grove_is_worktree "$wt"; then
		printf 'Removing leftover directory %s (not a worktree — nothing of git'\''s is in it)\n' "$wt"
		rm -rf "$wt"
	fi

	if grove_is_worktree "$wt"; then
		dirty="$(grove_worktree_dirty "$wt")"
		if [ -n "$SUBMODULE" ] && [ -d "$wt/$SUBMODULE" ]; then
			dirty="$dirty$(git -C "$wt/$SUBMODULE" status --porcelain 2>/dev/null)"
		fi
		if [ -n "$dirty" ] && [ "$force" != "-f" ] && [ "$force" != "--force" ]; then
			printf 'error: %s has uncommitted changes or untracked files:\n' "$name" >&2
			printf '%s\n' "$dirty" | head -20 >&2
			printf 'Re-run with --force to destroy them.\n' >&2
			return 1
		fi
		branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)"
		if [ -n "$SUBMODULE" ]; then
			sub_branch="$(git -C "$wt/$SUBMODULE" symbolic-ref --quiet --short HEAD 2>/dev/null)"
			# Only when git knows it as a worktree of the submodule repo — otherwise `worktree remove`
			# prints a bare "is not a working tree" fatal over an otherwise clean teardown.
			if git -C "$sub_main" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $wt/$SUBMODULE"; then
				git -C "$sub_main" worktree remove --force "$wt/$SUBMODULE" >/dev/null 2>&1
			fi
		fi
		git -C "$MAIN_ROOT" worktree remove --force "$wt" >/dev/null 2>&1 \
			|| grove_log "WARN: git worktree remove failed for $wt"
		# -d only deletes a branch whose commits are already merged, so committed-but-unmerged work
		# survives as a branch rather than being destroyed here.
		[ -n "${sub_branch:-}" ] && git -C "$sub_main" branch -d "$sub_branch" >/dev/null 2>&1
		[ -n "${branch:-}" ] && git -C "$MAIN_ROOT" branch -d "$branch" >/dev/null 2>&1
	fi

	git -C "$MAIN_ROOT" worktree prune >/dev/null 2>&1
	[ -n "$SUBMODULE" ] && git -C "$sub_main" worktree prune >/dev/null 2>&1

	if grove_has_site "$name" && grove_stack_running; then
		grove_db_drop "$name" && printf 'Dropped database %s.\n' "$(grove_wt_db "$name")"
	fi
	# The container keeps its own copy of anything sync-ignored, so it has to be told explicitly.
	grove_container_purge "$name"
	printf '%s is free.\n' "$name"
	grove_log "released $name"
}

# --- merge ------------------------------------------------------------------------------------------
#
# THE post-review path, and the fiddliest thing grove absorbs. The submodule's branch is merged first,
# so the outer pointer bump can reference the already-merged commit.
#
# With --keep the teardown is skipped entirely: worktree, branch, site and database stay up, the
# session keeps working on the same branch, and a later merge lands only the commits since — both
# rev-list guards below count HEAD..branch, so an already-landed history is simply a no-op.
grove_merge() { # <name> [--keep]
	local name="$1" keep="${2:-}" wt sub_main branch sub_branch dirty unmerged
	case "$keep" in ""|--keep|-k) ;; *) printf 'error: unknown merge option %s (only --keep)\n' "$keep" >&2; return 1 ;; esac

	wt="$(grove_wt_dir "$name")"
	sub_main="$MAIN_ROOT/$SUBMODULE"
	if ! grove_is_worktree "$wt"; then
		if [ -d "$wt" ]; then
			printf 'error: %s has a leftover directory but no worktree — clear it with: grove remove %s\n' "$name" "$name" >&2
		else
			printf 'error: %s has no worktree (for leftover branches, see: grove prune-merged)\n' "$name" >&2
		fi
		return 1
	fi

	branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
		|| { printf 'error: %s is on a detached HEAD — nothing safe to merge\n' "$name" >&2; return 1; }
	[ -n "$branch" ] || { printf 'error: %s is on a detached HEAD — nothing safe to merge\n' "$name" >&2; return 1; }
	[ -n "$SUBMODULE" ] && sub_branch="$(git -C "$wt/$SUBMODULE" symbolic-ref --quiet --short HEAD 2>/dev/null)" || sub_branch=""

	# Uncommitted work cannot be merged; there is deliberately no --force here.
	dirty="$(grove_worktree_dirty "$wt")"
	if [ -n "$SUBMODULE" ] && [ -d "$wt/$SUBMODULE" ]; then
		dirty="$dirty$(git -C "$wt/$SUBMODULE" status --porcelain 2>/dev/null)"
	fi
	if [ -n "$dirty" ]; then
		printf 'error: %s has uncommitted changes — commit them (in the worktree) before merging:\n' "$name" >&2
		printf '%s\n' "$dirty" | head -20 >&2
		return 1
	fi

	# Refuse to carry a grove-managed path across. These hold each checkout's own local data, so
	# merging one checkout's copy into another is meaningless at best — and for a `link` path it
	# replaces the target checkout's real directory with a symlink pointing at itself.
	local managed; managed="$(grove_merge_touches_managed "$branch")"
	if [ -n "$managed" ]; then
		printf 'error: %s changes paths grove manages as local data:\n' "$branch" >&2
		printf '%s\n' "$managed" | sort -u | sed 's/^/       /' >&2
		printf 'Merging them would overwrite the main checkout'\''s own copies. Drop them from the branch\n' >&2
		printf 'first (git rm --cached <path> && commit), then re-run.\n' >&2
		return 1
	fi

	# 1. The submodule's branch into the submodule's current branch.
	if [ -n "$sub_branch" ] && [ "$(git -C "$sub_main" rev-list --count "HEAD..$sub_branch" 2>/dev/null)" != "0" ]; then
		printf 'Merging submodule branch %s into %s …\n' "$sub_branch" "$(git -C "$sub_main" symbolic-ref --short HEAD)"
		git -C "$sub_main" -c core.commitGraph=false merge --no-edit "$sub_branch" || {
			printf 'error: the submodule merge has conflicts — resolve in %s (or git merge --abort), then re-run\n' "$sub_main" >&2
			return 1
		}
	fi

	# 2. This repo's branch into the main checkout's current branch.
	#
	# With a submodule, the pointer ALWAYS conflicts here, by construction: step 1 has just moved the
	# submodule's branch, so the outer branch's recorded pointer and it no longer share a merge base.
	# Git stops with "Failed to merge submodule … (commits don't follow merge-base)". That is expected
	# rather than something to hand back — the submodule was merged a moment ago, so its current HEAD
	# is by definition the pointer this merge should record.
	#
	# `core.commitGraph=false` is not cosmetic. Resolving a submodule conflict makes git read commits
	# out of the submodule's object store, and in this layout — one shared git dir with a linked
	# worktree per slot — that lookup goes wrong and git aborts with
	#     fatal: invalid commit position. commit-graph is likely corrupt
	# which is misleading: nothing is corrupt, both graphs verify and every object is present. With the
	# graph off git takes the other code path and reports the ordinary conflict, which is resolved below.
	if [ "$(git -C "$MAIN_ROOT" rev-list --count "HEAD..$branch" 2>/dev/null)" != "0" ]; then
		printf 'Merging %s into %s …\n' "$branch" "$(git -C "$MAIN_ROOT" symbolic-ref --short HEAD)"
		git -C "$MAIN_ROOT" -c core.commitGraph=false merge --no-edit "$branch" || {
			# Auto-resolve ONLY when the submodule path is the single unmerged entry. A real content
			# conflict, or anything else alongside it, still stops for a human.
			unmerged="$(git -C "$MAIN_ROOT" diff --name-only --diff-filter=U)"
			if [ -z "$SUBMODULE" ] || [ "$unmerged" != "$SUBMODULE" ]; then
				printf 'error: merge has conflicts — resolve in %s (or git merge --abort), then re-run\n' "$MAIN_ROOT" >&2
				return 1
			fi
			printf 'Resolving the expected submodule-pointer conflict to the submodule'\''s merged HEAD …\n'
			git -C "$MAIN_ROOT" add -- "$SUBMODULE" \
				&& git -C "$MAIN_ROOT" -c core.commitGraph=false commit --no-edit || {
					printf 'error: could not complete the merge in %s\n' "$MAIN_ROOT" >&2
					return 1
				}
		}
	fi

	# 3. Bump the submodule pointer when the merges left it behind. Pathspec-limited, so no unrelated
	#    staged work in the main checkout can ride along on this commit.
	if [ -n "$SUBMODULE" ] && \
	   [ "$(git -C "$MAIN_ROOT" rev-parse "HEAD:$SUBMODULE" 2>/dev/null)" != "$(git -C "$sub_main" rev-parse HEAD 2>/dev/null)" ]; then
		printf 'Bumping the %s submodule pointer …\n' "$SUBMODULE"
		git -C "$MAIN_ROOT" commit -m "chore: bump the $SUBMODULE submodule for $branch" -- "$SUBMODULE" \
			|| { printf 'error: could not commit the submodule bump\n' >&2; return 1; }
	fi

	# 4. Teardown — the branches are merged now, so remove's `branch -d` finally succeeds.
	if [ -n "$keep" ]; then
		printf 'Landed. %s stays up — branch %s continues; merge again to land later commits.\n' "$name" "$branch"
	else
		grove_remove "$name"
	fi
}

# Delete fully-merged worktree branches — what a session leaves behind when its worktree is already
# gone (clean exit, or Claude Code's periodic sweep) and its work has since been merged. `branch -d`
# refuses unmerged branches and branches checked out in a live worktree, so this can never destroy
# work; it only collects garbage.
grove_prune_merged() {
	local repo label b any=0
	for repo in "$MAIN_ROOT" ${SUBMODULE:+"$MAIN_ROOT/$SUBMODULE"}; do
		label="${repo#"$MAIN_ROOT"}"; label="${label:-this repo}"; label="${label#/}"
		git -C "$repo" worktree prune >/dev/null 2>&1
		while IFS= read -r b; do
			[ -n "$b" ] || continue
			if git -C "$repo" branch -d "$b" >/dev/null 2>&1; then
				printf 'Deleted merged branch %s (%s)\n' "$b" "$label"
				any=1
			fi
		done <<EOF
$(git -C "$repo" branch --list "${BRANCH_PREFIX}*" --merged HEAD --format '%(refname:short)' 2>/dev/null)
EOF
	done
	[ "$any" = "1" ] || printf 'Nothing to prune — no fully-merged %s* branches.\n' "$BRANCH_PREFIX"
}

# --- how long since the session holding a worktree last did anything ---------------------------------
#
# Hours since the owning session's transcript was last written, or empty when it cannot be
# established. Purely informational: `list` shows it so a worktree nobody is using stops looking
# exactly like one somebody is.
#
# WHY THIS SIGNAL. Two tempting ones are wrong. "Clean tree + fully merged" is NOT abandonment — it is
# precisely the state a healthy session sits in after `merge --keep`, so reclaiming on it kills live
# sessions. And directory mtime lies: anything watching the filesystem touches a worktree without a
# session being near it (PhpStorm wrote .idea/workspace.xml into a path seconds after teardown).
#
# Best-effort by construction. When any link is missing this returns EMPTY and the caller must render
# that as "unknown" — never as "idle". A missing record is an absence of evidence, and treating it as
# evidence of absence is how a live session loses its site.
grove_idle_hours() { # <wt-path>
	local wt="$1" transcript sid mtime
	transcript="$(grove_meta_get "$wt" TRANSCRIPT)"
	if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
		sid="$(grove_meta_get "$wt" SESSION_ID)"
		[ -n "$sid" ] || return 0
		# Claude Code stores a session's transcript under a directory named after the project path
		# with every slash turned into a dash.
		transcript="$HOME/.claude/projects/$(printf '%s' "$MAIN_ROOT" | sed 's|/|-|g')/$sid.jsonl"
	fi
	[ -f "$transcript" ] || return 0
	mtime="$(stat -f %m "$transcript" 2>/dev/null)" || return 0
	[ -n "$mtime" ] || return 0
	printf '%s' "$(( ( $(date +%s) - mtime ) / 3600 ))"
}

grove_list() {
	local stack_up="no"; grove_stack_running && stack_up="yes"
	local i name dir url state notes

	printf '%-20s  %-32s  %-42s  %s\n' "WORKTREE" "BRANCH" "SITE" "STATE"

	if [ "$NAMING" = "slots" ]; then
		i=1
		while [ "$i" -le "$SLOTS" ]; do
			name="wt$i"; i=$((i + 1))
			dir="$(grove_wt_dir "$name")"
			url="$(grove_has_site "$name" && grove_wt_url "$name")"
			if ! grove_is_worktree "$dir"; then
				notes=""
				[ -d "$dir" ] && notes="stale directory — safe to delete"
				if [ "$stack_up" = "yes" ] && grove_db_exists "$(grove_wt_db "$name")"; then
					notes="${notes:+$notes; }stale database — a reused slot reseeds it"
				fi
				state="free"
				[ -n "$notes" ] && state="free ($notes)"
				printf '%-20s  %-32s  %-42s  %s\n' "$name" "-" "-" "$state"
				continue
			fi
			grove_list_row "$name" "$dir" "$stack_up"
		done
	fi

	# Worktrees that are not slots: `free` naming, and the noslot-* overflow ones that were created
	# while every slot was busy. Nothing ever prunes those, so at minimum they must be visible.
	for dir in "$WORKTREES_DIR"/*; do
		[ -d "$dir" ] || continue
		name="$(basename "$dir")"
		case "$name" in wt[0-9]*) [ "$NAMING" = "slots" ] && continue ;; esac
		grove_is_worktree "$dir" || continue
		grove_list_row "$name" "$dir" "$stack_up"
	done

	[ "$stack_up" = "no" ] && [ "$STACK" != "none" ] && \
		printf '\n(the %s stack is not running — database state unknown)\n' "$STACK"
	return 0
}

grove_list_row() { # <name> <dir> <stack-up>
	local name="$1" dir="$2" stack_up="$3" branch state url idle
	branch="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || echo '(detached)')"
	state="in use"
	[ -n "$(grove_worktree_dirty "$dir")" ] && state="in use, uncommitted changes"
	url="-"
	if grove_has_site "$name"; then
		url="$(grove_wt_url "$name")"
		[ -f "$dir/.grove-provision-pending" ] && state="$state, site not built yet"
		if [ "$stack_up" = "yes" ] && [ ! -f "$dir/.grove-provision-pending" ] && ! grove_db_exists "$(grove_wt_db "$name")"; then
			state="$state, NO DATABASE"
		fi
	fi
	idle="$(grove_idle_hours "$dir")"
	if [ -n "$idle" ]; then
		# Hours below two days, then whole days ROUNDED rather than truncated — 44h reported as "1d"
		# reads as half the neglect it is, and this number exists to be judged by eye.
		if [ "$idle" -ge 48 ]; then
			state="$state, idle $(( (idle + 12) / 24 ))d"
		else
			state="$state, idle ${idle}h"
		fi
	else
		state="$state, idle unknown"
	fi
	printf '%-20s  %-32s  %-42s  %s\n' "$name" "$branch" "$url" "$state"
}

grove_info() { # <name>
	local name="$1" wt branch ahead
	wt="$(grove_wt_dir "$name")"
	grove_is_worktree "$wt" || { printf 'error: %s is not a worktree\n' "$name" >&2; return 1; }
	branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || echo '(detached)')"

	printf '\n  %-16s %s\n' "worktree" "$name"
	printf '  %-16s %s\n' "path" "$wt"
	printf '  %-16s %s\n' "branch" "$branch"
	[ -n "$SUBMODULE" ] && printf '  %-16s %s\n' "submodule branch" "$(git -C "$wt/$SUBMODULE" symbolic-ref --quiet --short HEAD 2>/dev/null || echo '-')"
	printf '  %-16s %s\n' "created" "$(grove_meta_get "$wt" CREATED)"
	printf '  %-16s %s\n' "profile" "$PLATFORM"

	if grove_has_site "$name"; then
		printf '  %-16s %s\n' "site" "$(grove_wt_url "$name")"
		[ "$STACK" = "ddev" ] && printf '  %-16s https://%s\n' "local name" "$(grove_wt_local_host "$name")"
		printf '  %-16s %s\n' "container path" "$(grove_wt_container_dir "$name")"
		printf '  %-16s %s' "database" "$(grove_wt_db "$name")"
		if grove_stack_running; then
			grove_db_exists "$(grove_wt_db "$name")" && printf ' (present)' || printf ' (MISSING)'
		fi
		printf '\n'
		[ -f "$wt/.grove-provision-pending" ] && printf '  %-16s %s\n' "" "site not built yet — builds on the first file change"
	else
		printf '  %-16s %s\n' "site" "none (naming=$NAMING, stack=$STACK)"
	fi

	ahead="$(git -C "$MAIN_ROOT" rev-list --count "HEAD..$branch" 2>/dev/null)"
	printf '  %-16s %s\n' "commits to land" "${ahead:-?}"
	local dirty; dirty="$(grove_worktree_dirty "$wt")"
	printf '  %-16s %s\n' "working tree" "$([ -n "$dirty" ] && echo 'dirty' || echo 'clean')"

	printf '\n  paths\n'
	local rel strategy
	while IFS="$(printf '\t')" read -r rel strategy; do
		[ -n "$rel" ] || continue
		printf '    %-28s %s\n' "$rel" "$strategy"
	done <<EOF
$(grove_each_path)
EOF
	printf '\n'
}

# Run a command in a worktree — inside the container when there is one, since that is where the
# toolchain lives and where the paths in a site's config resolve.
grove_shell() { # <name> [command...]
	local name="$1"; shift
	local wt; wt="$(grove_wt_dir "$name")"
	grove_is_worktree "$wt" || { printf 'error: %s is not a worktree\n' "$name" >&2; return 1; }

	if [ "$STACK" = "none" ] || ! grove_stack_running; then
		if [ "$#" -eq 0 ]; then (cd "$wt" && exec "${SHELL:-/bin/bash}"); else (cd "$wt" && eval "$*"); fi
		return $?
	fi
	local cdir; cdir="$(grove_wt_container_dir "$name")"
	if [ "$#" -eq 0 ]; then
		(cd "$MAIN_ROOT" && ddev ssh --dir "$cdir")
	else
		grove_stack_exec "cd '$cdir' && $*"
	fi
}

grove_sync_db() { # <name>
	local name="$1"
	grove_has_site "$name" || { printf 'error: %s has no database of its own\n' "$name" >&2; return 1; }
	grove_is_worktree "$(grove_wt_dir "$name")" || { printf 'error: %s is not a worktree\n' "$name" >&2; return 1; }
	grove_stack_running || { printf 'error: the %s stack is not running\n' "$STACK" >&2; return 1; }
	printf 'Re-seeding %s from %s …\n' "$(grove_wt_db "$name")" "$(grove_main_db)"
	grove_db_seed "$name" || { printf 'error: seeding failed\n' >&2; return 1; }
	grove_write_site_config "$name"
	printf 'Done — %s\n' "$(grove_wt_url "$name")"
}

# --- wire: everything grove DERIVES rather than asks for ---------------------------------------------
#
# The point of one declaration per path is that the rest follows from it. Nothing below is a setting:
# the hostname list comes from the slot count, the vhost from the docroot, the sync-ignore list from
# whichever paths declared `container`. Re-running this is safe and is how a changed slot count or a
# changed path list gets applied.

grove_re() { printf '%s' "$1" | sed 's/\./\\./g'; }   # a hostname, escaped for an nginx regex

grove_wire_hostnames() {
	local f="$MAIN_ROOT/.ddev/config.grove.yaml" i
	mkdir -p "$MAIN_ROOT/.ddev" 2>/dev/null
	{
		echo "# Generated by grove — do not edit. Re-run: grove wire"
		echo "#"
		echo "# One hostname per serving slot. ddev merges every .ddev/config.*.yaml into config.yaml, so"
		echo "# these are additive and config.yaml stays the stock project config."
		echo "#"
		echo "# Registering the hostname here is what makes ddev-router route it and mkcert include it in the"
		echo "# project certificate — an unregistered hostname never reaches the web server at all. Changing"
		echo "# the list needs a \`ddev restart\`."
		echo "#"
		echo "# Multi-level names (wt1.$PROJECT.$LOCAL_ZONE) do NOT work: the wildcard DNS for $LOCAL_ZONE covers"
		echo "# a single label only. Hence the flat form."
		echo "additional_hostnames:"
		i=1
		while [ "$i" -le "$SLOTS" ]; do printf '    - %s-wt%s\n' "$PROJECT" "$i"; i=$((i + 1)); done
	} >"$f" || return 1
	printf '  wrote %s (%s hostnames)\n' "${f#"$MAIN_ROOT"/}" "$SLOTS"
}

grove_wire_vhost() {
	local f="$MAIN_ROOT/.ddev/nginx_full/grove-worktrees.conf" root
	mkdir -p "$MAIN_ROOT/.ddev/nginx_full" 2>/dev/null
	root="$CONTAINER_ROOT/$WORKTREES_REL/\$grovewt"
	[ -n "$DOCROOT" ] && root="$root/$DOCROOT"

	{
		cat <<EOF
# Generated by grove — do not edit. Re-run: grove wire
#
# Serves every per-worktree site from ONE server block. The worktree name is captured out of the Host
# header and substituted into \`root\`, so adding a worktree needs no change here and no reload.
#
# Why a regex rather than one symlink per slot: re-pointing a symlinked docroot needs a php-fpm reload
# to clear the realpath and opcode caches, and a stale cache serves the PREVIOUS worktree's files — a
# failure that reads as "my edits don't show up". A literal path per request has no such state.
#
# Deliberately NOT carrying ddev's generated-file marker — this file is grove's and ddev must leave it
# alone. The marker is spelled with an underscore here (#_ddev-generated) precisely so that saying so
# does not itself trip ddev's scan for it.

# Which worktree a request is for, derived from the Host header — local and public names both. A
# \`map\` rather than a named capture in server_name because nginx will not let two regexes in one
# server_name share a capture name.
map \$host \$grovewt {
    ~^$(grove_re "$PROJECT")-(?<localwt>wt[0-9]+)\.$(grove_re "$LOCAL_ZONE")\$   \$localwt;
EOF
		[ -n "$ZONE" ] && printf '    ~^(?<publicwt>wt[0-9]+)-%s\\.%s$   $publicwt;\n' "$(grove_re "$PROJECT")" "$(grove_re "$ZONE")"
		cat <<EOF
    default                                                     "";
}

server {
    server_name ~^$(grove_re "$PROJECT")-wt[0-9]+\.$(grove_re "$LOCAL_ZONE")\$$([ -n "$ZONE" ] && printf '\n                ~^wt[0-9]+-%s\\.%s$' "$(grove_re "$PROJECT")" "$(grove_re "$ZONE")");
    root $root;

    # A worktree is a seeded copy of a real site on a guessable public name. Keep it out of search
    # results — the copy carries the original's content and, often, its licence keys.
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;

    listen 80;
    listen 443 ssl;
    ssl_certificate /etc/ssl/certs/master.crt;
    ssl_certificate_key /etc/ssl/certs/master.key;

    include /etc/nginx/monitoring.conf;
    index index.php index.htm index.html;
    sendfile off;
    error_log /dev/stdout info;
    access_log /var/log/nginx/access.log;

EOF
		if command -v grove_profile_nginx_locations >/dev/null 2>&1; then
			grove_profile_nginx_locations
		else
			cat <<'EOF'
    location / {
        absolute_redirect off;
        try_files $uri $uri/ /index.php?$query_string;
    }
EOF
		fi
		cat <<'EOF'

    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param SCRIPT_NAME $fastcgi_script_name;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_intercept_errors off;
        # The only wall-clock limit in the request path, kept long enough to sit on a debugger
        # breakpoint without a 504.
        fastcgi_read_timeout 3600s;
        fastcgi_param SERVER_NAME $host;
        fastcgi_param HTTPS $fcgi_https;
    }

    # Hidden files, and the usual backup/config/source leftovers.
    location ~* /\.(?!well-known\/) { deny all; }
    location ~* (?:\.(?:bak|conf|dist|fla|in[ci]|log|psd|sh|sql|sw[op])|~)$ { deny all; }

    include /etc/nginx/common.d/*.conf;
    include /mnt/ddev_config/nginx/*.conf;
}
EOF
	} >"$f" || return 1
	printf '  wrote %s\n' "${f#"$MAIN_ROOT"/}"
}

# The sync-ignore list, derived from the `container` strategy and from nothing else. That is the whole
# reason the strategy exists: one fact, written once, so the copy and the exclusion cannot drift.
grove_wire_sync() {
	local f="$MAIN_ROOT/.ddev/mutagen/mutagen.yml" paths rel
	paths="$(grove_container_paths)"
	[ -n "$paths" ] || { printf '  no `container` paths — nothing to exclude from sync\n'; return 0; }

	# An existing file is EDITED IN PLACE rather than replaced: it is ddev's, and it carries settings
	# (the symlink mode, the .git exclusions) that must survive. The insertion point is unambiguous —
	# the `paths:` list under `ignore:` — and the block is delimited so re-running replaces it.
	#
	# ddev's copy also carries its generated-file marker, which means DDEV REWRITES IT ON EVERY
	# RESTART. An edit made without removing that marker survives exactly until the next `ddev
	# restart`, silently, and the sync exclusion this whole strategy depends on quietly stops
	# existing. So grove takes ownership of the file by dropping the marker, which is ddev's own
	# documented way of saying "this one is mine now".
	if [ -f "$f" ]; then
		local tmp owned=""
		tmp="$(mktemp)" || return 1
		grep -q '^#ddev-generated' "$f" && owned=" (took ownership from ddev — its marker regenerated the file on every restart)"
		awk -v b="$GROVE_EXCLUDE_BEGIN" -v e="$GROVE_EXCLUDE_END" -v add="$paths" -v wt="$WORKTREES_REL" '
			/^#ddev-generated/ { next }
			$0 ~ b { skip = 1 }
			skip && $0 ~ e { skip = 0; next }
			skip { next }
			{ print }
			!done && /^[[:space:]]*ignore:[[:space:]]*$/ { seen_ignore = 1 }
			seen_ignore && !done && /^[[:space:]]*paths:[[:space:]]*$/ {
				print "        " b
				n = split(add, a, "\n")
				for (i = 1; i <= n; i++) if (a[i] != "") printf "        - \"/%s/*/%s\"\n", wt, a[i]
				print "        " e
				done = 1
			}
		' "$f" >"$tmp"

		if grep -q "$GROVE_EXCLUDE_BEGIN" "$tmp"; then
			cat "$tmp" >"$f"; rm -f "$tmp"
			printf '  updated %s%s\n' "${f#"$MAIN_ROOT"/}" "$owned"
			printf '  %-8s ddev mutagen reset   (a changed ignore list needs it; restart alone reuses the session)\n' "then:"
		else
			rm -f "$tmp"
			printf '  %s has no ignore.paths list to extend — add these by hand:\n' "${f#"$MAIN_ROOT"/}"
			while IFS= read -r rel; do
				[ -n "$rel" ] || continue
				printf '      - "/%s/*/%s"\n' "$WORKTREES_REL" "$rel"
			done <<EOF
$paths
EOF
		fi
		return 0
	fi

	mkdir -p "$(dirname "$f")" 2>/dev/null
	{
		echo "# Generated by grove — do not edit. Re-run: grove wire"
		echo "#"
		echo "# Every path below is declared \`container\` in .grove.conf, meaning it is copied INSIDE the"
		echo "# container and must therefore never be carried by the file sync. The list is DERIVED from those"
		echo "# declarations, so it cannot fall out of step with them."
		echo "#"
		echo "# This is where the strategy pays for itself: a Magento vendor/ is ~80k files, and propagating"
		echo "# them into the container — then watching them forever — is the real cost of a worktree, not the"
		echo "# copy-on-write clone that made them."
		echo "sync:"
		echo "  defaults:"
		echo "    ignore:"
		echo "      paths:"
		while IFS= read -r rel; do
			[ -n "$rel" ] || continue
			printf '        - "/%s/*/%s"\n' "$WORKTREES_REL" "$rel"
		done <<EOF
$paths
EOF
	} >"$f" || return 1
	printf '  wrote %s\n' "${f#"$MAIN_ROOT"/}"
}

grove_wire() {
	printf '\n  Deriving this project'\''s worktree plumbing from .grove.conf\n\n'
	grove_write_excludes
	printf '  refreshed the managed ignore block in %s\n' "$(git -C "$MAIN_ROOT" rev-parse --git-path info/exclude 2>/dev/null)"
	if [ "$STACK" = "ddev" ]; then
		grove_wire_hostnames
		grove_wire_vhost
		grove_wire_sync
		printf '\n  Then, once: ddev restart   (new hostnames only reach the router after one)\n'
	else
		printf '  stack is "%s" — no vhost, no hostnames and no sync list to derive.\n' "$STACK"
	fi

	printf '\n  Wire the hooks into .claude/settings.json:\n\n'
	cat <<'EOF'
      "WorktreeCreate": [{ "hooks": [
        { "type": "command", "command": "grove hook create", "timeout": 300 } ]}],
      "WorktreeRemove": [{ "hooks": [
        { "type": "command", "command": "grove hook remove", "timeout": 120 } ]}],
      "SessionStart":   [{ "hooks": [
        { "type": "command", "command": "grove hook context" } ]}],
      "PostToolUse":    [
        { "matcher": "EnterWorktree", "hooks": [
          { "type": "command", "command": "grove hook context" } ]},
        { "matcher": "Edit|Write", "hooks": [
          { "type": "command", "command": "grove hook on-edit", "timeout": 300 } ]}
      ]
EOF
	printf '\n'
}
