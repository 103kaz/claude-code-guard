#!/bin/bash
# code-guard: PreToolUse(Bash). With the pr_title_prefixes option set, stops gh pr create / gh pr edit whose --title does not
# start with one of the prefixes (feat: fix(scope): ...). Off while the option is empty.
# This is a style aid, not a security guard: a title it cannot read (built by a variable or substitution, no --title) passes.
# When you change this, add cases to tests/test-pr-title.sh and run it.
set -uo pipefail

command -v jq >/dev/null 2>&1 && command -v perl >/dev/null 2>&1 || exit 0

# Claude Code passes a multiple option as one string joined by commas; a JSON array and a space separated list are read too
raw="$(printf '%s' "${CLAUDE_PLUGIN_OPTION_PR_TITLE_PREFIXES:-}" | tr -d '[]"' | tr ',' ' ')"
prefixes=""
set -f
for p in $raw; do
  # only plain word characters; anything else is ignored
  case "$p" in *[!A-Za-z0-9_-]*|'') continue ;; esac
  prefixes="${prefixes:+$prefixes|}$p"
done
set +f
[ -n "$prefixes" ] || exit 0

cmd="$(jq -er '.tool_input.command // ""' 2>/dev/null)" || exit 0
case "$cmd" in
  *gh*pr*) ;;
  *) exit 0 ;;
esac

hit="$(CG_CMD="$cmd" CG_PREFIXES="$prefixes" perl "${BASH_SOURCE[0]%/*}/lib/pr-title.pl" 2>/dev/null)" || exit 0
[ -n "$hit" ] || exit 0

{
  echo "BLOCKED by code-guard: the PR title '${hit#*$'\t'}' does not start with a required prefix (${prefixes//|/:, }:), e.g. 'feat: ...' or 'fix(scope): ...'."
  echo "This is not a policy block: run the same command with a title that starts with the prefix that fits the change."
} >&2
exit 2
