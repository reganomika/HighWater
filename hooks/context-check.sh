#!/bin/bash
# Stop hook: measures the session's real context size and, when it crosses a
# percentage of the model's context window, forces the model to surface the
# CLAUDE.md task-boundary checkpoint via decision:block (exit 2). It enforces
# only the MECHANICAL half of that rule (context is large / near the ceiling);
# the SEMANTIC half (task closed? old history disposable? is this the focused-
# work exception?) stays the model's own call, made inside the AskUserQuestion
# it raises.
#   - warn tier (>= 55% of window): advisory nudge, enforced as TEXT only; the
#     focused-work exception still applies and the model may decline in one line.
#   - hard tier (>= 88% of window): "approaching ceiling"; the exception no longer
#     applies. Unconditional AskUserQuestion imperative, and it re-fires every Stop
#     until the transcript shows the checkpoint was actually raised.
# Cooldown (warn only): after a warn fire, don't fire again until context grows a
# further STEP tokens. Hard tier is NOT step-gated (see below), so a warn fire that
# lands just under HARD can never strand the ceiling warning past auto-compaction.
# Context shrink (auto-compaction / /clear) lowers the per-model floor so the next
# real crossing fires cleanly.
# Instant global off-switch: touch ~/.claude/hooks/context-check.disabled
#
# If another hook also runs on Stop, keep state and reasons independent: this
# hook's state file is its own, it honors stop_hook_active, and its reason text
# is meant to be appended alongside whatever the other hook emits, not replace it.
#
# Only registered under Stop. Stop and SubagentStop are DISTINCT Claude Code
# events with different payloads (SubagentStop carries agent_id/agent_type, Stop
# does not) and this hook is not registered for SubagentStop, so a subagent's
# completion never reaches it. No agent_id branch is needed or present; a stray
# agent_id in the payload is ignored and changes nothing.

INPUT="$(cat)"

# Kill switch, checked fresh on every run (each run is its own process).
if [ -f "$HOME/.claude/hooks/context-check.disabled" ]; then
  exit 0
fi

# No jq: fail open rather than wedge every Stop.
command -v jq >/dev/null 2>&1 || exit 0

# Effective context window in tokens. This environment runs 1M-window models
# (claude-opus-4-8[1m], claude-sonnet-5, claude-fable-5 all auto-compact near
# ~995K). On a plain 200K-window model, export CONTEXT_CHECK_WINDOW=200000 so the
# percentage thresholds track that window instead of silently never firing. One
# window is correct for every model in this environment (all sampled sessions ran
# 1M); a session mixing a 1M model with a 200K model is not something the data
# shows and is a documented limitation, not handled here.
WINDOW="${CONTEXT_CHECK_WINDOW:-1000000}"
WARN=$(( WINDOW * 55 / 100 ))   # "getting large" nudge, text-enforced (550k @ 1M)
HARD=$(( WINDOW * 88 / 100 ))   # "approaching ceiling", before the ~99% force-compact (880k @ 1M)
STEP=$(( WINDOW * 15 / 100 ))   # warn-tier re-nag only after this much further growth
                                # (150k @ 1M). Derived from the window, not flat, so a
                                # 200k override keeps STEP < WARN and the band stays usable;
                                # a flat 150k would exceed the whole 200k warn->hard band.

