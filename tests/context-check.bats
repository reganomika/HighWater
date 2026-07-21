#!/usr/bin/env bats
# Exercises the context-check.sh state machine against synthetic transcripts.
# Numbers below assume the 200K default window: WARN=110000, HARD=176000,
# STEP=30000 (55% / 88% / 15% of 200000). If those percentages change in
# hooks/context-check.sh, the literals here must move with them.

load helpers.bash

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

@test "the soft mark sits at exactly 55% of the window" {
  assistant_row 109999 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 0 ]

  assistant_row 110000 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 2 ]
}

@test "the hard mark sits at exactly 88% of the window" {
  assistant_row 175999 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"advisory nudge"* ]]

  assistant_row 176000 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"must call the AskUserQuestion tool now"* ]]
}

@test "below the soft mark stays silent" {
  assistant_row 50000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "warn tier blocks once and names the advisory tone" {
  # Exit 2 is the actual block; Claude Code ignores stdout/JSON on exit 2
  # and only reads stderr, so that's what's asserted here, not a JSON payload.
  assistant_row 120000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"advisory nudge"* ]]
}

@test "warn tier is step-gated and does not re-fire without growth" {
  assistant_row 120000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]

  run invoke_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the warn cooldown step is exactly 15% of the window" {
  assistant_row 120000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]

  # 149999 = FORCED_AT(120000) + STEP(30000) - 1: still inside cooldown.
  assistant_row 149999 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 0 ]

  # 150000 = FORCED_AT + STEP exactly: cooldown clears.
  assistant_row 150000 claude-sonnet-5 "2026-01-01T00:00:03Z"
  run invoke_hook
  [ "$status" -eq 2 ]
}

@test "warn tier re-fires after another STEP of growth" {
  assistant_row 120000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]

  assistant_row 155000 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 2 ]
}

@test "a jump straight past the hard mark skips the warn tier" {
  assistant_row 180000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"must call the AskUserQuestion tool now"* ]]
}

@test "hard tier keeps re-firing every Stop until a checkpoint is raised" {
  assistant_row 180000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]

  # No growth, no AskUserQuestion yet: still not step-gated, fires again.
  run invoke_hook
  [ "$status" -eq 2 ]
}

@test "hard tier acks once AskUserQuestion appears after the fire and goes quiet" {
  assistant_row 180000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]

  askuq_row "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 0 ]
  [ "$(state_field claude-sonnet-5 hard_ack)" = "true" ]

  # Post-ack cooldown: no further growth, stays quiet.
  run invoke_hook
  [ "$status" -eq 0 ]
}

@test "hard tier re-fires after STEP growth past a post-ack cooldown" {
  assistant_row 180000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]

  askuq_row "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 0 ]

  assistant_row 215000 claude-sonnet-5 "2026-01-01T00:00:03Z"
  run invoke_hook
  [ "$status" -eq 2 ]
}

@test "an AskUserQuestion timestamped before the fire does not count as an ack" {
  askuq_row "2026-01-01T00:00:01Z"
  assistant_row 180000 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 2 ]

  # Stale AUQ predates this fire: must still re-fire, not ack.
  run invoke_hook
  [ "$status" -eq 2 ]
}

@test "shrink to a still-elevated size resets the floor without an immediate re-fire" {
  assistant_row 120000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [ "$(state_field claude-sonnet-5 forced_at)" = "120000" ]

  # Simulated compaction: smaller, but still above WARN.
  assistant_row 115000 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 0 ]
  [ "$(state_field claude-sonnet-5 forced_at)" = "115000" ]
  [ "$(state_field claude-sonnet-5 tier)" = "none" ]

  # Growth measured from the NEW floor (115000), not the old one, confirms
  # the reset actually took effect rather than just not re-firing by luck.
  assistant_row 145000 claude-sonnet-5 "2026-01-01T00:00:03Z"
  run invoke_hook
  [ "$status" -eq 2 ]
}

@test "shrink below the soft mark goes fully silent" {
  assistant_row 180000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]

  assistant_row 40000 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "each model keeps its own independent track" {
  assistant_row 180000 claude-opus-4-8 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]

  # Switch to a different model at a small size: must not inherit opus's
  # elevated floor or its hard tier.
  assistant_row 20000 claude-sonnet-5 "2026-01-01T00:00:02Z"
  run invoke_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # Back to the first model, still elevated, no ack was ever raised for it:
  # its own track must have persisted through the other model's turns.
  assistant_row 185000 claude-opus-4-8 "2026-01-01T00:00:03Z"
  run invoke_hook
  [ "$status" -eq 2 ]
}

@test "a sidechain (subagent) row never stands in for the main transcript" {
  sidechain_row 500000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the kill switch silences the hook regardless of size" {
  touch "$HOME/.claude/hooks/context-check.disabled"
  assistant_row 199999 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a forced continuation (stop_hook_active) never re-blocks" {
  assistant_row 180000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an empty transcript fails open" {
  run invoke_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "CONTEXT_CHECK_WINDOW overrides the model-based default and rescales thresholds" {
  export CONTEXT_CHECK_WINDOW=1000000
  # claude-opus-4-8 would otherwise auto-default to 200K (see below); the
  # explicit override must win regardless. 120000 is warn-tier at 200K but
  # well under 55% of 1M.
  assistant_row 120000 claude-opus-4-8 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "claude-sonnet-5 auto-defaults to the 1M window when nothing is configured" {
  unset CONTEXT_CHECK_WINDOW
  # 300000 would already be well past the hard mark at a 200K window
  # (176000); silence here proves 1M was actually selected, not 200K.
  assistant_row 300000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "claude-fable-5 auto-defaults to the 1M window when nothing is configured" {
  unset CONTEXT_CHECK_WINDOW
  assistant_row 300000 claude-fable-5 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unrecognized model falls back to the 200K default when nothing is configured" {
  unset CONTEXT_CHECK_WINDOW
  # 120000 is warn-tier at 200K (110000-176000); silence would mean it was
  # wrongly treated as a 1M window instead.
  assistant_row 120000 claude-opus-4-8 "2026-01-01T00:00:01Z"
  run invoke_hook
  [ "$status" -eq 2 ]
  [[ "$output" == *"advisory nudge"* ]]
}

@test "state files older than 30 days are pruned, everything else survives" {
  local state_dir="$HOME/.claude/hooks/state"
  mkdir -p "$state_dir"
  touch -t 202001010000 "$state_dir/stale-session.context.json"
  touch "$state_dir/fresh-session.context.json"
  touch -t 202001010000 "$state_dir/unrelated-tool-state.json"

  assistant_row 50000 claude-sonnet-5 "2026-01-01T00:00:01Z"
  run invoke_hook

  [ ! -f "$state_dir/stale-session.context.json" ]
  [ -f "$state_dir/fresh-session.context.json" ]
  [ -f "$state_dir/unrelated-tool-state.json" ]
}

@test "a missing jq fails open before touching the transcript" {
  local hidden="$SANDBOX/bin"
  mkdir -p "$hidden"
  for tool in bash cat mkdir cut tail printf sh; do
    local real
    real="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sf "$real" "$hidden/$tool"
  done
  assistant_row 180000 claude-sonnet-5 "2026-01-01T00:00:01Z"

  local old_path="$PATH"
  export PATH="$hidden"
  run invoke_hook
  export PATH="$old_path"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
