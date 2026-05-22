# adversary

A Claude Code plugin that runs an adversarial 3-stage critique of an artifact in three isolated Claude subprocesses, with structured findings returned to your chat.

You invoke `/adversary:review <path-to-artifact>` against a plan, PR review draft, exploration answer, or recommendation document. The slash command's bash spawns three fresh `claude --print` subprocesses chained via stdout capture:

1. **Explore** — reconnaissance. Discovers project shape from the filesystem and extracts every verifiable claim from the artifact (typed, suspicion-ordered, with suggested verification approaches). LISTS claims; does NOT verify them.
2. **Verify** — checks every claim against ground truth. Has Bash for `git`, `docker`, `curl`, `lsof`, and database clients. Augments the ledger with any verifiable claims explore missed. Confidence-labels every VERIFIED claim.
3. **Review** — meta-critique. Examines reasoning, completeness, coverage; surfaces Critical / Important / Minor findings with section references and timestamps.

Each subprocess sees only its predecessor's stdout, not the parent session's context. Fresh-context per stage = real adversarial review with no parent-context bleed.

## Pipeline diagram

```
/adversary:review <path>
  ├─ explore subprocess: --tools "Read,Grep,Glob"     → stdout (claim ledger + briefing)
  │     ↓ piped as EXPLORE_OUTPUT
  ├─ verify subprocess:  --tools "Read,Grep,Glob,Bash,WebFetch" + Bash(git *), Bash(docker *), Bash(curl *), Bash(lsof *), Bash(psql *), Bash(mysql *), Bash(sqlite3 *), Bash(wc *), WebFetch
  │     ↓ stdout (verified ledger with status/confidence/evidence)
  │     ↓ piped as VERIFY_OUTPUT
  └─ review subprocess:  --tools "Read,Grep,Glob"     → stdout (Critical/Important/Minor findings)
                                                          ↓
                                                       chat
```

## Install

```
/plugin marketplace add lkrhl/adversary
/plugin install adversary
```

(Or for local development: `claude --plugin-dir /path/to/repo/plugins/adversary` per session.)

## Permissions

The only Claude Code permission this plugin needs is declared **inside the slash command's frontmatter** (`allowed-tools: ["Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/pipeline.sh *)"]`) — not your `settings.local.json`. There is nothing to add to your user-level or project-level permission allowlist. The `claude --print` subprocesses spawned by `pipeline.sh` run outside the Claude Code harness's permission scope; their tool restrictions (`--tools`, `--allowedTools`) are passed as CLI flags inside the pipeline script.

### First-time invocation

The first use of `/adversary:review` in a project shows a one-time permission-grant prompt for the slash command's bash invocation. The slash command's bash dispatches *before* you answer, so all three options actually run the pipeline — the difference is whether it runs once or twice:

- **Option 3 ("No")** — only the pre-grant fire runs. The harness surfaces the review output as a "Background command completed" message. No persistent grant, so the next invocation prompts again. **Pick this for one-off runs.**
- **Option 1 or 2 ("Yes" / "Yes, don't ask again")** — fires the pipeline a *second* time in parallel (≈2× token cost on this invocation only) but persists the grant for future runs in this project. Pick this if you plan to iterate.

## Configuring the plugin

**Quick start:** run `/adversary:init` from your project's working directory. It scaffolds `<cwd>/.adversary/config.json` with every documented key set to its default value, ready for you to edit. Refuses if the file already exists.

Or drop the config file by hand at `<cwd>/.adversary/config.json` to extend verify-stage tools, enable cost reporting, or enable debug mode. All keys are optional:

```json
{
  "tools": {
    "verify": {
      "extra_allowed_tools": [
        "Bash(gh *)",
        "WebSearch"
      ]
    }
  },
  "costReporting": false,
  "debug": false
}
```

