---
description: Re-read the current ~/.claude/CLAUDE.md and this project's own CLAUDE.md (if any) right in this chat, no new chat needed. Use when the task-boundary rule changed after this session started, and the chat is still running on the old version.
disable-model-invocation: true
---

Read right now, in full:
1. `~/.claude/CLAUDE.md`
2. `CLAUDE.md` at the root of the current project, if it exists

Whatever they currently say applies for the rest of this session in place of what was in the system prompt at session start: the same rules, just re-read fresh, since these files can change after a session has already loaded and the system prompt doesn't hot-reload.

Apply this from now until the end of the session.

Don't try to judge whether anything changed compared to how you'd been behaving before: that's unreliable self-assessment, you have no accurate record of your own old system prompt to honestly compare against, and on a large accumulated context that guess easily comes out confident and wrong. Instead, always, regardless of any belief about what changed, produce a concrete checkable artifact right now, not a claim: the current, ACTUALLY ACTIVE `context-check.sh` thresholds in one line, window plus soft and hard marks as both percentage and raw token count (e.g. `window=200000, warn=55% (110000), hard=88% (176000)`).

Compute these from every layer that can override the shipped defaults (55/88/15, window 200000), in the order the script itself applies them:
1. The script's own defaults, `hooks/context-check.sh`, the `CONTEXT_CHECK_WINDOW`/`WARN_PCT`/`HARD_PCT`/`STEP_PCT` fallback values.
2. `~/.claude/hooks/context-check.conf`, if it exists, overrides the script defaults.
3. The `env` block of `~/.claude/settings.json`, if it sets any `CONTEXT_CHECK_*` key there, overrides the config file.

Note explicitly if `CONTEXT_CHECK_DISABLE_WARN` or `CONTEXT_CHECK_DISABLE_HARD` is set anywhere in that chain, since a disabled tier makes its own threshold moot. You cannot see an env var exported only in a shell profile (not in settings.json), since that's invisible to a file read; say so if you can't fully verify the chain instead of reporting a number you didn't actually confirm.

The user looks at what you produced and sees for themselves whether it matches what they expect right now, instead of trusting your claim.
