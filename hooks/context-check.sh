#!/bin/bash
# Stop hook: measures the session's real context size and, when it crosses a
# percentage of the model's context window, forces the model to surface the
# CLAUDE.md task-boundary checkpoint via decision:block (exit 2). It enforces
# only the MECHANICAL half of that rule (context is large / near the ceiling);
# the SEMANTIC half (task closed? old history disposable? is this the focused-
# work exception?) stays the model's own call, made inside the AskUserQuestion
# it raises.
#   - warn tier (>= 55% of window, default): advisory nudge, enforced as TEXT
#     only; the focused-work exception still applies and the model may decline
#     in one line.
#   - hard tier (>= 88% of window, default): "approaching ceiling"; the
#     exception no longer applies. Unconditional AskUserQuestion imperative,
#     and it re-fires every Stop until the transcript shows the checkpoint
#     was actually raised.
# Cooldown (warn only): after a warn fire, don't fire again until context grows a
# further STEP tokens. Hard tier is NOT step-gated (see below), so a warn fire that
# lands just under HARD can never strand the ceiling warning past auto-compaction.
# Context shrink (auto-compaction / /clear) lowers the per-model floor so the next
# real crossing fires cleanly.
# Instant global off-switch: touch ~/.claude/hooks/context-check.disabled
# Every threshold above (window, warn/hard/step %, and each tier individually)
# is user-configurable via ~/.claude/hooks/context-check.conf; see CUSTOMIZE.md.
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

# User customization. A real exported env var always wins (so a one-off
# `CONTEXT_CHECK_WINDOW=... claude` or a CI override never gets clobbered by
# the file); otherwise ~/.claude/hooks/context-check.conf is sourced if it
# exists. Every variable here, its default, and what it does is documented
# in CUSTOMIZE.md; context-check.conf.example is a copy-and-edit template.
_ENV_WINDOW="${CONTEXT_CHECK_WINDOW-}"
_ENV_WARN_PCT="${CONTEXT_CHECK_WARN_PCT-}"
_ENV_HARD_PCT="${CONTEXT_CHECK_HARD_PCT-}"
_ENV_STEP_PCT="${CONTEXT_CHECK_STEP_PCT-}"
_ENV_DISABLE_WARN="${CONTEXT_CHECK_DISABLE_WARN-}"
_ENV_DISABLE_HARD="${CONTEXT_CHECK_DISABLE_HARD-}"

CONFIG_FILE="$HOME/.claude/hooks/context-check.conf"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090  # user's own file, path is fixed, not attacker input
  . "$CONFIG_FILE"
fi

# CONTEXT_CHECK_WINDOW is deliberately left UNRESOLVED here if the user set
# it nowhere (no env var, no config file): auto-detecting a model-appropriate
# default needs the model, which isn't known until the transcript is parsed
# below. An explicit value, from either source, is honored immediately and
# skips auto-detection entirely.
CONTEXT_CHECK_WINDOW="${_ENV_WINDOW:-${CONTEXT_CHECK_WINDOW-}}"
case "$CONTEXT_CHECK_WINDOW" in *[!0-9]*) CONTEXT_CHECK_WINDOW="" ;; esac

CONTEXT_CHECK_WARN_PCT="${_ENV_WARN_PCT:-${CONTEXT_CHECK_WARN_PCT:-55}}"
CONTEXT_CHECK_HARD_PCT="${_ENV_HARD_PCT:-${CONTEXT_CHECK_HARD_PCT:-88}}"
CONTEXT_CHECK_STEP_PCT="${_ENV_STEP_PCT:-${CONTEXT_CHECK_STEP_PCT:-15}}"
DISABLE_WARN="${_ENV_DISABLE_WARN:-${CONTEXT_CHECK_DISABLE_WARN-}}"
DISABLE_HARD="${_ENV_DISABLE_HARD:-${CONTEXT_CHECK_DISABLE_HARD-}}"

