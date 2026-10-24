#!/bin/bash
# Manual check, not run by CI: does Claude Code stop a tool call when a PreToolUse hook with "onFailure": "block" fails?
# It runs `claude -p` against throwaway plugins, so it needs a logged-in claude, network access and a few short model calls.
# Claude Code 2.1.295 or later. Run it from a terminal, not from inside a sandboxed session.
#   bash tests/manual-check-onfailure.sh
# Whether the tool call ran is read from a PostToolUse hook of the same throwaway plugin, which only fires after the tool
# ran and writes its file outside the Bash sandbox, so your own sandbox settings cannot make a run look like a block.
set -uo pipefail

command -v claude >/dev/null 2>&1 || { echo "claude was not found" >&2; exit 2; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/onfailure.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
echo "Claude Code: $(claude --version)"

# mkplugin <name> <hook-json>: a plugin with a PreToolUse(Bash) hook (the one under test) and a PostToolUse(Bash) hook
# that records "the tool call ran"
mkplugin() {
  local d="$tmp/$1"
  mkdir -p "$d/.claude-plugin" "$d/hooks"
  printf '{"name":"%s","version":"0.0.1","description":"onFailure check"}\n' "$1" > "$d/.claude-plugin/plugin.json"
  printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[%s]}],"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"touch %s"}]}]}}\n' \
    "$2" "$tmp/ran-$1" > "$d/hooks/hooks.json"
}

# run_case <name> <want: ran|blocked>: asks Claude to run a harmless echo; the PostToolUse file shows whether it ran
fail=0
run_case() {
  local name="$1" want="$2" file="$tmp/ran-$1" got
  # The prompt comes first: --allowedTools takes several values and would swallow a prompt placed after it
  (cd "$tmp" && claude -p "Use the Bash tool to run exactly this command and nothing else: echo onfailure-check-$name" \
    --plugin-dir "$tmp/$name" --allowedTools "Bash(echo *)" >"$tmp/out-$name" 2>&1)
  if [ -e "$file" ]; then got=ran; else got=blocked; fi
  if [ "$got" = "$want" ]; then
    echo "PASS  $name: $got"
  else
    echo "FAIL  $name: want $want, got $got. Output of claude -p:"
    sed 's/^/      | /' "$tmp/out-$name" | tail -n 25
    fail=1
  fi
}

mkplugin sanity   '{"type":"command","command":"exit 0"}'
mkplugin exit2    '{"type":"command","command":"exit 2"}'
mkplugin exit1_nb '{"type":"command","command":"exit 1"}'
mkplugin exit1_b  '{"type":"command","command":"exit 1","onFailure":"block"}'
mkplugin timeout  '{"type":"command","command":"sleep 5","timeout":1,"onFailure":"block"}'
mkplugin missing  '{"type":"command","command":"bash /nonexistent/code-guard-hook.sh","onFailure":"block"}'

# The first case proves the setup works at all: if the tool call does not run here, the other results mean nothing
run_case sanity ran
if [ "$fail" != 0 ]; then
  echo "The baseline did not run the tool call, so the rest is skipped." >&2
  exit 1
fi
run_case exit2    blocked   # exit 2 always blocks (the documented baseline)
run_case exit1_nb ran       # exit 1 without onFailure is a non-blocking error: the tool still runs
run_case exit1_b  blocked   # exit 1 with onFailure: block
run_case timeout  blocked   # a hook that times out
run_case missing  blocked   # a hook command that fails to run (exit 127)

[ "$fail" = 0 ] || exit 1
echo "all onFailure checks passed on $(claude --version)"
