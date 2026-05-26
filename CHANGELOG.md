# Changelog

All notable changes to the `adversary` plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.4.1] - 2026-05-26

### Added
- On API_ERROR abort, completed explore/verify outputs are dumped to stdout under `## Partial results` headers instead of being discarded.

### Removed
- Orphan `/tmp/claude-plugin-adversary/` entry in `.gitignore`.

## [2.4.0] - 2026-05-25

### Added
- Transient Anthropic API failures (529, overloaded, 5xx, rate limit) are now detected per stage and short-circuit the pipeline with a clear human-readable message naming the failing stage and the API reason. Exits 75 (`EX_TEMPFAIL`) so the parent session can distinguish API hiccups from real plugin failures. Previously these surfaced as a STUCK block that cascaded into downstream stages and produced confusing partial output.

## [2.3.0] - 2026-05-22

### Docs
- Instructional content cleaned up across the skill, protocols, and top-level docs.

## [2.2.0] - 2026-05-20

### Added
- `/adversary:init` scaffolds `<cwd>/.adversary/config.json` with every documented key at its default value.

## [2.1.0] - 2026-05-20

### Added
- Project-local config at `<cwd>/.adversary/config.json`.
- Opt-in per-stage and pipeline-total token / cost reporting via the `costReporting` config key or `ADVERSARY_COST_REPORTING` env var.
- Opt-in debug mode that retains per-pipeline state files and writes a timing log, via the `debug` config key or `ADVERSARY_DEBUG` env var.
- `WebFetch` granted to the verify subprocess by default.

### Fixed
- Stage prompts are piped via stdin instead of as a positional argument after `--allowedTools`.
- Stage failures write the STUCK block to stderr and the pipeline exits non-zero if any stage failed.

### Docs
- `protocols/explore.md` and `protocols/verify.md` corrected to document the stuck-detector global budget as `> 60`.
- `protocols/verify.md` verification ladder rewritten to match verify's actual `--allowedTools` set.

## [2.0.0] - 2026-05-19

Initial release.
