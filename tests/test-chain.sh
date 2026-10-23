#!/bin/bash
# Regression test for scripts/guard-chain.sh (a command chained to a sandbox-excluded command). Run it after changing the check.
set -uo pipefail
hook="$(cd "$(dirname "$0")/../scripts" && pwd)/guard-chain.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-chain.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0
n=0
ng() { echo "FAIL: $1"; fail=1; }

home="$tmp/home"
proj="$tmp/proj"
mkdir -p "$home/.claude" "$proj/.claude"

# settings <home-json> [<project-json>]: write the settings files the hook reads
settings() {
  printf '%s' "$1" > "$home/.claude/settings.json"
  rm -f "$proj/.claude/settings.json" "$proj/.claude/settings.local.json"
  [ -n "${2:-}" ] && printf '%s' "$2" > "$proj/.claude/settings.json"
  return 0
}

# check <want 0|2> <command>: RC is the hook's exit code
check() {
  n=$((n + 1))
  local want="$1" cmd="$2" rc
  jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' \
    | HOME="$home" CLAUDE_PROJECT_DIR="$proj" bash "$hook" >/dev/null 2>"$tmp/err"
  rc=$?
  [ "$rc" = "$want" ] || ng "want $want, got $rc: $cmd"
}

ON='{"sandbox":{"enabled":true,"excludedCommands":["git switch *","git add *","git commit *","git push *","gh pr *","git pull --ff-only","git fetch --prune"]}}'
settings "$ON"

# A single command, excluded or not, passes
check 0 'git switch -c feat/x'
check 0 'git pull --ff-only'
check 0 'ls -la'
check 0 'echo a && echo b'
check 0 'cd src && ls | head'

# Chained to an excluded command: blocked
check 2 'git switch -c feat/x && git add -A'
check 2 'cd src && git add -A'
check 2 'git add -A; git commit -m x'
check 2 'git push | tail -1'
check 2 'ls || gh pr view 1'
check 2 $'git add -A\ngit commit -m x'
check 2 'git switch -c a && echo b'
check 2 'echo before && git pull --ff-only'

# Quotes, redirects and heredocs do not chain
check 0 'git commit -m "fix a && b; c | d"'
check 0 "git commit -m 'a && b'"
check 0 'git push origin feat/x 2>&1'
check 0 'git push origin feat/x &>/dev/null'
check 0 $'git commit -m "$(cat <<\'EOF\'\nfix: a && b\nEOF\n)"'
check 0 $'git commit -F - <<EOF\nmsg; git push\nEOF'
check 0 'git commit -m a \
  --no-verify-not-a-flag'

# Shapes that look like separators but are not: comments, ANSI-C quotes, command substitutions, clobber, arithmetic
check 0 'git push # a && b'
check 0 "git commit -m \$'it\\'s a && b'"
check 0 'git commit -m "$(echo "a && b")"'
check 0 $'git commit -m "$(cat <<\'EOF\'\nsay 5" hi\nEOF\n)"'
check 0 'git commit -m $(date; echo x)'
check 0 'git commit -m `date; echo x`'
check 0 'git add x >| out'
check 0 'git add $((1 + 2)) y'
# A chain after a command substitution is still found
check 2 'git commit -m "$(date)" && git push'
check 2 'git add $((1<<x)) y
git commit -m x'

# Pattern forms: a bare command and the "prefix:*" form
settings '{"sandbox":{"enabled":true,"excludedCommands":["git push:*","git"]}}'
check 2 'git push origin x && ls'
check 0 'git status && ls'   # a bare "git" pattern matches only the bare command
settings "$ON"

# Not excluded by any pattern: chained is fine
check 0 'git status && git diff'
check 0 'git log | head -3'

# The sandbox is off or has no excluded commands: nothing to warn about
settings '{"sandbox":{"enabled":false,"excludedCommands":["git add *"]}}'
check 0 'git add -A && git commit -m x'
settings '{"sandbox":{"enabled":true}}'
check 0 'git add -A && git commit -m x'
settings '{}'
check 0 'git add -A && git commit -m x'

# A later settings file can switch the sandbox off again (false is a value, not "unset")
settings "$ON" '{"sandbox":{"enabled":false}}'
check 0 'git add -A && git commit -m x'
settings '{"sandbox":{"enabled":false,"excludedCommands":["git add *"]}}' '{"sandbox":{"enabled":true}}'
check 2 'git add -A && ls'

# Project settings are read too
settings '{"sandbox":{"enabled":true}}' '{"sandbox":{"excludedCommands":["terraform plan *"]}}'
check 2 'cd infra && terraform plan -out=x'
check 0 'terraform plan -out=x'

# Broken settings and broken input never block
settings 'not json'
check 0 'git add -A && git commit -m x'
n=$((n + 1))
printf 'not json' | HOME="$home" CLAUDE_PROJECT_DIR="$proj" bash "$hook" >/dev/null 2>&1 || ng "invalid input was not passed"

if [ "$fail" = 0 ]; then echo "all $n chain checks passed"; else exit 1; fi