STOP_HOOK_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)"
TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Second Stop of the same forced continuation: never re-block (loop guard).
# Our state only advances when we actually fire, and the checkpoint raised
# during that continuation is detected on the next FRESH Stop by timestamp,
# so nothing needs saving here.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# Current context size = summed usage of the VERY LAST assistant message that
# carries a usage object and a real model, on the MAIN transcript (isSidechain
# excluded so a subagent entry can never stand in for the session size).
# cache_read already reflects the whole re-sent prefix, so the last message's
# usage sum is the cumulative context size, not a per-turn spend delta. The
# same pass also returns that message's model + timestamp
# and the latest timestamp of any AskUserQuestion tool_use (used to verify a
# hard-tier checkpoint was actually raised). Read the tail first (bounded cost on
# the large transcripts this hook protects) and fall back to a full scan only if
# the tail holds no usage row.
METRIC_JQ='
  [ inputs
    | select(.type=="assistant")
    | select((.isSidechain // false) == false)
  ] as $rows
  | ( [ $rows[]
        | select(.message.usage != null and .message.model != null)
        | { s: ( (.message.usage.input_tokens // 0)
               + (.message.usage.cache_creation_input_tokens // 0)
               + (.message.usage.cache_read_input_tokens // 0)
               + (.message.usage.output_tokens // 0) ),
            m: .message.model,
            t: (.timestamp // "") } ] ) as $u
  | ( [ $rows[]
        | select(any(.message.content[]?; .type=="tool_use" and .name=="AskUserQuestion"))
        | (.timestamp // "") ]
      | map(select(. != "")) ) as $auq
  | ($u | last) as $last
  | if $last == null then "\t\t\t"
    else "\($last.s)\t\($last.m)\t\($last.t)\t\(($auq | max) // "")"
    end
'

SLICE="$(tail -n 1200 "$TRANSCRIPT" 2>/dev/null)"
LINE="$(printf '%s' "$SLICE" | jq -n -r "$METRIC_JQ" 2>/dev/null)"
SIZE="$(printf '%s' "$LINE" | cut -f1)"
if [ -z "$SIZE" ]; then
  LINE="$(jq -n -r "$METRIC_JQ" "$TRANSCRIPT" 2>/dev/null)"
  SIZE="$(printf '%s' "$LINE" | cut -f1)"
fi
MODEL="$(printf '%s' "$LINE" | cut -f2)"
MSG_TS="$(printf '%s' "$LINE" | cut -f3)"
AUQ_TS="$(printf '%s' "$LINE" | cut -f4)"

# No usable size (empty transcript, jq error): fail open.
case "$SIZE" in
  ''|*[!0-9]*) exit 0 ;;
esac
[ -z "$MODEL" ] && exit 0

STATE_DIR="$HOME/.claude/hooks/state"
mkdir -p "$STATE_DIR" 2>/dev/null
STATE_FILE="$STATE_DIR/${SESSION_ID}.context.json"

STATE='{}'
[ -f "$STATE_FILE" ] && STATE="$(cat "$STATE_FILE" 2>/dev/null)"
[ -z "$STATE" ] && STATE='{}'

# Env window changed since this state was written (e.g. a 1M shell and a 200K
# shell for the same session): the persisted floor is a fraction of a different
# scale, so drop all tracks and re-arm against the current window.
STORED_WINDOW="$(printf '%s' "$STATE" | jq -r '.window // empty' 2>/dev/null)"
if [ "$STORED_WINDOW" != "$WINDOW" ]; then
  STATE="$(jq -n --argjson w "$WINDOW" '{window:$w, models:{}}')"
fi

# Per-model track. Each model keeps its own context thread (a /model switch reads
# a different, independently-growing track), so cooldown state is keyed by model:
# a switch-induced size drop is a different track, never a false "shrink" on this
# one. Fields: forced_at (warn floor / cadence anchor), tier (none|warn|hard),
# fired_ts (anchor for hard-tier checkpoint verification), hard_ack (checkpoint
# verified-raised), hard_ack_at (size at ack, for post-ack cooldown).
TRACK="$(printf '%s' "$STATE" | jq -r --arg m "$MODEL" '
  (.models[$m] // {}) as $t
  | "\($t.forced_at // 0)\t\($t.tier // "none")\t\($t.fired_ts // "")\t\($t.hard_ack // false)\t\($t.hard_ack_at // 0)"
' 2>/dev/null)"
FORCED_AT="$(printf '%s' "$TRACK" | cut -f1)"
TIER_PREV="$(printf '%s' "$TRACK" | cut -f2)"
FIRED_TS="$(printf '%s' "$TRACK" | cut -f3)"
HARD_ACK="$(printf '%s' "$TRACK" | cut -f4)"
HARD_ACK_AT="$(printf '%s' "$TRACK" | cut -f5)"
case "$FORCED_AT" in ''|*[!0-9]*) FORCED_AT=0 ;; esac
case "$HARD_ACK_AT" in ''|*[!0-9]*) HARD_ACK_AT=0 ;; esac
[ -z "$TIER_PREV" ] && TIER_PREV="none"
[ "$HARD_ACK" = "true" ] || HARD_ACK="false"

save_track() { # forced_at tier fired_ts hard_ack hard_ack_at
  jq -n --argjson st "$STATE" --arg m "$MODEL" --argjson w "$WINDOW" \
    --argjson fa "$1" --arg tr "$2" --arg ts "$3" --argjson ha "$4" --argjson haa "$5" '
    ($st // {})
    | .window = $w
    | .models = (.models // {})
    | .models[$m] = {forced_at:$fa, tier:$tr, fired_ts:$ts, hard_ack:$ha, hard_ack_at:$haa}
  ' > "$STATE_FILE" 2>/dev/null
}

emit_block() { # reason
  jq -n --arg reason "$1" '{decision:"block", reason:$reason}'
  printf '%s\n' "$1" >&2
}

# Floor-follow, run UNCONDITIONALLY (before the warn gate) so a real compaction
# that drops this track well below WARN re-arms it immediately, instead of the
# stale high-water mark persisting until several later growth cycles pull it down.
# Reset the whole track on shrink so the next climb re-fires warn then hard clean.
if [ "$SIZE" -lt "$FORCED_AT" ]; then
  FORCED_AT="$SIZE"; TIER_PREV="none"; FIRED_TS=""; HARD_ACK="false"; HARD_ACK_AT=0
  save_track "$SIZE" "none" "" false 0
fi

# Below the soft threshold: the common case, stay silent (floor already persisted
# above if it moved).
if [ "$SIZE" -lt "$WARN" ]; then
  exit 0
fi

PCT=$(( SIZE * 100 / WINDOW ))

if [ "$SIZE" -lt "$HARD" ]; then
  # ---- WARN tier: advisory, text-enforced, step-gated cadence ----
  if [ "$SIZE" -lt $(( FORCED_AT + STEP )) ]; then
    exit 0
  fi
  REASON="Context boundary check (mechanical half of the CLAUDE.md task-boundary rule; this tier is an advisory nudge enforced as text, not a forced tool call). The live context on ${MODEL} is ${SIZE} tokens, ${PCT}% of this session's ~${WINDOW}-token window, past the soft \"getting large\" mark (${WARN}) but below the hard mark (${HARD}). You judge the semantic half. After one line naming what you observed, do exactly one of: (a) raise the checkpoint now by calling the AskUserQuestion tool, single-select, header \"Context\", multiSelect false, three options with the visible text in the conversation language: \"New-chat handoff prompt\" (you generate a self-contained handoff prompt), \"Clear context, stay here\" (you tell the user to run /clear), \"Continue as-is\" (proceed unchanged); or (b) if this is focused continuous work where the accumulated history is needed (the documented exception), say so in one line and continue. You will not be nudged again until context grows another ${STEP} tokens."
  emit_block "$REASON"
  save_track "$SIZE" "warn" "$FIRED_TS" false "$HARD_ACK_AT"
  exit 2
fi

# ---- HARD tier: >= HARD, not step-gated, re-fires until the checkpoint is
# actually raised (verified in the transcript), then respects the answer ----

# Was a checkpoint actually raised since the last hard fire? (AskUserQuestion
# tool_use with a timestamp after this track's fire.) If so, ack and go quiet:
# the user has now been given the choice; do not re-nag on their answer.
if [ "$TIER_PREV" = "hard" ] && [ "$HARD_ACK" != "true" ] && [ -n "$FIRED_TS" ] && [ -n "$AUQ_TS" ]; then
  if [[ "$AUQ_TS" > "$FIRED_TS" ]]; then
    save_track "$FORCED_AT" "hard" "$FIRED_TS" true "$SIZE"
    exit 0
  fi
fi

# Post-ack cooldown: the checkpoint was raised and answered; don't re-nag until a
# further STEP of growth (near the ceiling that means auto-compaction handles it).
if [ "$HARD_ACK" = "true" ] && [ "$SIZE" -lt $(( HARD_ACK_AT + STEP )) ]; then
  exit 0
fi

# Fire hard: first crossing, an unresolved prose-dodge / dropped reason, or growth
# past the post-ack cooldown. decision:block + stderr.
REASON="Context boundary checkpoint (mechanical half of the CLAUDE.md task-boundary rule). The live context on ${MODEL} is ${SIZE} tokens, ${PCT}% of this session's ~${WINDOW}-token window, past the hard mark (${HARD}). The harness force-compacts near ~99%; do not wait for it, and the focused-work exception does NOT apply this close to the ceiling (CLAUDE.md trigger 3). You must call the AskUserQuestion tool now, before writing anything else: one single-select question, header \"Context\", multiSelect false, exactly these three options (translate the visible text into the conversation language, keep the meaning): \"New-chat handoff prompt\" (you generate a self-contained handoff prompt), \"Clear context, stay here\" (you tell the user to run /clear), \"Continue as-is\" (proceed unchanged). Precede the tool call with one line naming what you observed (size and %). Only if the AskUserQuestion tool is genuinely not available to you this turn, not merely inconvenient, state IN CAPS that auto-compaction is imminent and list those three options in text so the user can still choose."
emit_block "$REASON"
save_track "$SIZE" "hard" "$MSG_TS" false "$HARD_ACK_AT"
exit 2
