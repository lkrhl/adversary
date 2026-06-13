#!/usr/bin/env bash
# Adversary 3-subprocess pipeline.
#
# Invoked by commands/review.md via:
#   bash ${CLAUDE_PLUGIN_ROOT}/scripts/pipeline.sh <artifact-path>
#
# Spawns three fresh `claude --print` subprocesses (explore → verify → review),
# chaining their stdout outputs as the next subprocess's prompt input.
# Each subprocess has its own ADVERSARY_RUN_ID for independent stuck-detector
# state files; the stuck-detector hook is gated on ADVERSARY_SUBPROCESS=1 so it
# only fires inside these subprocesses, not in the parent interactive session.

set -e

# Optional timing probe: gated on ADVERSARY_DEBUG=1 in env. Off by default so
# normal runs don't write sidecar files. Useful for diagnosing parent-side
# (harness/UI) latency vs. subprocess time when investigating "delay" reports.
if [[ "${ADVERSARY_DEBUG:-}" == "1" ]]; then
  printf '%s epoch=%s pipeline.sh START pid=%s args=%q\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(date '+%s')" "$$" "${1:-}" >> /tmp/adversary-timing.log
fi

ARTIFACT_PATH="${1:-}"
if [[ -z "$ARTIFACT_PATH" ]]; then
  echo "Error: artifact path required" >&2
  echo "Usage: /adversary:review <path-to-artifact>" >&2
  exit 64
fi

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PIPELINE_ID="$(date +%s)-$$"
export ADVERSARY_SUBPROCESS=1

# Per-stage status + usage rows. We can't keep this in bash variables because each
# `EXPLORE=$(run_stage ...)` runs the function in a command-substitution subshell;
# bash variable mutations there don't reach the parent. One TSV row per stage:
#   <stage>\t<status>\t<in>\t<out>\t<cc>\t<cr>\t<cost>
# Status is OK, FAILED, or API_ERROR. Failed/API_ERROR rows have zeros for tokens.
# API_ERROR signals transient Anthropic failures (529, overloaded, rate limit,
# 5xx) and triggers an early abort instead of the cascade-with-STUCK fallback.
STATE_FILE="/tmp/adversary-state-${PIPELINE_ID}.tsv"
API_ERROR_FILE="/tmp/adversary-api-error-${PIPELINE_ID}.txt"
: > "$STATE_FILE"
rm -f "$API_ERROR_FILE"

# Regex for transient Anthropic API failures we want to short-circuit on.
# Matched against stderr (when claude exits non-zero) and against the JSON
# result text (when claude exits zero but sets is_error=true).
API_ERROR_RE='API Error|overloaded|rate.?limit|529|502|503|504|insufficient_quota'

# Project-local config: tool grants + reporting toggles. Lives at
# $PWD/.adversary/config.json with shape:
#   {
#     "tools": {"verify": {"extra_allowed_tools": ["Bash(gh *)", "mcp__Ref__...", ...]}},
#     "costReporting": false,
#     "debug": false
#   }
# All keys optional. Both toggles default false. Env vars override config
# (ADVERSARY_DEBUG=1 enables debug; ADVERSARY_COST_REPORTING=1|true enables
# cost reporting; either env var set to 0|false disables). Tool entries are
# filtered through a hardcoded read-only-ish denylist below; built-in tools
# auto-routed to --tools as well. Broken/missing config = defaults.
VERIFY_EXTRA_ALLOWED_TOOLS=""
VERIFY_EXTRA_BUILTINS=""
COST_REPORTING=0
CONFIG_FILE="${PWD}/.adversary/config.json"
# Denylist regexes — anchored, applied to each user-supplied tool entry. Broad
# Bash patterns (e.g. `Bash(npm *)`) bypass the denylist by design — narrow
# patterns are the only ones we can safely filter (see README "Configuring the
# plugin" → "Broad-vs-narrow Bash patterns" for the trade-off).
TOOLS_DENYLIST_RE=(
  '^Edit(\(|$)'
  '^Write(\(|$)'
  '^MultiEdit(\(|$)'
  '^NotebookEdit(\(|$)'
  '^Bash\(rm '
  '^Bash\(mv '
  '^Bash\(cp '
  '^Bash\(chmod '
  '^Bash\(chown '
  '^Bash\(sudo '
  '^Bash\(ssh '
  '^Bash\(scp '
  '^Bash\(rsync '
  '^Bash\(npm install'
  '^Bash\(npm i '
  '^Bash\(yarn add'
  '^Bash\(pip install'
  '^Bash\(composer install'
  '^Bash\(composer require'
  '^Bash\(apt '
  '^Bash\(brew install'
  '^Bash\(git push'
  '^Bash\(git commit'
  '^Bash\(git rebase'
  '^Bash\(git reset'
  '^Bash\(git checkout '
)
# Built-in tools that need to be added to `--tools` (the *available* set) when
# the user lists them, not just `--allowedTools`. MCP tools and Bash subcommand
# patterns don't need this — they flow through `--allowedTools` once `Bash` is
# already available.
BUILTIN_TOOLS_RE='^(WebSearch|WebFetch|TodoWrite|Task)$'

