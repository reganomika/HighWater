# Changelog

Notable changes to this project. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/).

## [0.3.0] - 2026-07-22

Found by installing the plugin and actually using it: the hard mark fired on the very first message of a new session (453552 tokens, 226% of the assumed 200K window) on an account running Sonnet 5, which the previous default had no way to know always runs at 1M.

### Added

- Model-based window auto-detection. When `CONTEXT_CHECK_WINDOW` isn't set anywhere (config file or env), the hook now reads the model from the transcript it already parses and picks the window itself: `1000000` for `claude-sonnet-5` and `claude-fable-5` (per Claude Code's own docs, these always run at 1M, on any plan, no opt-in), `200000` for everything else, since Opus and older models vary by plan in ways the transcript can't reveal. An explicit `CONTEXT_CHECK_WINDOW`, from either source, always wins over auto-detection.
- 4 new tests covering auto-detection for both 1M models, the 200K fallback for an unrecognized model, and that an explicit override still beats the model-based default.

## [0.2.0] - 2026-07-22

### Added

- Hard-mark self-calibration. The hook watches for `compact_boundary` events (Claude Code's own record of exactly where a real auto-compaction fired) and, the first time it sees one, remembers that token count in `~/.claude/hooks/context-check.observed.json`. From then on, the hard mark becomes `observed − 20000` whenever that's earlier than the configured percentage would fire, a fixed token margin since the room needed to generate a checkpoint doesn't scale with window size. Only ever lowers the mark, never raises it past the configured value, and never below the soft mark. See [CUSTOMIZE.md](CUSTOMIZE.md#hard-mark-self-calibration).
- `tests/calibration.bats`: 8 tests covering persistence, the margin boundary, the never-raises and never-below-warn guards, and fail-open on a malformed observation file.
- FAQ entries on how accurate the 88% assumption actually is (backed by 66 sampled real compactions: median ~99.98%, as early as ~93%, only 4/66 below 88%) and on transcript-read lag at `Stop` time.

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
