#!/bin/bash
# Development hook for this repository (not part of the plugin): a pull request is created only after the
# doc-code-consistency skill has checked the commit being proposed.
#   doc-check.sh record   PostToolUse(Skill): after doc-code-consistency runs, record HEAD
#   doc-check.sh gate     PreToolUse(Bash|mcp__.*): block gh pr create / an MCP create_pull_request when the branch head
#                         is not the recorded commit (no check yet, or commits added after it)
# The record is a file under the git directory. This is a reminder for Claude, not enforcement: the file can be written by hand.
set -uo pipefail

mode="${1:-}"
input="$(cat)"
command -v jq >/dev/null 2>&1 || { echo "BLOCKED by doc-check.sh: jq was not found." >&2; exit 2; }
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
git_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0
state="$git_dir/code-guard-doc-check"

case "$mode" in
  record)
    skill="$(jq -r '.tool_input.skill // ""' <<<"$input")"
    if [[ "$skill" =~ (^|:)doc-code-consistency$ ]]; then
      git rev-parse -q --verify HEAD >"$state" 2>/dev/null || rm -f "$state"
    fi
    exit 0
    ;;
  gate)
    tool="$(jq -r '.tool_name // ""' <<<"$input")"
    head=""
    if [ "$tool" = Bash ]; then
      cmd="$(jq -r '.tool_input.command // ""' <<<"$input")"
      grep -Eq '(^|[[:space:];&|(])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' <<<"$cmd" || exit 0
      head="$(perl -ne 'if (/\bpr\s+create\b.*?\s(?:--head|-H)(?:=|\s+)(["\x27]?)([^\s"\x27;&|]+)\1/) { print $2; exit }' <<<"$cmd")"
    elif [[ "$tool" =~ (^|_)create_pull_request$ ]]; then
      head="$(jq -r '.tool_input.head // ""' <<<"$input")"
      head="${head##*:}"
    else
      exit 0
    fi
    # The commit the pull request would propose: the named head branch (local, else origin/), else HEAD
    if [ -n "$head" ]; then
      sha="$(git rev-parse -q --verify "refs/heads/$head^{commit}" 2>/dev/null || git rev-parse -q --verify "refs/remotes/origin/$head^{commit}" 2>/dev/null)"
    else
      sha="$(git rev-parse -q --verify HEAD 2>/dev/null)"
    fi
    recorded="$(cat "$state" 2>/dev/null || true)"
    if [ -z "$sha" ] || [ "$sha" != "$recorded" ]; then
      echo "BLOCKED by doc-check.sh: run the doc-code-consistency skill on this branch before creating the pull request." >&2
      if [ -z "$recorded" ]; then
        echo "No check is recorded for this repository." >&2
      else
        echo "The last check was on ${recorded:0:7}; the branch head is ${sha:0:7}. Check again after the latest commits." >&2
      fi
      echo "Scope: the claims in the changed lines of the branch diff, and existing text that mentions the changed code. Fix any mismatch, check again, then create the pull request." >&2
      exit 2
    fi
    exit 0
    ;;
esac
exit 0
