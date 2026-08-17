#!/usr/bin/env bash
#
# The hook entry points — and the interface that actually matters.
#
# AN AI SESSION NEVER TYPES `grove create`. Claude Code fires a WorktreeCreate hook, and the session
# is *moved* into a worktree and has to be *told* where it landed. Every one of the five wirings
# below is machine-triggered; the CLI in bin/grove is the human's copy of the same operations.
#
#   WorktreeCreate            build the worktree + site. Its STDOUT IS THE WORKTREE PATH — nothing
#                             else may be printed there, and a non-zero exit aborts creation and
#                             fails the session, so only the checkout and the submodule are fatal.
#   WorktreeRemove            drop the database, vhost entry, worktree and branch.
#   SessionStart              tell the session its URL, database and branch.
#   PostToolUse[EnterWorktree] the same, for a background session moved into a worktree mid-flight —
#                             SessionStart fired long before that happened.
#   PostToolUse[Edit|Write]   build the site on the first real file change, when provisioning is lazy.
#
# A project wires these into .claude/settings.json instead of carrying five scripts of its own:
#
#   { "type": "command", "command": "grove hook create", "timeout": 300 }

# Read one string field out of a JSON object. jq when it is there; a sed fallback when it is not,
# because a missing jq must not be the reason a session fails to get its worktree.
grove_json_str() { # <json> <key> [<key>...]  — first key that has a value wins
	local json="$1"; shift
	local key value
	for key in "$@"; do
		if command -v jq >/dev/null 2>&1; then
			value="$(printf '%s' "$json" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null)"
		else
			value="$(printf '%s' "$json" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)"
		fi
		[ -n "$value" ] && { printf '%s' "$value"; return 0; }
	done
	return 0
}

grove_json_nested() { # <json> <parent> <key>
	local json="$1" parent="$2" key="$3"
	if command -v jq >/dev/null 2>&1; then
		printf '%s' "$json" | jq -r --arg p "$parent" --arg k "$key" '.[$p][$k] // empty' 2>/dev/null
	else
		printf '%s' "$json" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
	fi
}

# --- WorktreeCreate ---------------------------------------------------------------------------------
hook_create() {
	GROVE_TAG="create"
	local input name base session transcript
	input="$(cat || true)"
	grove_log "--- WorktreeCreate input: ${input:-<empty>}"

	# The reference docs give the field as `worktree_name` while their own example reads `name`, and
	# `name` is what actually arrives. Accept either rather than betting on one and creating a
	# worktree called "null". Same for base_ref, which is documented but not always sent: HEAD is the
	# deliberate fallback, because a worktree branched from origin/main can pin a submodule commit
	# that exists only on another machine.
	name="$(grove_json_str "$input" worktree_name name)"
	base="$(grove_json_str "$input" base_ref)"
	session="$(grove_json_str "$input" session_id)"
	transcript="$(grove_json_str "$input" transcript_path)"
	[ -n "$base" ] || base="HEAD"

	grove_create "$name" "$base" "$session" "$transcript" || {
		printf 'grove: could not create the worktree — see %s\n' "$GROVE_LOG_FILE" >&2
		exit 1
	}

	# The one thing Claude Code reads.
	printf '%s\n' "$GROVE_NEW_PATH"
}

