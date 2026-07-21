# Shared fixtures for context-check.bats. Not a test file itself.

SCRIPT="$BATS_TEST_DIRNAME/../hooks/context-check.sh"

# Resolved once, before any test can restrict PATH (the missing-jq test
# does exactly that): lets the harness itself keep building fixtures with
# jq even while the hook under test can't find it.
JQ_BIN="$(command -v jq)"

# Fresh $HOME (isolates hook state) and a session id per test.
setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME/.claude/hooks"
  TRANSCRIPT="$SANDBOX/transcript.jsonl"
  : > "$TRANSCRIPT"
  SESSION_ID="test-session"
  unset CONTEXT_CHECK_WINDOW
}

teardown_sandbox() {
  rm -rf "$SANDBOX"
}

# assistant_row <size> <model> <timestamp> — appends a row that carries
# a real usage+model pair, so it can become the transcript's "$last" size.
assistant_row() {
  "$JQ_BIN" -nc --argjson size "$1" --arg model "$2" --arg ts "$3" \
    '{type:"assistant", isSidechain:false, timestamp:$ts,
      message:{model:$model,
        usage:{input_tokens:$size, cache_creation_input_tokens:0,
               cache_read_input_tokens:0, output_tokens:0},
        content:[]}}' >> "$TRANSCRIPT"
}

# askuq_row <timestamp> — appends an AskUserQuestion tool_use with no usage,
# mirroring how the real transcript records a raised checkpoint.
askuq_row() {
  "$JQ_BIN" -nc --arg ts "$1" \
    '{type:"assistant", isSidechain:false, timestamp:$ts,
      message:{content:[{type:"tool_use", name:"AskUserQuestion"}]}}' >> "$TRANSCRIPT"
}

# sidechain_row <size> <model> <timestamp> — a subagent's own assistant
# turn; must never be able to stand in for the main session's $last.
sidechain_row() {
  "$JQ_BIN" -nc --argjson size "$1" --arg model "$2" --arg ts "$3" \
    '{type:"assistant", isSidechain:true, timestamp:$ts,
      message:{model:$model,
        usage:{input_tokens:$size, cache_creation_input_tokens:0,
               cache_read_input_tokens:0, output_tokens:0},
        content:[]}}' >> "$TRANSCRIPT"
}

# invoke_hook [stop_hook_active] — pipes the standard Stop payload to the
# script and runs it under bats' `run`, so call this as `run invoke_hook`.
invoke_hook() {
  local active="${1:-false}"
  "$JQ_BIN" -nc --arg tp "$TRANSCRIPT" --arg sid "$SESSION_ID" --argjson active "$active" \
    '{transcript_path:$tp, session_id:$sid, stop_hook_active:$active}' \
    | bash "$SCRIPT"
}

state_field() {
  local model="$1" field="$2"
  "$JQ_BIN" -r --arg m "$model" ".models[\$m].$field // empty" \
    "$HOME/.claude/hooks/state/${SESSION_ID}.context.json" 2>/dev/null
}
