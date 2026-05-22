# Changelog

All notable changes to the `adversary` plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
