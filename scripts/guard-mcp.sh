#!/bin/bash
# code-guard: PreToolUse(mcp__.*) guard.
# MCP tools that delete or publish external resources, or change secrets, need user approval (ask).
# This keeps operations that guard-bash.sh stops on the CLI (wrangler, gcloud, gh) from slipping through an MCP route.
#
# The decision uses the words in the tool name (without the server name) and, for tools that take SQL, the input text.
# There is no per-server list. When you change this, add cases to tests/test-guard.sh and run it.
set -uo pipefail

# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/lib/common.sh" || { echo "BLOCKED by code-guard: cannot load lib/common.sh; blocking everything this hook covers." >&2; exit 2; }
need_cmd jq

input="$(cat)"
tool="$(jq -r '.tool_name // ""' <<<"$input")"
name="${tool##*__}"

# Does the tool name (words split by _ or -) contain a word for delete / publish / change secrets
if grep -Eiq '(^|[_-])(delete|destroy|drop|purge|remove|truncate|wipe|deploy|publish|rollback|secret|secrets)([_-]|$)' <<<"$name"; then
  ask "MCP tool $tool: deletes or publishes an external resource, or changes a secret. Confirm the user has OKed this in chat before approving"
fi

# Tools that run SQL (query, sql, execute) ask when the statement changes data
if grep -Eiq '(^|[_-])(query|sql|execute|exec)([_-]|$)' <<<"$name" \
   && jq -r '.tool_input | tostring' <<<"$input" | grep -Eiq '(^|[^[:alnum:]_])(drop|delete|truncate|alter|update|insert|replace|create)[[:space:]]'; then
  ask "MCP tool $tool: SQL that changes the database. Confirm the user has OKed this in chat before approving"
fi

exit 0
