#!/bin/bash
# Regression test for scripts/doc-check.sh (userConfig doc_check_before_pr). Run it after changing the check.
set -uo pipefail
hook="$(cd "$(dirname "$0")/../scripts" && pwd)/doc-check.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-doc-check.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0
n=0
ng() { echo "FAIL: $1"; fail=1; }

mkrepo() {
  git init -q -b main "$1"
  git -C "$1" config user.name t
  git -C "$1" config user.email t@t
  git -C "$1" config commit.gpgsign false
  git -C "$1" commit -q --allow-empty -m init
  git -C "$1" switch -q -c feat/x
  git -C "$1" commit -q --allow-empty -m change
}
repo="$tmp/repo"
mkrepo "$repo"
mkrepo "$tmp/other"

ON=true
# run <mode> <json> [repo]: exit code goes to RC, stderr to $tmp/err
run() {
  n=$((n + 1))
  printf '%s' "$2" | CLAUDE_PLUGIN_OPTION_DOC_CHECK_BEFORE_PR="$ON" CLAUDE_PLUGIN_DATA="$tmp/data" CLAUDE_PROJECT_DIR="${3:-$repo}" \
    bash "$hook" "$1" >/dev/null 2>"$tmp/err"
  RC=$?
}
bash_in() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
skill_in() { jq -nc --arg s "$1" '{tool_name:"Skill",tool_input:{skill:$s}}'; }

# Off (the default): nothing is gated or recorded
ON=""
run gate "$(bash_in 'gh pr create --title x')"
[ "$RC" = 0 ] || ng "gh pr create was blocked with the setting off (rc=$RC)"
run record "$(skill_in 'doc-code-consistency')"
[ -d "$tmp/data/doc-check" ] && ng "a check was recorded with the setting off"
ON=false
run gate "$(bash_in 'gh pr create --title x')"
[ "$RC" = 0 ] || ng "gh pr create was blocked with the setting false (rc=$RC)"
ON=true

# On, no check yet: gh pr create is blocked, other commands pass
run gate "$(bash_in 'gh pr create --title x --body y')"
[ "$RC" = 2 ] || ng "gh pr create passed with no check recorded (rc=$RC)"
grep -q 'doc-code-consistency' "$tmp/err" || ng "the block reason does not name the skill"
run gate "$(bash_in 'gh pr view 1')"
[ "$RC" = 0 ] || ng "gh pr view was blocked (rc=$RC)"
run gate "$(bash_in 'git push -u origin feat/x')"
[ "$RC" = 0 ] || ng "git push was blocked (rc=$RC)"

# Another skill does not count; doc-code-consistency (plain or plugin-scoped) does
run record "$(skill_in 'code-review')"
run gate "$(bash_in 'gh pr create')"
[ "$RC" = 2 ] || ng "another skill counted as the check (rc=$RC)"
run record "$(skill_in 'code-guard:doc-code-consistency')"
run gate "$(bash_in 'gh pr create --title x')"
[ "$RC" = 0 ] || ng "gh pr create was blocked right after the check (rc=$RC)"
run gate "$(bash_in 'git add -A && gh pr create --fill')"
[ "$RC" = 0 ] || ng "a chained gh pr create was blocked right after the check (rc=$RC)"

# The record is per repository
run gate "$(bash_in 'gh pr create')" "$tmp/other"
[ "$RC" = 2 ] || ng "a check in one repository counted for another (rc=$RC)"

# A commit after the check: check again
git -C "$repo" commit -q --allow-empty -m more
run gate "$(bash_in 'gh pr create')"
[ "$RC" = 2 ] || ng "gh pr create passed after a new commit (rc=$RC)"
grep -q 'Check again' "$tmp/err" || ng "the block reason does not ask to check again"
run record "$(skill_in 'doc-code-consistency')"
run gate "$(bash_in 'gh pr create')"
[ "$RC" = 0 ] || ng "a plain skill name did not count (rc=$RC)"

# --head names the branch being proposed, not the checked-out one
git -C "$repo" branch other main
run gate "$(bash_in 'gh pr create --head other --title x')"
[ "$RC" = 2 ] || ng "--head of an unchecked branch passed (rc=$RC)"
run gate "$(bash_in 'gh pr create --head=feat/x --title x')"
[ "$RC" = 0 ] || ng "--head of the checked branch was blocked (rc=$RC)"

# MCP: create_pull_request is gated the same way
run gate '{"tool_name":"mcp__github__create_pull_request","tool_input":{"head":"other","base":"main"}}'
[ "$RC" = 2 ] || ng "an MCP create_pull_request of an unchecked branch passed (rc=$RC)"
run gate '{"tool_name":"mcp__github__create_pull_request","tool_input":{"head":"o:feat/x","base":"main"}}'
[ "$RC" = 0 ] || ng "an MCP create_pull_request of the checked branch was blocked (rc=$RC)"
run gate '{"tool_name":"mcp__github__list_pull_requests","tool_input":{}}'
[ "$RC" = 0 ] || ng "another MCP tool was blocked (rc=$RC)"

# Outside git there is no branch to check: pass
mkdir -p "$tmp/plain"
run gate "$(bash_in 'gh pr create')" "$tmp/plain"
[ "$RC" = 0 ] || ng "gh pr create outside git was blocked (rc=$RC)"

if [ "$fail" = 0 ]; then echo "all $n doc-check checks passed"; fi
exit "$fail"
