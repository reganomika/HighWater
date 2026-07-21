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
1. The script's own defaults, `hooks/context-check.sh`, the `WARN_PCT`/`HARD_PCT`/`STEP_PCT` fallback values (55/88/15).
2. If `CONTEXT_CHECK_WINDOW` is set nowhere (neither config file nor env, see below), the window is auto-detected from the session's model in the transcript: `1000000` for `claude-sonnet-5` or `claude-fable-5` (they always run at 1M, on any plan), `200000` for anything else (Opus and others vary by plan, not detectable from the transcript).
3. `~/.claude/hooks/context-check.conf`, if it exists, overrides the script/auto-detected defaults.
4. The `env` block of `~/.claude/settings.json`, if it sets any `CONTEXT_CHECK_*` key there, overrides the config file.
5. `~/.claude/hooks/context-check.observed.json`, if it exists, can pull the hard mark earlier still: read its `observed_pre_tokens` and report `observed_pre_tokens - 20000` as the effective hard mark whenever that's lower than what steps 1-4 computed. Say so explicitly when this is the binding number, it's easy to mistake for the configured percentage otherwise.

Note explicitly if `CONTEXT_CHECK_DISABLE_WARN` or `CONTEXT_CHECK_DISABLE_HARD` is set anywhere in that chain, since a disabled tier makes its own threshold moot. You cannot see an env var exported only in a shell profile (not in settings.json), since that's invisible to a file read; say so if you can't fully verify the chain instead of reporting a number you didn't actually confirm.

The user looks at what you produced and sees for themselves whether it matches what they expect right now, instead of trusting your claim.