if [[ -f "$CONFIG_FILE" ]]; then
  if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
    printf 'pipeline.sh: %s exists but is not valid JSON; ignoring and continuing with defaults\n' "$CONFIG_FILE" >&2
  else
    # Reporting toggles. Both default off; env vars further down override these.
    if [[ "$(jq -r '.costReporting // false' "$CONFIG_FILE")" == "true" ]]; then
      COST_REPORTING=1
    fi
    if [[ -z "${ADVERSARY_DEBUG:-}" ]] && [[ "$(jq -r '.debug // false' "$CONFIG_FILE")" == "true" ]]; then
      export ADVERSARY_DEBUG=1
    fi
    # verify-stage tool extensions.
    while IFS= read -r tool; do
      [[ -z "$tool" ]] && continue
      deny_hit=""
      for regex in "${TOOLS_DENYLIST_RE[@]}"; do
        if [[ "$tool" =~ $regex ]]; then
          deny_hit="$regex"
          break
        fi
      done
      if [[ -n "$deny_hit" ]]; then
        printf 'pipeline.sh: dropping %s — matches read-only-ish denylist (%s). verify is read-only by design; broaden a Bash pattern with care.\n' "$tool" "$deny_hit" >&2
        continue
      fi
      VERIFY_EXTRA_ALLOWED_TOOLS+=" $tool"
      if [[ "$tool" =~ $BUILTIN_TOOLS_RE ]]; then
        VERIFY_EXTRA_BUILTINS+=",$tool"
      fi
    done < <(jq -r '.tools.verify.extra_allowed_tools[]? // empty' "$CONFIG_FILE")
  fi
fi

# Env-var overrides apply after the config file so they win on conflict.
if [[ -n "${ADVERSARY_COST_REPORTING:-}" ]]; then
  case "${ADVERSARY_COST_REPORTING,,}" in
    0|false|off|no) COST_REPORTING=0 ;;
    1|true|on|yes)  COST_REPORTING=1 ;;
  esac
fi

