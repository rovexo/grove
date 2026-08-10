#!/usr/bin/env bash
# shellcheck disable=SC2034   # a profile exists to SET defaults; the engine is what reads them
#
# Profile: plain — a repository with no platform conventions to inherit.
#
# The default, and deliberately almost empty. A project that names no platform gets worktrees,
# branches, path strategies and merges; it just has no config file to rewrite and no docroot to serve
# from, because grove has no way to guess either.
#
# Everything below is a DEFAULT. The project's .grove.conf is sourced after this file, so overriding
# is plain assignment and extending is `+=`.

# The checkout root is the docroot. Set GROVE_DOCROOT in the project file if the served directory is
# a subdirectory.
GROVE_DOCROOT=""

# Nothing is copied, created or linked unless the project says so.
GROVE_PATHS=()
