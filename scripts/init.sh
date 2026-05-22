#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR=".adversary"
CONFIG_FILE="${CONFIG_DIR}/config.json"

if [[ -e "$CONFIG_FILE" ]]; then
  printf '%s already exists. Edit by hand or delete it before re-running.\n' "$CONFIG_FILE" >&2
  exit 1
fi

mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_FILE" <<'JSON'
{
  "tools": {
    "verify": {
      "extra_allowed_tools": []
    }
  },
  "costReporting": false,
  "debug": false
}
JSON

printf 'Created %s\n' "$CONFIG_FILE"
printf 'Edit to customize. See README "Configuring the plugin" section for available extras and the read-only-ish denylist.\n'
