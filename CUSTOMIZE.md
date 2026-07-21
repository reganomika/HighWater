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
| `CONTEXT_CHECK_HARD_PCT` | `88` | Hard mark, percent of the window. Forces an `AskUserQuestion` checkpoint before the harness force-compacts near ~99%. Must be greater than `CONTEXT_CHECK_WARN_PCT`. |
| `CONTEXT_CHECK_STEP_PCT` | `15` | Re-nag cooldown after a fire, percent of the window. Applies to both tiers (warn's own cadence, and the hard tier's post-ack cooldown). |
| `CONTEXT_CHECK_DISABLE_WARN` | unset | Set to `1` to silence the warn tier entirely. The hard tier still fires. |
| `CONTEXT_CHECK_DISABLE_HARD` | unset | Set to `1` to silence the hard tier entirely. **This removes the tool's actual safety net**, no forced stop before auto-compaction, leaving only the warn nudge if that's still enabled. Only set this if you genuinely want a soft reminder and nothing more. |

Percentages must satisfy `1 <= warn < hard <= 100`; window and percentages must be plain integers. Anything malformed (a typo, `warn >= hard`, non-numeric) is ignored and the hook falls back to the shipped default for that value, the same fail-open policy as a missing `jq`: a bad config degrades the checkpoint, it never wedges your session.

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

`bats tests/` covers the state machine (`tests/context-check.bats`), config precedence and fail-open behavior (`tests/customization.bats`), and whether the docs' quoted percentages still match the script (`tests/docs-consistency.bats`). If you change `CONTEXT_CHECK_WARN_PCT`/`HARD_PCT`/`STEP_PCT`'s *shipped defaults* in the script (not your own local config), run the suite, `docs-consistency.bats` will tell you exactly which doc file still quotes the old numbers.
