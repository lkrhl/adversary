---
description: Run an adversarial 3-stage critique (explore → verify → review) of an artifact in three fresh Claude subprocesses. Prints structured findings in chat with section refs and timestamps. No sidecar file, no parent-context cost.
allowed-tools: ["Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/pipeline.sh *)"]
---

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/pipeline.sh "$ARGUMENTS"`
