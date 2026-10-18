#!/bin/bash
# code-guard: PreToolUse(mcp__.*) guard.
# MCP tools that delete or publish external resources, or change secrets, need user approval (ask).
# This keeps operations that guard-bash.sh stops on the CLI (wrangler, gcloud, gh) from slipping through an MCP route.
#
# The decision uses the words in the tool name (without the server name; camelCase is split) and, for tools that take SQL,
# the input text. There is no per-server list. When you change this, add cases to tests/test-guard.sh and run it.
set -uo pipefail

# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/lib/common.sh" || { echo "BLOCKED by code-guard: cannot load lib/common.sh; blocking everything this hook covers." >&2; exit 2; }
need_cmd jq perl

input="$(cat)"
tool="$(jq -er '.tool_name // ""' <<<"$input")" \
  || block "could not read the hook input (not valid JSON); blocking everything this hook covers"
name="${tool##*__}"
# deleteRepository -> delete_Repository, so the words can be split on _ and -
name_w="$(sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' <<<"$name")"

# Does the tool name (words split by _ or -) contain a word for delete / publish / change secrets, or is it a tool that
# writes to a branch (merge, push, commit a file straight to a branch, move a ref)
if grep -Eiq '(^|[_-])(delete|destroy|drop|purge|remove|truncate|wipe|erase|deploy|publish|unpublish|rollback|secret|secrets)([_-]|$)|(^|_)(merge_pull_request|merge_branch|push_files|push_branch|force_push|create_or_update_file|update_file|create_commit|update_ref)$' <<<"$name_w"; then
  ask "MCP tool $tool: deletes, publishes, merges or pushes an external resource, or changes a secret. Confirm the user has OKed this in chat before approving"
fi

# Tools that run SQL (query, sql, execute) ask when the statement changes data.
# All string values are joined; /* comments */ and -- comments are dropped, newline, tab and NBSP are flattened to spaces, so
# DELETE/**/FROM and DELETE--x<newline>FROM are seen. A keyword may be followed by a quote or a parenthesis (UPDATE"t", INSERT(a))
# A comment mark inside a string literal is not a comment (SELECT '--'; DELETE ..., SELECT '/*'; DELETE ...), so the text
# is also read with the comments kept. # is a MySQL comment. replace and copy count only at the start of a statement
# (replace(name, 'a', 'b') is a function)
if grep -Eiq '(^|[_-])(query|sql|execute|exec)([_-]|$)' <<<"$name_w" \
   && jq -r '[.. | strings] | join(" ")' <<<"$(jq -c '.tool_input // {}' <<<"$input")" 2>/dev/null \
        | perl -0pe 's/\xc2\xa0/ /g; my $k = $_; s{/\*.*?\*/}{ }gs; s/--[^\n]*/ /g; s/#[^\n]*/ /g; $_ .= ";\n" . $k' | tr '\n\t\r' '   ' \
        | grep -Eiq '(^|[^[:alnum:]_])(drop|delete|truncate|alter|update|insert|create|merge|grant|revoke|rename|upsert)([[:space:]"`(\[]|$)|(^|;)[[:space:]]*(replace|copy)([[:space:]"`(\[]|$)'; then
  ask "MCP tool $tool: SQL that changes the database. Confirm the user has OKed this in chat before approving"
fi

exit 0
