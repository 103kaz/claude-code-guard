#!/bin/bash
# Regression test for scripts/check-enabled.sh. Run it after changing the check.
set -uo pipefail
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
hook="$SCRIPTS/check-enabled.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-check-enabled.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0
n=0
ng() { echo "FAIL: $1"; fail=1; }

# run <project dir>: result goes to RC / OUT / ERR
run() {
  n=$((n + 1))
  OUT="$(CLAUDE_PROJECT_DIR="$1" bash "$hook" 2>"$tmp/err" </dev/null)"
  RC=$?
  ERR="$(cat "$tmp/err")"
}
# proj <name> <file> <json>: a project whose settings file holds the JSON
proj() {
  mkdir -p "$tmp/$1/.claude"
  printf '%s\n' "$3" >"$tmp/$1/.claude/$2"
}
quiet() { [ "$RC" = 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] || ng "$1 (rc=$RC out=$OUT err=$ERR)"; }
warns() { [ "$RC" = 0 ] || ng "$1: exit $RC (a warning must not fail the session)"; grep -q 'code-guard' <<<"$OUT" && grep -q 'systemMessage' <<<"$OUT" || ng "$1: no warning (out=$OUT)"; }

# No settings: silent
mkdir -p "$tmp/none"; run "$tmp/none"; quiet "spoke with no settings"

# Switched off in the project settings / the local settings: warn the user and the context
proj off settings.json '{"enabledPlugins":{"code-guard@claude-code-guard":false}}'
run "$tmp/off"; warns "project settings switch it off"
jq -e '.hookSpecificOutput.hookEventName == "SessionStart" and (.hookSpecificOutput.additionalContext | length > 0)' <<<"$OUT" >/dev/null 2>&1 || ng "the warning is not valid SessionStart output (out=$OUT)"

proj offlocal settings.local.json '{"enabledPlugins":{"code-guard@some-other-marketplace":false}}'
run "$tmp/offlocal"; warns "local settings switch it off (another marketplace name)"

# Every hook switched off by the project settings is the same hole
proj nohooks settings.json '{"disableAllHooks":true}'
run "$tmp/nohooks"; warns "disableAllHooks"
proj hooksok settings.json '{"disableAllHooks":false}'
run "$tmp/hooksok"; quiet "spoke although hooks are not disabled"

# Enabled, other plugins off, or no enabledPlugins: silent
proj on settings.json '{"enabledPlugins":{"code-guard@claude-code-guard":true}}'
run "$tmp/on"; quiet "spoke although it is enabled"
proj other settings.json '{"enabledPlugins":{"other-plugin@x":false}}'
run "$tmp/other"; quiet "spoke about another plugin"
proj similar settings.json '{"enabledPlugins":{"code-guard-extra@x":false}}'
run "$tmp/similar"; quiet "matched a plugin whose name only starts with code-guard"
proj noplugins settings.json '{"permissions":{}}'
run "$tmp/noplugins"; quiet "spoke without enabledPlugins"

# Unreadable settings: silent (this is a warning aid, not a guard)
proj broken settings.json '{not json'
run "$tmp/broken"; quiet "spoke on broken JSON"

if [ "$fail" = 0 ]; then echo "all $n check-enabled checks passed"; fi
exit "$fail"
