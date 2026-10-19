#!/bin/bash
# code-guard: PreToolUse(mcp__.*) guard.
# MCP tools that delete or publish external resources, or change secrets, need user approval (ask).
# This keeps operations that guard-bash.sh stops on the CLI (wrangler, gcloud, gh) from slipping through an MCP route.
#
# The decision uses the words in the tool name (without the server name; camelCase is split) and the input text (SQL).
# There is no per-server list. When you change this, add cases to tests/test-guard.sh and run it.
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

# A tool that writes straight to a branch is blocked when its branch / ref argument is a protected branch, as a Bash push
# to it is. Without the argument (the server picks the branch) it is asked below. Tools that commit a file change to the
# branch they are given (delete_file, create_file, write_file, edit_file, commit_files) count too; without a branch
# argument they write elsewhere (a local file) and are not judged here
# A name with the word push (git_push, push) is one too; it asks when it is given a branch / ref / refspec, or when push is its last word (push_notification is not)
branch_vals=""
if grep -Eiq '(^|_)(push_files|push_branch|force_push|create_or_update_file|update_file|create_commit|update_ref|delete_file|create_file|write_file|edit_file|commit_files)$|(^|[_-])push([_-]|$)' <<<"$name_w"; then
  branch_vals="$(jq -r '.tool_input | [.. | objects | (.branch, .ref, (.refspec | strings | sub("^\\+"; "") | split(":") | last))] | .[] | select(type == "string") | gsub("^\\s+|\\s+$"; "") | select(. != "")' <<<"$input" 2>/dev/null)"
  # Both branch and ref are read, at any depth of the input; an empty value is no value. Spaces around a value are dropped (" main " may reach
  # main if the server trims it)
  while IFS= read -r target; do
    target="${target#refs/}"; target="${target#heads/}"
    if is_protected_branch "$target"; then
      block "MCP tool $tool: writes straight to the protected branch $target (${PROTECTED_LIST}). Create a branch and open a PR"
    fi
  done <<<"$branch_vals"
  # A tool whose last word is push (git_push) can push the current branch with no argument, so it asks either way
  if grep -Eiq '(^|[_-])push$' <<<"$name_w" || { [ -n "$branch_vals" ] && grep -Eiq '(^|[_-])push([_-]|$)' <<<"$name_w"; }; then
    ask "MCP tool $tool: pushes to a branch. Confirm the user has OKed this in chat before approving"
  fi
fi

# Does the tool name (words split by _ or -) contain a word for delete / publish / change secrets, or is it a tool that
# writes to a branch (merge, push, commit a file straight to a branch, move a ref)
if grep -Eiq '(^|[_-])(delete|destroy|drop|purge|remove|truncate|wipe|erase|deploy|publish|unpublish|rollback|secret|secrets)([_-]|$)|(^|_)(merge_pull_request|merge_branch|push_files|push_branch|force_push|create_or_update_file|update_file|create_commit|update_ref)$' <<<"$name_w"; then
  ask "MCP tool $tool: deletes, publishes, merges or pushes an external resource, or changes a secret. Confirm the user has OKed this in chat before approving"
fi

# Is the tool one that takes SQL (query, sql, execute, exec, migration)
sql_tool=0
grep -Eiq '(^|[_-])(query|sql|execute|exec|migration|migrations|migrate)([_-]|$)' <<<"$name_w" && sql_tool=1
# A tool that only reads (search, list, get ...) is not judged by its input: a search for "DELETE FROM" changes nothing.
# The input is not read for it either. A name that also has a word that writes (get_or_create, find_and_replace) is not one
if [ "$sql_tool" = 0 ] && grep -Eiq '^(get|list|search|read|describe|fetch|find|view|show)([_-]|$)' <<<"$name_w" \
   && ! grep -Eiq '[_-](or|and|then|create|update|insert|upsert|set|put|write|add|apply|replace|save|edit|modify|send)([_-]|$)' <<<"$name_w"; then
  exit 0
