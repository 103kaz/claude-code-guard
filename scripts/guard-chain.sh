#!/bin/bash
# code-guard: PreToolUse(Bash). Stops a command chained (&& || ; | newline) to a command listed in the
# sandbox's excludedCommands. An excluded command runs outside the sandbox only as the whole command; chained, it runs
# inside the sandbox and fails (a git write under .git, a gh call). Stopping it first saves the failed run.
# This is a usability aid, not a security guard: when the settings or the input cannot be read, it passes.
# When you change this, add cases to tests/test-chain.sh and run it.
set -uo pipefail

command -v jq >/dev/null 2>&1 && command -v perl >/dev/null 2>&1 || exit 0

input="$(cat)"
cmd="$(jq -er '.tool_input.command // ""' <<<"$input" 2>/dev/null)" || exit 0
# A command with none of the separator characters is a single command
case "$cmd" in
  *'&'*|*';'*|*'|'*|*$'\n'*) ;;
  *) exit 0 ;;
esac

HOME="${HOME:-/nonexistent-home}"
proj="${CLAUDE_PROJECT_DIR:-.}"
files=()
for f in "$HOME/.claude/settings.json" "$proj/.claude/settings.json" "$proj/.claude/settings.local.json"; do
  [ -f "$f" ] && files+=("$f")
done
[ "${#files[@]}" -gt 0 ] || exit 0

# Later files win for "enabled" (false is a value, so unset is filtered with select, not //); the excluded commands of
# all files are joined
cfg="$(jq -s -c '{enabled: ([.[].sandbox.enabled | select(. != null)] | last // false), patterns: ([.[].sandbox.excludedCommands // []] | add // [] | unique)}' "${files[@]}" 2>/dev/null)" || exit 0
[ "$(jq -r '.enabled' <<<"$cfg" 2>/dev/null)" = true ] || exit 0
patterns="$(jq -r '.patterns[]' <<<"$cfg" 2>/dev/null)" || exit 0
[ -n "$patterns" ] || exit 0

# The perl script splits the command at the top level (quotes, redirects like 2>&1 and heredoc bodies are not
# separators) and prints the first segment that matches an excluded pattern when there is more than one segment
hit="$(CG_CMD="$cmd" CG_PATTERNS="$patterns" perl "${BASH_SOURCE[0]%/*}/lib/chain.pl" 2>/dev/null)" || exit 0
[ -n "$hit" ] || exit 0

{
  echo "BLOCKED by code-guard: '$hit' is excluded from the sandbox (settings sandbox.excludedCommands) only as the whole command."
  echo "Chained with && || ; | or a newline it runs inside the sandbox and fails. This is not a policy block: run each command in its own Bash call, with no chaining, redirects or pipes added."
} >&2
exit 2
