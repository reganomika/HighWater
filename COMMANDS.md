# Commands

One slash command, available once installed. Nothing here fires automatically beyond the `context-check.sh` hook itself, which does its own thing on `Stop` without any command needed.

## `/refresh-context-rules`

```
/refresh-context-rules
```

Run this in a chat that's been open since before you last edited CLAUDE.md, so it picks up the current task-boundary rule without a restart. It re-reads `~/.claude/CLAUDE.md` and this project's own CLAUDE.md (if any), and returns one checkable artifact: the actual active thresholds (window, soft and hard marks, both as a percentage and in tokens), resolved through the script's defaults, your `context-check.conf` if any, and `~/.claude/settings.json`, so you can confirm your customization took effect instead of trusting a claim. See [CUSTOMIZE.md](CUSTOMIZE.md) for what's configurable.

Named differently from Bullpen's own `/refresh-rules` on purpose: if you install both, their skill directories would otherwise collide under the manual (non-plugin) install path.

This only refreshes text-based rules in files that were already installed when the chat started. It cannot add the hook itself to an already-running session, that needs a restart, see [FAQ.md](FAQ.md).
