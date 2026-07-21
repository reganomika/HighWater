# FAQ

### I installed the plugin but my existing chat isn't using it. Is it broken?

No. Claude Code loads hook registrations once, when a session starts, and never reloads them mid-session. A chat that was already open when you installed HighWater keeps running without the hook, forever, until you close it. Restart that chat, a brand-new session started after install gets it automatically, no extra step needed.

### I appended CLAUDE.md.example but nothing changed.

`CLAUDE.md.example` never installs itself, not via the plugin, not on restart, not automatically under any circumstance. The plugin system deliberately doesn't load CLAUDE.md files. Copy its contents into your own `~/.claude/CLAUDE.md` by hand, every time you want to pick up a change to it.

### The checkpoint keeps interrupting me. How do I make it stop?

A few options depending on what you actually want. Turn it off entirely: `touch ~/.claude/hooks/context-check.disabled`, instant, no restart. Turn off just the hard tier and keep the soft nudge (or vice versa): `CONTEXT_CHECK_DISABLE_HARD=1` / `CONTEXT_CHECK_DISABLE_WARN=1`, see [CUSTOMIZE.md](CUSTOMIZE.md). Push the thresholds higher instead of off: `CONTEXT_CHECK_WARN_PCT`/`HARD_PCT`, or widen the whole window with `CONTEXT_CHECK_WINDOW`. Or just answer the checkpoint: at the soft mark you can decline in one line if this is genuinely focused work that needs the accumulated history, and it won't nag again until context grows another 15% of the window.

### Why does it fire again right after I answered the hard-tier checkpoint?

It shouldn't, if the answer was a real `AskUserQuestion` call. The hook checks the transcript for one after its own fire and goes quiet once it finds it, then stays quiet until context grows another 15% of the window. If it keeps firing, the checkpoint wasn't actually raised as a tool call, a text-only answer doesn't count at the hard tier, on purpose, see [README.md](README.md) on why prose-only compliance isn't trusted here.

### My account has a 1M context window. Do I need to configure anything?

Depends on the model. Sonnet 5 and Fable 5 always run with a 1M window, on any plan, no opt-in needed, so the hook detects this from the model name in the transcript and defaults to 1,000,000 automatically. Nothing to set.

Opus and everything else varies by plan and usage credits (Claude Code's own docs: Opus gets 1M included on Max/Team/Enterprise, but needs usage credits on Pro), which isn't something the transcript reveals, so those still default to 200,000. If you're running Opus with 1M enabled, set `export CONTEXT_CHECK_WINDOW=1000000` yourself (shell profile, or the `env` block of `~/.claude/settings.json`). Skip this when you need it and the thresholds stay at 110k/176k, a fifth of the real ceiling, so the hook does the opposite of going quiet: it starts hard-firing once you're a normal fraction of the way into a long session and keeps re-firing on every Stop for however much further context you accumulate, since real auto-compaction is still hundreds of thousands of tokens away. Self-calibration (see below) corrects this on its own after the first real compaction, but a manual override fixes it immediately instead of waiting for that.

### Can the 55%/88% thresholds be changed?

Yes, without touching the script: `CONTEXT_CHECK_WARN_PCT` and `CONTEXT_CHECK_HARD_PCT`, either as env vars or in `~/.claude/hooks/context-check.conf`. The window they're computed from is `CONTEXT_CHECK_WINDOW` (default 200,000), and the re-nag cooldown is `CONTEXT_CHECK_STEP_PCT`. Either tier can also be turned off entirely with its own variable. Full list, examples, and how to confirm what's actually active: [CUSTOMIZE.md](CUSTOMIZE.md).

### Does any of this send my data anywhere?

No. The hook is a local shell script that reads your own session transcript file on disk, your own `~/.claude/hooks/context-check.conf` if you created one, and writes a small state file under `~/.claude/hooks/state/`. Nothing here makes a network call. Read the script yourself before trusting that claim, it's short.

### Can I run this alongside Bullpen?

Yes. They're independent hooks on independent events (`context-check.sh` on `Stop`, `route-gate.sh` on `PreToolUse` in Bullpen) with separate state files, and this repo's on-demand command is deliberately named `/refresh-context-rules`, not `/refresh-rules`, so it doesn't collide with Bullpen's own command if you install both by hand instead of via the plugin system.

### Does this stop the harness from auto-compacting my context?

No, and it isn't trying to. Claude Code force-compacts on its own regardless of this hook, empirically near ~99% of the window in most observed sessions but sometimes earlier. `context-check.sh` fires earlier, at 55% and 88% by default, so you get an actual choice (handoff, clear, continue) before that happens automatically without asking you.

### How accurate is the 88% hard mark, really?

It's an assumption that gets corrected by evidence. Real auto-compaction doesn't land at a fixed percentage (66 real compactions sampled across one account's history: median ~99.98% of window, but as early as ~93% in some sessions, only 4 of 66 below 88%), and the hook doesn't pretend otherwise: Claude Code writes a `compact_boundary` event to the transcript with the exact token count every time it actually compacts. The first time the hook sees one, it remembers that number (`~/.claude/hooks/context-check.observed.json`, account-wide, not per-session, read from disk every run so it survives past that event scrolling out of the transcript tail the hook scans) and uses `observed − 20000` as the hard mark whenever that's earlier than the configured percentage would fire, a fixed token margin rather than a percentage of the observed point, since the room actually needed to generate a checkpoint doesn't scale with window size. It only ever pulls the mark earlier, never later, and never below the soft mark. See [CUSTOMIZE.md](CUSTOMIZE.md#hard-mark-self-calibration).

### Is the measured context size always exactly right?

Close, not exact. Claude Code's own hooks reference notes that the transcript file is written asynchronously and isn't guaranteed to include the very latest message by the time a `Stop` hook fires. `context-check.sh` reads the transcript rather than the hook's `last_assistant_message` field because it needs the cumulative usage total, not just the latest message's text, and that total isn't available anywhere else. In practice this means the measured size can lag true size by up to one turn. Since the hook fires on every `Stop`, that lag self-corrects on the very next one, it isn't cause for concern, just don't expect the printed number to be accurate to the token on the turn where a threshold is first crossed.

### Can I use this with claude.ai or the API instead of Claude Code?

No. Hooks are a Claude Code–specific concept (the CLI and desktop app). None of it applies to claude.ai or direct API usage.
