# Install

**Any chat window already open before you install will not get the new hook, full stop: not after `/reload-plugins`, not ever, until you close it and start a new one.** Claude Code loads hook registrations once when a session starts; there's no live reload for that. New chats opened after install work immediately. See [FAQ.md](FAQ.md) for more on this.

**On a 1M-context account, set one variable before you rely on this.** The hook defaults to a 200K window, the standard tier, because the transcript carries no field saying which tier you're actually on. If your account runs the 1M-context tier and you skip this, the thresholds compute against the wrong ceiling and the hook stays quiet for most of a real session:

```bash
export CONTEXT_CHECK_WINDOW=1000000
```

Put it in your shell profile, or in the `env` block of `~/.claude/settings.json` so it applies regardless of shell.

## As a plugin (recommended)

```
/plugin marketplace add reganomika/HighWater
/plugin install highwater@highwater
```

A local clone path works the same way in place of `reganomika/HighWater`. Registers the skill and the hook in one step. Restart Claude Code (or `/reload-plugins`) once after install; skill edits apply live from then on.

`CLAUDE.md.example` never auto-installs: the plugin system doesn't load CLAUDE.md files. Append it to your own `~/.claude/CLAUDE.md` by hand.

## Copy into your own config (no plugin system)

```bash
git clone <this-repo-url>
cp -r <repo>/skills/refresh-context-rules ~/.claude/skills/
mkdir -p ~/.claude/hooks
cp <repo>/hooks/context-check.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/context-check.sh
```

Add to `~/.claude/settings.json` (merge into your existing file):

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/context-check.sh" }] }]
  }
}
```

If you already have another `Stop` hook registered (from Bullpen or elsewhere), add this as a second entry in the same `hooks` array rather than a second `Stop` block, both hooks fire independently either way.

Start a new session to pick up the skill and the hook, chats already open when you do this stay on old behavior until restarted, no exceptions. Append `CLAUDE.md.example` to your own CLAUDE.md if you want it.

## Disable temporarily

`touch ~/.claude/hooks/context-check.disabled`, checked fresh on every run, no restart needed. Back on: `rm ~/.claude/hooks/context-check.disabled`.

## Uninstall

**Plugin install:**

```
/plugin uninstall highwater@highwater
```

Removes the skill and the hook registration. If you also want the marketplace source gone: `/plugin marketplace remove reganomika/HighWater`.

**Copy-into-config install:** nothing tracks what the manual method copied, so remove it by hand:

```bash
rm -rf ~/.claude/skills/refresh-context-rules
rm ~/.claude/hooks/context-check.sh
```

Then remove the `context-check.sh` entry from the `Stop` array in `~/.claude/settings.json` yourself, and delete the "Task boundaries and new chats" section from your `~/.claude/CLAUDE.md` if you appended `CLAUDE.md.example`. Either way, this only takes effect for chats started after you do it, same restart rule as install.

## Try without installing

```bash
claude --plugin-dir <path-to-this-repo>
```
