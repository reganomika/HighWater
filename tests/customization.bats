#!/usr/bin/env bats
# Covers ~/.claude/hooks/context-check.conf and the CONTEXT_CHECK_* knobs:
# the file is sourced, a real exported env var wins over it, malformed
# values fail open to the shipped defaults, and each tier's disable switch
# actually silences only that tier. See CUSTOMIZE.md for the user-facing
# version of this contract.

load helpers.bash

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

@test "a config file rescales the thresholds" {
  # WINDOW 100000, WARN_PCT 20 -> WARN=20000. Default WARN (55% of 200K =
  # 110000) would stay silent at this size; the custom config must not.
  write_config "CONTEXT_CHECK_WINDOW=100000" "CONTEXT_CHECK_WARN_PCT=20" "CONTEXT_CHECK_HARD_PCT=40"
  assistant_row 25000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"advisory nudge"* ]]
}

@test "an exported env var wins over the config file" {
  write_config "CONTEXT_CHECK_WINDOW=100000"
  export CONTEXT_CHECK_WINDOW=200000
  # 25000 is warn-tier at the file's 100000 window (55% = 55000... actually
  # below; use a size that only fires under the SMALLER, file-only window)
  assistant_row 60000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  unset CONTEXT_CHECK_WINDOW
  # 60000 is warn-tier at window=100000 (WARN=55000) but sub-threshold at
  # window=200000 (WARN=110000). Firing here would mean the file won, not env.
  [ "$status" -eq 0 ]
}

@test "a malformed percentage falls back to the shipped default" {
  write_config "CONTEXT_CHECK_WARN_PCT=not-a-number"
  # 120000 is warn-tier under the real default (55% of 200000 = 110000).
  assistant_row 120000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]
}

@test "warn >= hard in the config falls back to the shipped defaults" {
  write_config "CONTEXT_CHECK_WARN_PCT=90" "CONTEXT_CHECK_HARD_PCT=50"
  assistant_row 120000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"advisory nudge"* ]]
}

@test "CONTEXT_CHECK_DISABLE_WARN silences only the warn tier" {
  write_config "CONTEXT_CHECK_DISABLE_WARN=1"
  assistant_row 120000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 0 ]

  assistant_row 180000 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"must call the AskUserQuestion tool now"* ]]
}

@test "CONTEXT_CHECK_DISABLE_HARD silences only the hard tier" {
  write_config "CONTEXT_CHECK_DISABLE_HARD=1"
  assistant_row 120000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"advisory nudge"* ]]

  assistant_row 190000 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 0 ]
}

@test "no config file present behaves exactly like the shipped defaults" {
  assistant_row 109999 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 0 ]

  assistant_row 110000 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 2 ]
}
