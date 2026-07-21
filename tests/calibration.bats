#!/usr/bin/env bats
# Covers self-calibration from real compact_boundary events: the hook lowers
# its own hard mark once it has actually witnessed where auto-compaction
# fired on this account, instead of only trusting an assumed percentage.
# Numbers assume the 200K default window: WARN=110000, HARD=176000.

load helpers.bash

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

@test "a real compact_boundary event gets persisted to the observed file" {
  compact_boundary_row 150000 "2026-01-01T00:00:01Z"
  assistant_row 50000 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 0 ]
  [ "$(jq -r '.observed_pre_tokens' "$(observed_file)")" = "150000" ]
}

@test "a low observed compaction point pulls the hard mark down" {
  # 150000 observed -> calibrated hard = 135000 (90%), below the configured
  # 176000. 140000 sits between the two: fires hard only if calibration
  # actually applied.
  compact_boundary_row 150000 "2026-01-01T00:00:01Z"
  assistant_row 140000 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"must call the AskUserQuestion tool now"* ]]
}

@test "calibration never raises the hard mark above the configured value" {
  # An absurdly high observed point (990000*0.9 way above 176000) must not
  # relax anything: the configured 176000 mark still governs.
  compact_boundary_row 999999 "2026-01-01T00:00:01Z"
  assistant_row 180000 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"must call the AskUserQuestion tool now"* ]]
}

@test "calibration never pushes the hard mark below the soft mark" {
  # 100000 observed -> 90% = 90000, below WARN (110000): must be rejected,
  # leaving the configured 176000 hard mark in place. 120000 is warn-tier
  # under the real default and would wrongly read as hard-tier if the
  # calibration guard didn't hold.
  compact_boundary_row 100000 "2026-01-01T00:00:01Z"
  assistant_row 120000 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"advisory nudge"* ]]
  [[ "$output" != *"must call the AskUserQuestion tool now"* ]]
}

@test "the calibration margin is exactly 20000 tokens below the observed point" {
  # observed 195999 -> calibrated 175999, one under the configured hard mark
  # (176000): must apply.
  compact_boundary_row 195999 "2026-01-01T00:00:01Z"
  assistant_row 175999 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"must call the AskUserQuestion tool now"* ]]
}

@test "an observed point exactly at the margin from the configured hard mark does not override" {
  # observed 196000 -> calibrated 176000, equal to (not less than) the
  # configured hard mark: guard requires strictly lower, must not apply.
  # 175999 would still be silent under the unchanged, configured hard mark.
  compact_boundary_row 196000 "2026-01-01T00:00:01Z"
  assistant_row 175999 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"advisory nudge"* ]]
  [[ "$output" != *"must call the AskUserQuestion tool now"* ]]
}

@test "an observed point at or below the margin itself is ignored, not underflowed" {
  compact_boundary_row 15000 "2026-01-01T00:00:01Z"
  assistant_row 120000 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"advisory nudge"* ]]
}

@test "a malformed observed-compaction file is ignored" {
  mkdir -p "$HOME/.claude/hooks"
  echo "not json" > "$(observed_file)"
  assistant_row 140000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"advisory nudge"* ]]
}