# Malformed numbers fail open to the shipped defaults rather than wedging
# every Stop on a typo in the config file.
case "$CONTEXT_CHECK_WARN_PCT" in ''|*[!0-9]*) CONTEXT_CHECK_WARN_PCT=55 ;; esac
case "$CONTEXT_CHECK_HARD_PCT" in ''|*[!0-9]*) CONTEXT_CHECK_HARD_PCT=88 ;; esac
case "$CONTEXT_CHECK_STEP_PCT" in ''|*[!0-9]*) CONTEXT_CHECK_STEP_PCT=15 ;; esac
if [ "$CONTEXT_CHECK_WARN_PCT" -lt 1 ] || [ "$CONTEXT_CHECK_HARD_PCT" -gt 100 ] \
   || [ "$CONTEXT_CHECK_WARN_PCT" -ge "$CONTEXT_CHECK_HARD_PCT" ]; then
  printf 'context-check.sh: CONTEXT_CHECK_WARN_PCT/HARD_PCT (%s/%s) must satisfy 1 <= warn < hard <= 100; falling back to 55/88\n' \
    "$CONTEXT_CHECK_WARN_PCT" "$CONTEXT_CHECK_HARD_PCT" >&2
  CONTEXT_CHECK_WARN_PCT=55
  CONTEXT_CHECK_HARD_PCT=88
fi
# WINDOW/WARN/HARD/STEP themselves are computed further below, once the
# transcript scan has resolved MODEL (needed for auto-detection).

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
# shellcheck disable=SC2016  # single quotes are deliberate: this is jq source, $vars are jq's, not the shell's
# Same pass also looks for the most recent compact_boundary system event in
# the scanned range: its compactMetadata.preTokens is the harness's own
# record of the exact size a REAL auto-compaction fired at for this account,
# used below to calibrate the hard mark instead of trusting an assumed
# percentage alone. Rare event, piggybacks on whichever scan (tail or full)
# already ran for the usage lookup rather than forcing an extra full read.
METRIC_JQ='
  [ inputs ] as $all
  | ( [ $all[]
        | select(.type=="assistant")
        | select((.isSidechain // false) == false)
      ] ) as $rows
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
  | ( [ $all[]
        | select(.type=="system" and .subtype=="compact_boundary")
        | (.compactMetadata.preTokens // empty) ]
      | last ) as $compact_pre
  | ($u | last) as $last
  | if $last == null then "\t\t\t\t"
    else "\($last.s)\t\($last.m)\t\($last.t)\t\(($auq | max) // "")\t\($compact_pre // "")"
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
COMPACT_PRE="$(printf '%s' "$LINE" | cut -f5)"
case "$COMPACT_PRE" in ''|*[!0-9]*) COMPACT_PRE="" ;; esac

# No usable size (empty transcript, jq error): fail open.
case "$SIZE" in
  ''|*[!0-9]*) exit 0 ;;
esac
[ -z "$MODEL" ] && exit 0

# Resolve the window now that MODEL is known. An explicit CONTEXT_CHECK_WINDOW
# (env var or config file, checked earlier) always wins and skips detection
# entirely. Otherwise: claude-sonnet-5 and claude-fable-5 always run with a
# 1M context window on any plan, per Claude Code's own docs (no 200K variant
# exists for them, no opt-in needed), so defaulting them to 200K would make
# the hard tier fire almost immediately in every session, not near any real
# ceiling. Everything else (Opus, Haiku, older models) varies by plan and
# usage credits, so 200K stays the conservative fallback there; a wrong
# guess in that direction fails toward firing early, not toward silently
# never firing, and self-calibration below corrects it once a real
# compaction is actually observed.
if [ -z "$CONTEXT_CHECK_WINDOW" ]; then
  case "$MODEL" in
    claude-sonnet-5|claude-fable-5) CONTEXT_CHECK_WINDOW=1000000 ;;
    *) CONTEXT_CHECK_WINDOW=200000 ;;
  esac
fi
WINDOW="$CONTEXT_CHECK_WINDOW"
WARN=$(( WINDOW * CONTEXT_CHECK_WARN_PCT / 100 ))   # "getting large" nudge, text-enforced
HARD=$(( WINDOW * CONTEXT_CHECK_HARD_PCT / 100 ))   # "approaching ceiling", before the harness force-compacts
                                                     # (near ~99% of window in observed sessions, sometimes
                                                     # earlier; calibrated downward below once a real
                                                     # compaction is actually observed, see COMPACT_PRE below)
STEP=$(( WINDOW * CONTEXT_CHECK_STEP_PCT / 100 ))   # re-nag cadence, both tiers. Derived from the
                                                     # window, not flat, so a smaller window keeps
                                                     # STEP inside the warn->hard band.