# Runs one `claude --print` stage. Three outcomes:
#   1. OK     — normal output flows downstream.
#   2. FAILED — non-API failure (logic, missing files, etc.). Substitutes a
#               STUCK block so the downstream stage's existing STUCK-handling
#               logic kicks in instead of cascading failure to the parent.
#   3. API_ERROR — transient Anthropic failure (529, overloaded, 5xx, rate
#                  limit). Captures the reason for the main loop to abort on,
#                  no STUCK block (would mislead the next stage about a real
#                  finding). Main loop checks STATE_FILE between stages.
# set +e/-e is scoped to the claude call only; the outer set -e remains in
# effect for non-subprocess errors (bad args, missing protocol files, etc.).
run_stage() {
  local stage="$1" protocol="$2" prompt="$3"
  shift 3
  local stderr_file json_output output rc usage_line t_in t_out t_cc t_cr cost
  local api_reason is_error err_result
  stderr_file=$(mktemp)
  export ADVERSARY_RUN_ID="${PIPELINE_ID}-${stage}"
  # Prompt piped via stdin, not appended as a positional — `--allowedTools <tools...>`
  # and `--tools <tools...>` are Commander.js variadic flags and would otherwise eat a
  # trailing positional prompt as an extra tool spec, leaving claude with no input.
  # `--output-format json` so we can extract usage/cost alongside the response text
  # (which arrives as the `.result` field of the result event).
  set +e
  json_output=$(printf '%s' "$prompt" | claude --print --no-session-persistence \
    --model opus \
    --output-format json \
    --append-system-prompt "$(cat "$protocol")" \
    "$@" 2>"$stderr_file")
  rc=$?
  set -e

  # Classify outcome. API errors get checked first because they can surface
  # either as non-zero exit (stderr) OR zero exit with is_error=true (JSON).
  api_reason=""
  if (( rc != 0 )) && grep -qEi "$API_ERROR_RE" "$stderr_file"; then
    api_reason=$(grep -Ei "$API_ERROR_RE" "$stderr_file" | head -1 | head -c 500)
  elif (( rc == 0 )) && [[ -n "$json_output" ]]; then
    is_error=$(printf '%s' "$json_output" | jq -r '.[] | select(.type=="result") | .is_error // false' 2>/dev/null)
    if [[ "$is_error" == "true" ]]; then
      err_result=$(printf '%s' "$json_output" | jq -r '.[] | select(.type=="result") | .result // ""' 2>/dev/null | head -c 500)
      if printf '%s' "$err_result" | grep -qEi "$API_ERROR_RE"; then
        api_reason="$err_result"
      fi
    fi
  fi

  if [[ -n "$api_reason" ]]; then
    printf '%s' "$api_reason" > "$API_ERROR_FILE"
    printf '%s\tAPI_ERROR\t0\t0\t0\t0\t0\n' "$stage" >> "$STATE_FILE"
    printf 'pipeline.sh: %s stage hit transient Anthropic API error; aborting pipeline\n' "$stage" >&2
    output=""
  elif (( rc != 0 )); then
    output=$(printf '## STUCK\nReason: %s subprocess exited %d. See stderr below.\nPartial output: <none>\nstderr (truncated 1KB):\n%s\nRecommendation to downstream: graceful degradation\n' \
      "$stage" "$rc" "$(head -c 1024 "$stderr_file")")
    # Surface the failure to stderr so it's visible even when downstream stages
    # gracefully degrade and overwrite the final stdout payload.
    printf 'pipeline.sh: %s stage failed (exit %d); STUCK block substituted, downstream graceful degradation in effect\n%s\n' \
      "$stage" "$rc" "$output" >&2
    printf '%s\tFAILED\t0\t0\t0\t0\t0\n' "$stage" >> "$STATE_FILE"
  else
    output=$(printf '%s' "$json_output" | jq -r '.[] | select(.type=="result") | .result // ""')
    usage_line=$(printf '%s' "$json_output" | jq -r '
      .[] | select(.type=="result") |
      "\(.usage.input_tokens // 0) \(.usage.output_tokens // 0) \(.usage.cache_creation_input_tokens // 0) \(.usage.cache_read_input_tokens // 0) \(.total_cost_usd // 0)"
    ')
    read -r t_in t_out t_cc t_cr cost <<< "$usage_line"
    printf '%s\tOK\t%s\t%s\t%s\t%s\t%s\n' "$stage" "${t_in:-0}" "${t_out:-0}" "${t_cc:-0}" "${t_cr:-0}" "${cost:-0}" >> "$STATE_FILE"
    if (( COST_REPORTING == 1 )); then
      printf 'pipeline.sh: %s tokens in=%s out=%s cache_create=%s cache_read=%s cost=$%s\n' \
        "$stage" "$t_in" "$t_out" "$t_cc" "$t_cr" "$cost" >&2
    fi
  fi
  rm -f "$stderr_file"
  printf '%s' "$output"
}

# Called between stages. If the most recent stage hit an API_ERROR, print a
# clear human-readable abort message and exit 75 (EX_TEMPFAIL) so the parent
# session can distinguish transient API failures from real plugin bugs.
abort_if_api_error() {
  grep -q $'\tAPI_ERROR\t' "$STATE_FILE" || return 0
  local stage reason
  stage=$(grep $'\tAPI_ERROR\t' "$STATE_FILE" | head -1 | cut -f1)
  reason=$(cat "$API_ERROR_FILE" 2>/dev/null || echo "<no detail captured>")
  # Surface completed-stage outputs on stdout so the parent session sees them
  # verbatim (vs. paraphrasing whatever it picks up from the stderr banner).
  # Reads the main-scope EXPLORE/VERIFY vars directly — unset/empty if that
  # stage didn't run or didn't complete.
  if [[ -n "${EXPLORE:-}" ]]; then
    printf '## Partial results — explore stage (completed)\n\n%s\n\n' "$EXPLORE"
  fi
  if [[ -n "${VERIFY:-}" ]]; then
    printf '## Partial results — verify stage (completed)\n\n%s\n\n' "$VERIFY"
  fi
  cat >&2 <<EOF

========================================
adversary: aborted — Anthropic API error
========================================
Stage:  ${stage}
Detail: ${reason}

This is a transient Anthropic API issue (overload, rate limit, or 5xx).
The pipeline stopped before subsequent stages ran; no partial review was
produced because cascading on a transient error would yield misleading
output. Please retry in a few minutes.
========================================
EOF
  if [[ "${ADVERSARY_DEBUG:-}" != "1" ]]; then
    rm -f "$STATE_FILE" "$API_ERROR_FILE" \
          "/tmp/adversary-stuck-${PIPELINE_ID}-explore.json" \
          "/tmp/adversary-stuck-${PIPELINE_ID}-verify.json" \
          "/tmp/adversary-stuck-${PIPELINE_ID}-review.json"
  fi
  exit 75
}

EXPLORE=$(run_stage "explore" "${PLUGIN_ROOT}/protocols/explore.md" "ARTIFACT_PATH: ${ARTIFACT_PATH}" \
  --tools "Read,Grep,Glob" \
  --allowedTools "Read Grep Glob")
abort_if_api_error

VERIFY_PROMPT=$(printf 'ARTIFACT_PATH: %s\n\nEXPLORE_OUTPUT:\n%s' "$ARTIFACT_PATH" "$EXPLORE")
VERIFY=$(run_stage "verify" "${PLUGIN_ROOT}/protocols/verify.md" "$VERIFY_PROMPT" \
  --tools "Read,Grep,Glob,Bash,WebFetch${VERIFY_EXTRA_BUILTINS}" \
  --allowedTools "Read Grep Glob Bash(git *) Bash(docker *) Bash(curl *) Bash(lsof *) Bash(wc *) Bash(psql *) Bash(mysql *) Bash(sqlite3 *) WebFetch${VERIFY_EXTRA_ALLOWED_TOOLS}")
abort_if_api_error

REVIEW_PROMPT=$(printf 'ARTIFACT_PATH: %s\n\nVERIFY_OUTPUT:\n%s' "$ARTIFACT_PATH" "$VERIFY")
REVIEW=$(run_stage "review" "${PLUGIN_ROOT}/protocols/review.md" "$REVIEW_PROMPT" \
  --tools "Read,Grep,Glob" \
  --allowedTools "Read Grep Glob")
abort_if_api_error

if [[ "${ADVERSARY_DEBUG:-}" == "1" ]]; then
  printf '%s epoch=%s pipeline.sh END   pid=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(date '+%s')" "$$" >> /tmp/adversary-timing.log
fi

printf '%s\n' "$REVIEW"

# Aggregate totals from the per-stage state file. Failed stages have zeros in the
# token columns so they contribute nothing; the cost column is summed with awk's
# native float arithmetic so we don't lose precision on the running total.
# LC_NUMERIC=C: jq always emits dotted decimals, but awk respects the system
# LC_NUMERIC for both parsing AND formatting — so a comma-locale would silently
# parse "0.75" as integer 0 and emit "1,23" instead of "1.23". Force C-locale.
# Gated on COST_REPORTING so config.costReporting=false suppresses the totals
# line in addition to the per-stage stderr lines.
if (( COST_REPORTING == 1 )); then
  LC_NUMERIC=C awk -F'\t' '
    $2 == "OK" { in_t += $3; out_t += $4; cc += $5; cr += $6; cost += $7 }
    END {
      printf "\n---\npipeline total tokens: in=%d out=%d cache_create=%d cache_read=%d | cost=$%.6f\n", in_t, out_t, cc, cr, cost
    }
  ' "$STATE_FILE"
fi

if grep -q $'\tFAILED\t' "$STATE_FILE"; then
  EXIT_CODE=1
else
  EXIT_CODE=0
fi

# Cleanup at end of run. Skipped under ADVERSARY_DEBUG=1 so the state files remain
# inspectable when diagnosing a run. Runs regardless of whether stages produced
# STUCK blocks — failure context is captured in the STUCK blocks (stage name,
# exit code, stderr) by run_stage and in the FAILED rows of STATE_FILE.
if [[ "${ADVERSARY_DEBUG:-}" != "1" ]]; then
  rm -f "$STATE_FILE" "$API_ERROR_FILE" \
        "/tmp/adversary-stuck-${PIPELINE_ID}-explore.json" \
        "/tmp/adversary-stuck-${PIPELINE_ID}-verify.json" \
        "/tmp/adversary-stuck-${PIPELINE_ID}-review.json"
fi

exit "$EXIT_CODE"