# --- WorktreeRemove ---------------------------------------------------------------------------------
#
# Treat this as BEST-EFFORT, not guaranteed. A completed subagent's clean worktree has been observed
# NOT to fire it (the subagent stays continuable, which appears to keep it alive), and Claude Code's
# periodic cleanup sweep removes worktrees without firing any hook at all. The scheme stays correct
# anyway: create prunes stale registrations and reseeds the database whenever it takes a name, and
# `grove list` flags a stale database on a free slot.
hook_remove() {
	GROVE_TAG="remove"
	local input path name
	input="$(cat || true)"
	grove_log "--- WorktreeRemove input: ${input:-<empty>}"

	path="$(grove_json_str "$input" worktree_path path worktree_name name)"
	[ -n "$path" ] || { grove_log "no worktree path or name in the input; nothing to do"; exit 0; }

	# A value that is not an absolute path is taken to be the worktree's name.
	case "$path" in
	/*) ;;
	*)  path="$(grove_wt_dir "$path")" ;;
	esac

	# Never touch anything outside our own worktree directory.
	case "$path" in
	"$WORKTREES_DIR"/*) ;;
	*) grove_log "ignoring $path (outside $WORKTREES_DIR)"; exit 0 ;;
	esac

	name="$(basename "$path")"

	# Deliberately REFUSE to delete a worktree that still holds uncommitted work, and keep its
	# database too so the site stays inspectable. That is the one case where a slot stays occupied on
	# purpose; `grove list` shows it and `grove remove --force` clears it.
	local dirty=""
	if [ -d "$path" ]; then
		dirty="$(grove_worktree_dirty "$path")"
		if [ -n "$SUBMODULE" ] && [ -d "$path/$SUBMODULE" ]; then
			dirty="$dirty$(git -C "$path/$SUBMODULE" status --porcelain 2>/dev/null)"
		fi
	fi
	if [ -n "$dirty" ]; then
		grove_log "KEEPING $path — it still has uncommitted changes or untracked files."
		grove_log "  Its database is kept too, so the site stays usable. Land finished work with"
		grove_log "  'grove merge $name' (commit it first), or discard it with 'grove remove $name --force'."
		exit 0
	fi

	grove_remove "$name" >>"$GROVE_LOG_FILE" 2>&1
	exit 0
}

# --- SessionStart / PostToolUse[EnterWorktree] --------------------------------------------------------
#
# A file on disk is only awareness if the model reads it, and nothing guarantees that — so the note is
# injected. Registered twice, because the two ways a session lands in a worktree surface at different
# moments: `--worktree` makes the cwd the worktree from the first turn (SessionStart), while a
# background session starts in the main checkout and is moved only when it first tries to write, long
# after SessionStart (EnterWorktree). Subagents get neither event and rely on finding the file.
#
# Runs on EVERY session start, so the not-a-worktree path must be silent and fast.
hook_context() {
	GROVE_TAG="context"
	local input event cwd p n candidates note root
	input="$(cat || true)"
	[ -n "$input" ] || exit 0

	event="$(grove_json_str "$input" hook_event_name)"
	cwd="$(grove_json_str "$input" cwd)"
	grove_log "fired: event=$event cwd=${cwd:-?}"

	# Candidates that might be (inside) the worktree, in order of trust.
	candidates="$cwd"
	if [ "$event" = "PostToolUse" ]; then
		p="$(grove_json_nested "$input" tool_input path)"
		[ -n "$p" ] && candidates="$candidates
$p"
		n="$(grove_json_nested "$input" tool_input name)"
		if [ -n "$n" ]; then
			candidates="$candidates
$(grove_wt_dir "$n")"
		fi
	fi

	note=""
	local c
	while IFS= read -r c; do
		[ -n "$c" ] || continue
		# Reduce the candidate to its worktree root: the path segment right after the worktrees dir.
		case "$c" in
		"$WORKTREES_DIR"/*)
			root="$WORKTREES_DIR/$(printf '%s' "${c#"$WORKTREES_DIR"/}" | cut -d/ -f1)"
			if [ -f "$root/WORKTREE-SITE.md" ]; then
				note="$(cat "$root/WORKTREE-SITE.md")"
				break
			fi
			;;
		esac
	done <<EOF
$candidates
EOF

	[ -n "$note" ] || { grove_log "no worktree note found for: $(printf '%s' "$candidates" | tr '\n' ' ')"; exit 0; }
	grove_log "injecting the worktree note into $event context"

	if command -v jq >/dev/null 2>&1; then
		jq -n --arg event "$event" --arg note "$note" '{
			hookSpecificOutput: {
				hookEventName: $event,
				additionalContext: ("This session runs in an isolated worktree with its own site. Its WORKTREE-SITE.md says:\n\n" + $note)
			}
		}'
	fi
	exit 0
}

# --- PostToolUse[Edit|Write] --------------------------------------------------------------------------
#
# A file change is the signal that this session is doing real work, so that is when the site gets
# built. It costs such a session one pause, once, and costs a question-only session nothing at all.
# Nothing here is fatal: a session with no site is degraded, not broken.
hook_on_edit() {
	GROVE_TAG="on-edit"; export GROVE_TAG
	local wt_root marker name failures
	wt_root="${CLAUDE_PROJECT_DIR:-$PWD}"
	marker="$wt_root/.grove-provision-pending"

	# The common case by far — the main checkout, or a worktree whose site is already built — so it
	# must be the cheapest possible exit.
	[ -f "$marker" ] || exit 0

	name="$(basename "$wt_root")"
	grove_has_site "$name" || { rm -f "$marker"; exit 0; }

	# Stack down: leave the marker for the NEXT edit rather than silently deciding this worktree will
	# never have a site.
	grove_stack_running || {
		grove_log "$name: first edit seen but the $STACK stack is down — leaving the marker for the next one"
		exit 0
	}

	# The marker now SURVIVES a failed build, which is what makes the retry real — and turns "retry on
	# the next edit" into "retry on every edit". For a build that fails reproducibly that is minutes
	# of Magento per keystroke, so the automatic attempts are capped and the rest is handed over
	# deliberately. `grove provision` itself is never capped: that is a human asking.
	failures="$(grove_build_failures "$name")"
	if [ "$failures" -ge 2 ]; then
		grove_log "$name: $failures builds have not finished — not retrying automatically. Run: grove provision $name"
		printf 'This worktree'\''s site has failed to build %s times; grove has stopped retrying on edits.\n' "$failures" >&2
		printf 'Run it where nothing times out:  grove provision %s\n' "$name" >&2
		exit 0
	fi

	# A cut-off previous attempt is worth naming BEFORE the retry, because the retry is about to break
	# that build's lock — after which nothing on screen would say a build had ever been killed.
	[ "$(grove_build_state "$name")" = "interrupted" ] && \
		grove_log "$name: the previous build was cut off part-way — retrying it"

	grove_log "$name: file change — building the site"
	grove_provision "$name" >>"$GROVE_LOG_FILE" 2>&1

	# Report the STATE rather than the exit code. They are not the same question: provision returns 0
	# when another process already holds the build, and the session wants to hear "it is being built"
	# rather than "done".
	case "$(grove_build_state "$name")" in
	ready)
		grove_log "$name: site ready at $(grove_wt_url "$name")"
		printf 'Built this worktree'\''s site on your file change: %s\n' "$(grove_wt_url "$name")" >&2
		;;
	building)
		printf 'This worktree'\''s site is already being built by another process — leaving it to finish.\n' >&2
		;;
	*)
		grove_log "$name: provisioning did not finish — retry with: grove provision $name"
		printf 'Could not build this worktree'\''s site (%s). Retry, where nothing times out:  grove provision %s\n' \
			"$(grove_build_detail "$name" "$(grove_build_state "$name")")" "$name" >&2
		;;
	esac
	exit 0
}
