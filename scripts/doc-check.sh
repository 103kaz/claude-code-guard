#!/bin/bash
# code-guard: run /code-guard:doc-code-consistency before a pull request (userConfig doc_check_before_pr, default off).
#   doc-check.sh record   PostToolUse(Skill): after /code-guard:doc-code-consistency starts, record the repository's HEAD
#   doc-check.sh record-prompt   UserPromptSubmit: the same record when the user types /code-guard:doc-code-consistency
#   doc-check.sh gate    PreToolUse(Bash|mcp__.*): block gh pr create / an MCP create_pull_request when the head of the
#                         branch being proposed is not the recorded commit (no check yet, or commits after it)
# The record is kept per repository under the plugin data directory. This is a reminder for Claude, not enforcement:
# the record is written when the skill starts, whatever the check finds.
# When you change this, add cases to tests/test-doc-check.sh and run it.
set -uo pipefail

# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/lib/common.sh" || { echo "BLOCKED by code-guard: cannot load lib/common.sh; blocking everything this hook covers." >&2; exit 2; }
[ "$(opt_bool DOC_CHECK_BEFORE_PR false)" = true ] || exit 0
need_cmd jq perl

mode="${1:-}"
input="$(cat)"
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
git_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0
git_dir="$(cd "$git_dir" 2>/dev/null && pwd -P)" || exit 0
state_dir="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/code-guard}/doc-check"
state="$state_dir/$(printf '%s' "$git_dir" | cksum | tr -c '0-9\n' '_' | head -n 1)"

case "$mode" in
  record)
    skill="$(jq -r '.tool_input.skill // ""' <<<"$input")"
    # Only the bundled skill counts (a personal skill of the same name may have other steps)
    if [ "$skill" = "code-guard:doc-code-consistency" ]; then
      mkdir -p "$state_dir" 2>/dev/null
      git rev-parse -q --verify HEAD >"$state" 2>/dev/null || rm -f "$state"
    fi
    exit 0
    ;;
  record-prompt)
    # A slash command typed by the user does not go through the Skill tool, so PostToolUse(Skill) never sees it
    prompt="$(jq -r '.prompt // ""' <<<"$input")"
    if [[ "$prompt" =~ ^[[:space:]]*/code-guard:doc-code-consistency([[:space:]]|$) ]]; then
      mkdir -p "$state_dir" 2>/dev/null
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
      if [ -z "$recorded" ]; then
        why="No check is recorded for this repository."
      else
        why="The last check was on ${recorded:0:7}; the branch head is ${sha:0:7}. Check again after the latest commits."
      fi
      block "run /code-guard:doc-code-consistency on this branch before creating the pull request (doc_check_before_pr is on). $why Scope: the claims in the changed lines of the branch diff, and existing text that mentions the changed code. Fix any mismatch, check again, then create the pull request."
    fi
    exit 0
    ;;
esac
exit 0