# Calibrate the hard mark from a REAL observed auto-compaction instead of
# only trusting an assumed percentage. If this scan caught a compact_boundary
# event, persist its preTokens (account-wide, not per-session: a real
# compaction point is evidence about the account, not one conversation, and
# must survive past this event scrolling out of the tail -n 1200 window on
# later runs, so it's read from the file unconditionally below, not
# re-derived from the scan every time).
#
# The margin below that observed point is a FIXED token count, not a
# percentage of it: what it needs to protect is "enough room left to
# generate an AskUserQuestion checkpoint and a handoff prompt before the
# real ceiling", and that cost doesn't scale with window size. A percentage
# margin would over-protect on a 1M window (10% of ~1M is a ~100K buffer,
# nobody needs that much runway to write a handoff) and, worse, could
# under-protect if the window were ever smaller than assumed. CALIBRATION_MARGIN
# is deliberately generous for a task that realistically costs low
# thousands of tokens.
#
# Only ever lowers the mark, never raises it past what's configured, and
# never below WARN: a low first observation makes the hook fire earlier
# than strictly necessary, annoying but safe; calibration never gets to
# make it fire later than the configured assumption would have on its own.
# Malformed or missing observation file: ignored, no fail-closed path here.
CALIBRATION_MARGIN=20000
OBSERVED_FILE="$HOME/.claude/hooks/context-check.observed.json"
if [ -n "$COMPACT_PRE" ]; then
  jq -n --argjson p "$COMPACT_PRE" '{observed_pre_tokens: $p}' > "$OBSERVED_FILE" 2>/dev/null
fi
OBSERVED_PRE=""
if [ -f "$OBSERVED_FILE" ]; then
  OBSERVED_PRE="$(jq -r '.observed_pre_tokens // empty' "$OBSERVED_FILE" 2>/dev/null)"
fi
case "$OBSERVED_PRE" in ''|*[!0-9]*) OBSERVED_PRE="" ;; esac
if [ -n "$OBSERVED_PRE" ] && [ "$OBSERVED_PRE" -gt "$CALIBRATION_MARGIN" ]; then
  CALIBRATED_HARD=$(( OBSERVED_PRE - CALIBRATION_MARGIN ))
  if [ "$CALIBRATED_HARD" -lt "$HARD" ] && [ "$CALIBRATED_HARD" -gt "$WARN" ]; then
    HARD="$CALIBRATED_HARD"
  fi
fi

STATE_DIR="$HOME/.claude/hooks/state"
mkdir -p "$STATE_DIR" 2>/dev/null

# One file per session, forever, with nothing else ever removing them.
# Prune this hook's own files (only the *.context.json suffix, never
# touching whatever other hooks keep in the same directory) once they've
# been untouched for a month; a session that old is not coming back to
# use its cooldown state anyway.
find "$STATE_DIR" -maxdepth 1 -name '*.context.json' -mtime +30 -delete 2>/dev/null

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
  # Exit 2 is what actually blocks the Stop; Claude Code only parses JSON on
  # exit 0 and ignores stdout entirely on exit 2, so stderr is the one real
  # channel here, not a JSON decision:block payload alongside it.
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
  if [ -n "$DISABLE_WARN" ]; then
    exit 0
  fi
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

# CONTEXT_CHECK_DISABLE_HARD trades away the tool's actual safety net (no
# more forced stop before auto-compaction), leaving only the warn nudge if
# that's still enabled. Deliberate opt-out, documented in CUSTOMIZE.md, not
# a bug.
if [ -n "$DISABLE_HARD" ]; then
  exit 0
fi

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
REASON="Context boundary checkpoint (mechanical half of the CLAUDE.md task-boundary rule). The live context on ${MODEL} is ${SIZE} tokens, ${PCT}% of this session's ~${WINDOW}-token window, past the hard mark (${HARD}). The harness force-compacts on its own before this session's context can grow indefinitely; do not wait for it, and the focused-work exception does NOT apply this close to the ceiling (CLAUDE.md trigger 3). You must call the AskUserQuestion tool now, before writing anything else: one single-select question, header \"Context\", multiSelect false, exactly these three options (translate the visible text into the conversation language, keep the meaning): \"New-chat handoff prompt\" (you generate a self-contained handoff prompt), \"Clear context, stay here\" (you tell the user to run /clear), \"Continue as-is\" (proceed unchanged). Precede the tool call with one line naming what you observed (size and %). Only if the AskUserQuestion tool is genuinely not available to you this turn, not merely inconvenient, state IN CAPS that auto-compaction is imminent and list those three options in text so the user can still choose."
emit_block "$REASON"
save_track "$SIZE" "hard" "$MSG_TS" false "$HARD_ACK_AT"
exit 2
