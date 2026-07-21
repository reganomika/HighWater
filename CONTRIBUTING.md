# Contributing

## Running the checks locally

```bash
brew install shellcheck bats-core   # or your platform's equivalent
shellcheck hooks/context-check.sh
bats tests/
```

Both run in CI on every push and PR ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)), the test suite on both Ubuntu and macOS since `context-check.sh` leans on plain POSIX tools that behave slightly differently between GNU and BSD coreutils. A PR that doesn't pass both won't merge.

## Changing `hooks/context-check.sh`

- If you change what `WARN_PCT`/`HARD_PCT`/`STEP_PCT` default to, run `bats tests/`, `tests/docs-consistency.bats` will name every doc file that still quotes the old percentage or token amount.
- If you change the state machine (tiers, cooldowns, floor-follow, hard-ack), add a case to `tests/context-check.bats` that would fail without your fix. A change with no failing-then-passing test attached is hard to trust months later.
- Keep the fail-open policy: a missing dependency, a malformed transcript, or a bad user config should degrade the checkpoint, never wedge a `Stop`. If you add a new failure path, it should `exit 0`, not error out.
- New behavior that changes what a user sees by default belongs in `CHANGELOG.md`, and probably in `CUSTOMIZE.md` if it's configurable.

## Style

Match the existing docs: direct statements, no marketing language, no emojis, no long dashes (—) in any language. Comments in the script explain *why*, not *what*, existing comments are the reference for the level of detail expected.

## Versioning

`plugin.json`'s `version` field is the update gate, Claude Code skips an update if the version string hasn't changed, regardless of new commits. Bump it (semver: patch for fixes, minor for new configurable behavior, major for a breaking default) and add a `CHANGELOG.md` entry for any change a user would notice. Tag the release with `claude plugin tag --push` after merging.

## Reporting a bug

Open an issue with: your Claude Code version, whether you're on the plugin install or the manual copy-in, the relevant lines from `~/.claude/hooks/context-check.disabled` / `context-check.conf` if either exists, and, if the hook fired unexpectedly or didn't fire, the stderr line it printed (see [`FAQ.md`](FAQ.md) first, several odd-looking behaviors are documented there as intentional).
