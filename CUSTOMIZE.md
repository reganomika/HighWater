# Customize

Everything numeric in `context-check.sh` is configurable, without editing the script.

## Where settings live

Copy [`context-check.conf.example`](context-check.conf.example) to `~/.claude/hooks/context-check.conf` and uncomment what you want to change:

```bash
mkdir -p ~/.claude/hooks
cp context-check.conf.example ~/.claude/hooks/context-check.conf
```

The script sources this file on every run if it exists. No file, no change: an absent or empty config behaves exactly like the shipped defaults (200K window, 55%/88%/15%, both tiers on).

A real exported env var (your shell profile, or the `env` block in `~/.claude/settings.json`) always wins over the file, so a one-off `CONTEXT_CHECK_WINDOW=1000000 claude` or a CI override never gets clobbered by whatever the file says.

## Variables

| Variable | Default | Effect |
|---|---|---|
| `CONTEXT_CHECK_WINDOW` | `200000` | Context window in tokens, the base every percentage below is computed from. `1000000` for the 1M-context account tier. |
| `CONTEXT_CHECK_WARN_PCT` | `55` | Soft mark, percent of the window. Advisory nudge, enforced as text only. |
| `CONTEXT_CHECK_HARD_PCT` | `88` | Hard mark, percent of the window. Forces an `AskUserQuestion` checkpoint before the harness force-compacts. Real auto-compaction has landed anywhere from ~93% to ~101% of the window across observed sessions, not a fixed point, which is why this self-calibrates, see below. Must be greater than `CONTEXT_CHECK_WARN_PCT`. |
| `CONTEXT_CHECK_STEP_PCT` | `15` | Re-nag cooldown after a fire, percent of the window. Applies to both tiers (warn's own cadence, and the hard tier's post-ack cooldown). |
| `CONTEXT_CHECK_DISABLE_WARN` | unset | Set to `1` to silence the warn tier entirely. The hard tier still fires. |
| `CONTEXT_CHECK_DISABLE_HARD` | unset | Set to `1` to silence the hard tier entirely. **This removes the tool's actual safety net**, no forced stop before auto-compaction, leaving only the warn nudge if that's still enabled. Only set this if you genuinely want a soft reminder and nothing more. |

Percentages must satisfy `1 <= warn < hard <= 100`; window and percentages must be plain integers. Anything malformed (a typo, `warn >= hard`, non-numeric) is ignored and the hook falls back to the shipped default for that value, the same fail-open policy as a missing `jq`: a bad config degrades the checkpoint, it never wedges your session.

## Hard-mark self-calibration

`CONTEXT_CHECK_HARD_PCT` is an assumption, not a guarantee: real auto-compaction doesn't fire at a fixed percentage of the window, it varies by session. So the hook doesn't only trust the percentage. Claude Code writes a `compact_boundary` event to the transcript every time it actually compacts, with the exact token count that triggered it. The hook watches for this event; the first time it sees one, it saves that number to `~/.claude/hooks/context-check.observed.json` and, from then on, uses `observed − 20000` as the hard mark whenever that's *lower* than the configured percentage would produce.

The margin is a fixed token count, not a percentage of the observed point: what it protects is room to actually generate an `AskUserQuestion` checkpoint and a handoff prompt before the real ceiling, and that cost doesn't scale with window size. A percentage margin would over-protect on a 1M window (10% of ~1M is a ~100K buffer nobody needs) for no better safety than a flat one.

This only ever pulls the mark earlier, never later: a high or missing observation changes nothing, and calibration can never push the hard mark below the soft one. Delete `~/.claude/hooks/context-check.observed.json` to reset it; the hook re-learns from the next real compaction. This file is account-wide, not per-session, since a real compaction point is evidence about your account, not about one conversation, and it's read from disk on every run so an old observation survives even after the event that produced it scrolls out of the transcript tail the hook scans.

## Examples

Wider warn band, narrower hard approach, on a 1M account:

```bash
CONTEXT_CHECK_WINDOW=1000000
CONTEXT_CHECK_WARN_PCT=40
CONTEXT_CHECK_HARD_PCT=92
```

Only the hard stop, no soft nudge:

```bash
CONTEXT_CHECK_DISABLE_WARN=1
```

## Checking what's actually active

`/refresh-context-rules` reports the live thresholds as currently computed (window, and the soft/hard marks as both percentages and raw token counts), reading your config file if you have one. Run it any time you want a checkable answer instead of trusting your own memory of what you set.

Two things it can't see: an env var set outside `~/.claude/settings.json` (a shell-only export isn't visible to a file read), and whatever a *different* shell used to launch Claude Code actually had exported at hook-run time. If the reported numbers don't match what you expected, check `~/.claude/settings.json`'s `env` block and your shell profile for a stale or conflicting value.

## Testing a change

`bats tests/` covers the state machine (`tests/context-check.bats`), config precedence and fail-open behavior (`tests/customization.bats`), hard-mark self-calibration (`tests/calibration.bats`), and whether the docs' quoted percentages still match the script (`tests/docs-consistency.bats`). If you change `CONTEXT_CHECK_WARN_PCT`/`HARD_PCT`/`STEP_PCT`'s *shipped defaults* in the script (not your own local config), run the suite, `docs-consistency.bats` will tell you exactly which doc file still quotes the old numbers.
