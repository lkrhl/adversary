---
description: Scaffold a project-local adversary config at <cwd>/.adversary/config.json with every documented key set to its default value. Refuses if the file already exists; edit by hand or delete first.
allowed-tools: ["Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/init.sh *)"]
---

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/init.sh "$ARGUMENTS"`
