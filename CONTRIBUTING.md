# Contributing

## Filing an issue

- GitHub issues at the project repo. `lkrhl/adversary` is the canonical distribution.
- For unexpected pipeline behavior, include the failing subprocess's stdout (the partial output / findings list / STUCK block).
- For STUCK reports, include the STUCK banner plus the partial output above it. The stuck-detector state file at `/tmp/adversary-stuck-<RUN_ID>.json` may also be useful — it records every tool call the subprocess made before getting stuck.

## Dev install

**Per-session via `--plugin-dir`** (recommended for iteration):

```
claude --plugin-dir /path/to/your/clone
```

The plugin loads only for that session. Edit files in your clone, restart `claude`, changes pick up. No install/uninstall cycle, no marketplace setup. Recommended for iterating on the plugin itself; for using the plugin as a tool, the marketplace install in README is better.

Permission changes inside the plugin require a full new Claude session — `/reload-plugins` is insufficient.

## Running the tests

There are no test harnesses yet. Tests against the subprocess pipeline are on the roadmap.

In the meantime, manual sanity checks before opening a PR:

1. `claude --plugin-dir <repo>` then `/adversary:review <path-to-real-artifact>` — verify the pipeline runs end-to-end without permission prompts and emits structured findings.
2. Inspect `/tmp/adversary-stuck-<RUN_ID>.json` after a run to verify the stuck-detector hook fired (you should see 1+ recorded calls per subprocess; three files per pipeline run, one per stage).
3. Run the same against an artifact you know to be wrong — verify the review subprocess surfaces Critical findings rather than rubber-stamping.

## PR conventions

- One concern per PR (don't bundle a bug fix with a refactor).
- Update `CHANGELOG.md`: add a new versioned entry at the top, or extend the most recent unreleased one, with a bullet describing the user-visible change. The project does not maintain a long-running `## [Unreleased]` section — entries are versioned as they land.
- Keep `README.md` accurate when behavior changes — especially the pipeline diagram and the permissions paragraph.

## Architecture notes

- **Three subprocesses, not one subagent.** Each stage (explore → verify → review) runs as a separate `claude --print` subprocess invoked by the slash command's bash. Outputs flow as stdout → next subprocess's prompt input. The Claude Code subagent permission scope is bypassed entirely; subprocess permissions are controlled via `--tools` and `--allowedTools` CLI flags on each invocation.
- **Protocols are system prompts, not dispatchable agents.** `protocols/{explore,verify,review}.md` are concatenated into the corresponding subprocess's `--append-system-prompt`. They retain agent-style YAML frontmatter for human readability but are NOT registered as dispatchable agent types.
- **`${CLAUDE_PLUGIN_ROOT}` substitution** is performed by Claude Code in `SKILL.md`, slash command bodies, and `hooks.json`. Used in `commands/review.md` to point at the protocol files. NOT substituted in arbitrary text contexts.
- **Permission surface is one entry**, declared in `commands/review.md` frontmatter as `allowed-tools: ["Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/pipeline.sh *)"]`. Nothing belongs in user `settings.local.json`. The `claude --print` subprocesses spawned by `pipeline.sh` run outside the harness's permission scope; their tool restrictions are passed via subprocess `--tools` / `--allowedTools` CLI flags and do not require user allowlist entries.
- **Stuck-detector state writes are shell-process writes**, not Claude tool calls. They write to `/tmp/adversary-stuck-<RUN_ID>.json` without going through the harness's permission gate.
