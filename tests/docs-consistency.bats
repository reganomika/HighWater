#!/usr/bin/env bats
# hooks/context-check.sh is the ONE source of truth for the 55/88/15
# thresholds; every doc file quotes those numbers by hand in prose. This
# doesn't template the docs (they read better hand-written), it just fails
# loudly if a doc's number stops matching what the script actually does,
# so a threshold change can't silently drift out of sync in five other
# files. Run after any edit to WARN/HARD/STEP in the script.

SCRIPT="$BATS_TEST_DIRNAME/../hooks/context-check.sh"
REPO_ROOT="$BATS_TEST_DIRNAME/.."
DOCS=(
  "$REPO_ROOT/README.md"
  "$REPO_ROOT/FAQ.md"
  "$REPO_ROOT/INSTALL.md"
  "$REPO_ROOT/CLAUDE.md.example"
  "$REPO_ROOT/COMMANDS.md"
  "$REPO_ROOT/skills/refresh-context-rules/SKILL.md"
)

# extract_pct <VARNAME> — pulls the literal percent out of e.g.
# `WARN=$(( WINDOW * 55 / 100 ))`, so this test tracks the script instead
# of hardcoding its own copy of 55/88/15.
extract_pct() {
  awk -v var="$1" '$0 ~ "^"var"=" { for (i=1;i<=NF;i++) if ($i=="*") { print $(i+1); exit } }' "$SCRIPT"
}

# any_doc_contains <needle> — true if at least one doc file quotes this
# exact string. Threshold numbers are scattered across different files
# depending on what each doc is explaining, not every file repeats every
# number, so the set is checked as a whole rather than file by file.
any_doc_contains() {
  grep -qF -- "$1" "${DOCS[@]}"
}

setup() {
  WARN_PCT="$(extract_pct WARN)"
  HARD_PCT="$(extract_pct HARD)"
  STEP_PCT="$(extract_pct STEP)"
  [ -n "$WARN_PCT" ] && [ -n "$HARD_PCT" ] && [ -n "$STEP_PCT" ]
}

@test "the script defines all three thresholds as extractable percentages" {
  [ "$WARN_PCT" -gt 0 ]
  [ "$HARD_PCT" -gt "$WARN_PCT" ]
  [ "$STEP_PCT" -gt 0 ]
}

@test "docs quote the current soft-mark and hard-mark percentages" {
  any_doc_contains "${WARN_PCT}%"
  any_doc_contains "${HARD_PCT}%"
}

@test "docs quote the current cooldown-step percentage" {
  any_doc_contains "${STEP_PCT}%"
}

@test "docs quote the current default-window token amounts" {
  local window=200000
  any_doc_contains "$(( window * WARN_PCT / 100 / 1000 ))k"
  any_doc_contains "$(( window * HARD_PCT / 100 / 1000 ))k"
  any_doc_contains "$(( window * STEP_PCT / 100 / 1000 ))k"
}

@test "docs quote the current 1M-override token amounts" {
  local window=1000000
  any_doc_contains "$(( window * WARN_PCT / 100 / 1000 ))k"
  any_doc_contains "$(( window * HARD_PCT / 100 / 1000 ))k"
  any_doc_contains "$(( window * STEP_PCT / 100 / 1000 ))k"
}