fi

# SQL that changes data asks. All string values are joined; /* comments */ and -- comments are dropped, newline, tab and NBSP
# are flattened to spaces, so DELETE/**/FROM and DELETE--x<newline>FROM are seen. A keyword may be followed by a quote or a
# parenthesis (UPDATE"t", INSERT(a))
# A comment mark inside a string literal is not a comment (SELECT '--'; DELETE ..., SELECT '/*'; DELETE ...), so the text
# is also read with the comments kept. # is a MySQL comment
# A quoted identifier of one word ("update", `delete`, [create]) is a name, not a keyword: its text becomes x. An identifier
# with spaces or other marks is kept as it is (it can be quotes inside a string around a statement)
sql_text="$(jq -r '[.. | strings] | join(" ")' <<<"$(jq -c '.tool_input // {}' <<<"$input")" 2>/dev/null \
  | perl -0pe 's/\xc2\xa0/ /g; my $k = $_; s{/\*.*?\*/}{ }gs; s/--[^\n]*/ /g; s/#[^\n]*/ /g; $_ .= ";\n" . $k;
      s/(["`])([^"`]*)\1/ my ($q, $s) = ($1, $2); $s =~ m{^[\w\$]*$} ? "${q}x$q" : "$q$s$q" /ge; s/\[[\w\$]*\]/[x]/g' | tr '\n\t\r' '   ')"
# Tools that take SQL: any data-changing keyword asks. replace and copy count only at the start of a statement
# (replace(name, 'a', 'b') is a function)
if [ "$sql_tool" = 1 ] \
   && grep -Eiq '(^|[^[:alnum:]_])(drop|delete|truncate|alter|update|insert|create|merge|grant|revoke|rename|upsert)([[:space:]"`(\[]|$)|(^|;)[[:space:]]*(replace|copy)([[:space:]"`(\[]|$)' <<<"$sql_text"; then
  ask "MCP tool $tool: SQL that changes the database. Confirm the user has OKed this in chat before approving"
fi
# Any other tool (run, statement, ...) asks when the input has the shape of a data-changing statement
# (DELETE FROM, UPDATE t SET, INSERT INTO, DROP / ALTER / CREATE / TRUNCATE TABLE ...). UPDATE with an alias or a JOIN,
# a multi-table DELETE, TRUNCATE of several tables and MySQL's INSERT without INTO are included
Q='[[:space:]"`(\[]*'
NAME='[^[:space:];]+'
T='[[:alnum:]_"`.]+'
OBJ='(table|database|schema|view|index|unique|sequence|function|procedure|trigger|type|role|user|extension|policy|materialized|temp|temporary|column|constraint|if)'
if grep -Eiq "(^|[^[:alnum:]_])(delete${Q}from|insert${Q}(into|or|ignore)|(replace|merge)${Q}into|update${Q}${NAME}([[:space:]]+(as[[:space:]]+)?[[:alnum:]_]+)?${Q}set|update[[:space:]][^;]*[[:space:]]join[[:space:]][^;]*[[:space:]]set|delete${Q}([[:alnum:]_.]+[[:space:]]*,[[:space:]]*)*[[:alnum:]_.]+[[:space:]]+from|insert${Q}${NAME}${Q}(values|select|set)|rename${Q}(table|user)|(drop|alter|truncate)${Q}${OBJ}|create${Q}(or[[:space:]]+replace[[:space:]]+)?${OBJ}|truncate[[:space:]]+(only[[:space:]]+)?${T}([[:space:]]*,[[:space:]]*${T})*[[:space:]]*(;|$)|(grant|revoke)[[:space:]]+(all|select|insert|update|delete|usage|execute|references|trigger|create|connect)([[:space:],]|$))([^[:alnum:]_]|$)" <<<"$sql_text"; then
  ask "MCP tool $tool: the input looks like SQL that changes the database. Confirm the user has OKed this in chat before approving"
fi

exit 0
