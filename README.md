<p align="center">
  <img src="assets/logo.svg" alt="HighWater" width="460">
</p>

Context-boundary hygiene for Claude Code. A hook that watches your context size and forces a task-boundary checkpoint, new chat, clear, or continue, before the window quietly burns your budget or hits auto-compaction.

## What's in here

- **`hooks/context-check.sh`**: a `Stop` hook that reads real context size from the transcript and, past a threshold, blocks the response until Claude raises the checkpoint
- **`CLAUDE.md.example`**: the rule that wires the checkpoint behavior (what it offers, how it phrases the question) into Claude's own behavior
- **`/refresh-context-rules`**: on-demand command, see [COMMANDS.md](COMMANDS.md)

Looking for cost-aware model routing (which subagent tier handles a task) instead of context hygiene? That's a separate tool, [Bullpen](https://github.com/reganomika/Bullpen), safe to install alongside this one.

## Install

```
/plugin marketplace add reganomika/HighWater
/plugin install highwater@highwater
```

Full instructions, including the no-plugin-system path, what happens to chats you already have open, and how to disable or remove it: [INSTALL.md](INSTALL.md).

## Docs

- [COMMANDS.md](COMMANDS.md): the one slash command, with a real output example
- [INSTALL.md](INSTALL.md): both install paths, restart caveats, uninstall
- [FAQ.md](FAQ.md): common questions and corner cases

## License

MIT, see `LICENSE`.
