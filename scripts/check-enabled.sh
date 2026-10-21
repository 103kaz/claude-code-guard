#!/bin/bash
# code-guard: warn when a project's settings switch code-guard off (enabledPlugins false, or disableAllHooks true).
# The plugin cannot run this itself: a plugin that is switched off runs no hooks. Register it as a SessionStart hook in the
# user's own settings (~/.claude/settings.json), outside the plugin. See "A repository can switch the plugin off" in the README.
# Prints a systemMessage (for the user) and additionalContext (for Claude) only when a project settings file disables it. Never blocks.
# When you change this, add cases to tests/test-check-enabled.sh and run it.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0

for f in .claude/settings.json .claude/settings.local.json; do
  [ -f "$f" ] || continue
  why=""
  if jq -e '(.enabledPlugins // {}) | to_entries | any((.key | test("^code-guard@")) and .value == false)' "$f" >/dev/null 2>&1; then
    why="switched off by $f in this project (enabledPlugins)"
  elif jq -e '.disableAllHooks == true' "$f" >/dev/null 2>&1; then
    why="disabled together with every other hook by disableAllHooks in $f"
  fi
  if [ -n "$why" ]; then
    msg="code-guard is $why, so none of its guards or its verify loop will run here. Remove that entry, or treat this repository as unguarded."
    jq -n --arg m "$msg" '{systemMessage: $m, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
    exit 0
  fi
done
exit 0
