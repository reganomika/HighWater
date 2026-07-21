# FAQ

### I installed the plugin but my existing chat isn't using it. Is it broken?

No. Claude Code loads hook registrations once, when a session starts, and never reloads them mid-session. A chat that was already open when you installed HighWater keeps running without the hook, forever, until you close it. Restart that chat, a brand-new session started after install gets it automatically, no extra step needed.

### I appended CLAUDE.md.example but nothing changed.

`CLAUDE.md.example` never installs itself, not via the plugin, not on restart, not automatically under any circumstance. The plugin system deliberately doesn't load CLAUDE.md files. Copy its contents into your own `~/.claude/CLAUDE.md` by hand, every time you want to pick up a change to it.

### The checkpoint keeps interrupting me. How do I make it stop?

Three options depending on what you actually want. Turn it off entirely: `touch ~/.claude/hooks/context-check.disabled`, instant, no restart. Push the thresholds higher: `export CONTEXT_CHECK_WINDOW=<bigger number>` widens the whole window the 55%/88% marks are computed from. Or just answer the checkpoint: at the soft mark you can decline in one line if this is genuinely focused work that needs the accumulated history, and it won't nag again until context grows another 15% of the window.

### Why does it fire again right after I answered the hard-tier checkpoint?

It shouldn't, if the answer was a real `AskUserQuestion` call. The hook checks the transcript for one after its own fire and goes quiet once it finds it, then stays quiet until context grows another 15% of the window. If it keeps firing, the checkpoint wasn't actually raised as a tool call, a text-only answer doesn't count at the hard tier, on purpose, see [README.md](README.md) on why prose-only compliance isn't trusted here.

### Can the 55%/88% thresholds be changed?

The window they're computed from, yes: `CONTEXT_CHECK_WINDOW` (default 1,000,000). The percentages themselves are in the script, `hooks/context-check.sh`, as the `WARN`/`HARD` calculations near the top. Edit them directly if 55/88 doesn't fit your usage.

### Does any of this send my data anywhere?

No. The hook is a local shell script that reads your own session transcript file on disk and writes a small state file under `~/.claude/hooks/state/`. Nothing here makes a network call. Read the script yourself before trusting that claim, it's short.

### Can I run this alongside Bullpen?

Yes. They're independent hooks on independent events (`context-check.sh` on `Stop`, `route-gate.sh` on `PreToolUse` in Bullpen) with separate state files, and this repo's on-demand command is deliberately named `/refresh-context-rules`, not `/refresh-rules`, so it doesn't collide with Bullpen's own command if you install both by hand instead of via the plugin system.

### Does this stop the harness from auto-compacting my context?

No, and it isn't trying to. Claude Code force-compacts on its own near ~99% of the window regardless of this hook. `context-check.sh` fires earlier, at 55% and 88%, so you get an actual choice (handoff, clear, continue) before that happens automatically without asking you.

### Can I use this with claude.ai or the API instead of Claude Code?

No. Hooks are a Claude Code–specific concept (the CLI and desktop app). None of it applies to claude.ai or direct API usage.
