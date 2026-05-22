#!/usr/bin/env bash
# Adversary STUCK detector — PreToolUse hook for the adversary subprocess pipeline.
#
# Gate: only fires when ADVERSARY_SUBPROCESS=1 in env (set by the slash command's
# bash invocation around each subprocess). Exits 0 (no-op) otherwise — so the hook
# is inert in the user's interactive session even though the plugin is loaded there.
#
# State: per-subprocess JSON file at /tmp/adversary-stuck-${ADVERSARY_RUN_ID}.json.
# The hook writes as a shell process, not as a Claude tool call, so this is NOT
# subject to the path-anchored permission allowlist that bites Read/Write/Edit.
#
# Rules:
#   1. Same (tool, args_hash) 3rd time in this subprocess → block (exit 2)
#   2. Global tool-call count > 60 in this subprocess → block (exit 2)
#
# When blocked, the hook prints a STUCK: message to stderr; the protocol instructs
# the subprocess to surface a STUCK block and return.

set -u

if [[ "${ADVERSARY_SUBPROCESS:-}" != "1" ]]; then
  exit 0
fi

RUN_ID="${ADVERSARY_RUN_ID:-default}"
STATE_FILE="/tmp/adversary-stuck-${RUN_ID}.json"

INPUT="$(cat)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // "unknown"')"
ARGS_JSON="$(printf '%s' "$INPUT" | jq -c '.tool_input // {}')"
ARGS_HASH="$(printf '%s|%s' "$TOOL" "$ARGS_JSON" | openssl md5 | awk '{print $NF}' | cut -c1-12)"

if [[ ! -f "$STATE_FILE" ]]; then
  echo '{"calls":[],"global_count":0}' > "$STATE_FILE"
fi

CURRENT_STATE="$(cat "$STATE_FILE")"
GLOBAL_COUNT="$(printf '%s' "$CURRENT_STATE" | jq '.global_count')"

NEW_GLOBAL=$((GLOBAL_COUNT + 1))
if (( NEW_GLOBAL > 60 )); then
  echo "STUCK: budget-blow (>60 tool calls in this subprocess run). Emit STUCK block and return." >&2
  exit 2
fi

SAME_COUNT="$(printf '%s' "$CURRENT_STATE" | jq --arg h "$ARGS_HASH" '[.calls[] | select(.args_hash == $h)] | length')"
NEW_SAME=$((SAME_COUNT + 1))
if (( NEW_SAME >= 3 )); then
  echo "STUCK: same tool call repeated 3 times (tool=${TOOL}, args_hash=${ARGS_HASH}). Emit STUCK block and return." >&2
  exit 2
fi

UPDATED="$(printf '%s' "$CURRENT_STATE" | jq --arg t "$TOOL" --arg h "$ARGS_HASH" --argjson g "$NEW_GLOBAL" \
  '.calls += [{"tool":$t,"args_hash":$h,"ts":now}] | .global_count = $g')"
printf '%s' "$UPDATED" > "$STATE_FILE"

exit 0