| Key | Type | Default | Effect | Env var override |
|---|---|---|---|---|
| `tools.verify.extra_allowed_tools` | string[] | `[]` | Extra entries appended to verify-stage `--allowedTools` after filtering through a read-only-ish denylist (see below). Built-in tools (`WebSearch`, `WebFetch`, `TodoWrite`, `Task`) are also added to `--tools`. | — |
| `costReporting` | bool | `false` | When true: per-stage `tokens in=… out=… cache_create=… cache_read=… cost=$…` lines to stderr, plus a pipeline-total line on stdout below the review. | `ADVERSARY_COST_REPORTING=1\|true\|on\|yes` enables; `=0\|false\|off\|no` disables. |
| `debug` | bool | `false` | When true: writes a timing log to `/tmp/adversary-timing.log` and keeps per-pipeline state files at `/tmp/adversary-*-${PIPELINE_ID}.*` for inspection. | `ADVERSARY_DEBUG=1` enables. |

Env vars are checked after the config file, so they win on conflict. Missing config = defaults. Malformed JSON = one warning to stderr, then defaults.

### Read-only-ish denylist (for `tools.verify.extra_allowed_tools`)

verify is read-only by design — it produces a verification report, not changes. The following patterns are dropped from `extra_allowed_tools` with a stderr warning if you include them:

| Category | Blocked patterns |
|---|---|
| File mutation | `Edit`, `Write`, `MultiEdit`, `NotebookEdit` |
| Bash FS mutation | `Bash(rm *)`, `Bash(mv *)`, `Bash(cp *)`, `Bash(chmod *)`, `Bash(chown *)` |
| Privilege escalation | `Bash(sudo *)` |
| Remote mutation | `Bash(ssh *)`, `Bash(scp *)`, `Bash(rsync *)` |
| Dependency install | `Bash(npm install *)`, `Bash(npm i *)`, `Bash(yarn add *)`, `Bash(pip install *)`, `Bash(composer install *)`, `Bash(composer require *)`, `Bash(apt *)`, `Bash(brew install *)` |
| Git mutation | `Bash(git push *)`, `Bash(git commit *)`, `Bash(git rebase *)`, `Bash(git reset *)`, `Bash(git checkout *)` |

### Broad-vs-narrow Bash patterns

The denylist only blocks **narrow** patterns. A broad pattern like `Bash(npm *)` bypasses the install-specific deny because the matcher doesn't expand wildcards. If you grant `Bash(npm *)`, npm install is reachable from verify. Two pragmatic responses:

- **Use narrow patterns for safety**: `Bash(npm view *)`, `Bash(npm ls *)`, `Bash(npm outdated *)` keep the deny granular.
- **Use broad patterns deliberately**: the baseline already does this for `Bash(git *)` and `Bash(docker *)` because narrow alternatives are unwieldy. The trade-off is your choice per-project.

There is no whitelist enforcement on broad patterns — the trade-off is documented, not enforced. If you need stricter isolation, run verify under a sandbox or fork the plugin and constrain the baseline directly.

### Sharing config across a team

`.adversary/config.json` can be checked into the repo if the whole team wants the same verify-stage capabilities and reporting defaults (often the case — you want consistent review surface across reviewers). Gitignore it if it's per-developer.

## Stuck detection

A PreToolUse hook (`hooks/stuck-detector.sh`) fires on every tool call inside the subprocess and enforces two rules:

1. Same `(tool, args)` repeated 3× → block (the subprocess emits a STUCK block in its output).
2. \> 60 tool calls in one subprocess run → block.

The hook is gated on `ADVERSARY_SUBPROCESS=1` (set by the slash command's bash around each subprocess invocation), so it is inert in your normal interactive Claude sessions even though the plugin is installed. State is per-subprocess at `/tmp/adversary-stuck-<RUN_ID>.json`, written by the hook as a shell process — no Claude Code tool permission grants involved.

## Dependencies

- `claude` CLI (the same binary that runs your interactive sessions — used as a subprocess).
- `jq`, `bash`, `awk`, `openssl` — used by the stuck-detector hook.

## License

MIT — see [LICENSE](LICENSE).
