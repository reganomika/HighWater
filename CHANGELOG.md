# Changelog

Notable changes to this project. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [0.1.2] - 2026-07-21

Fixes from an independent review of the state machine and docs.

### Fixed

- FAQ's 1M-account answer was backwards: skipping `CONTEXT_CHECK_WINDOW=1000000` doesn't make the hook "go quiet", it makes it hard-fire early and keep re-firing, since the thresholds stay at a fifth of the real ceiling.
- `emit_block` printed a `{decision:"block", reason}` JSON payload to stdout that was never actually read, Claude Code only processes JSON on exit 0 and ignores stdout on exit 2. Removed; the stderr line was always the real channel.
- `CLAUDE.md.example` claimed the hook is "registered in `~/.claude/settings.json`" unconditionally; that's only true for the manual-install path, a plugin install registers it via `hooks/hooks.json`.
- `~/.claude/hooks/state/` accumulated one file per session forever. Now pruned past 30 days untouched, on every run, scoped to this hook's own filename suffix.

## [0.1.1] - 2026-07-21

### Added

- `displayName: "HighWater"` in `plugin.json`, so the `/plugin` picker shows proper casing instead of falling back to the lowercase `name`.

## [0.1.0] - 2026-07-21

First tagged release. `plugin.json` had no `version` field before this, so Claude Code resolved every commit as its own version and installs auto-updated silently on `/plugin update`. Everything below folds into this one version since nothing was ever tagged before it.

### Added

- `hooks/context-check.sh`: the `Stop` hook itself, split out of Bullpen.
- `/refresh-context-rules` skill and `CLAUDE.md.example`, the rule that wires the checkpoint behavior into Claude's own behavior.
- `tests/`: a bats suite covering the hook's state machine, config precedence and fail-open behavior, and doc/script consistency.
- `.github/workflows/ci.yml`: shellcheck and the bats suite on every push and PR.
- Full user configuration: `~/.claude/hooks/context-check.conf` and six `CONTEXT_CHECK_*` variables (window, warn/hard/step percentages, per-tier disable switches). See `CUSTOMIZE.md`.

### Changed

- Default `CONTEXT_CHECK_WINDOW` from 1,000,000 to 200,000 tokens. The old default matched only the 1M-context account tier; on a standard 200K account the hook silently never fired, since context could never reach 55% of a window five times too large. **If you installed HighWater before this release and run the 1M tier, set `CONTEXT_CHECK_WINDOW=1000000` explicitly** (see `INSTALL.md`), the hook can no longer assume it for you.

### Fixed

- A test assertion that matched jq's compact JSON output instead of its actual pretty-printed default. Passed locally, caught by CI on the first real run.
