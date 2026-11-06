#!/bin/bash
# Regression test for scripts/guard-pr-title.sh (a gh pr title without a required prefix). Run it after changing the check.
set -uo pipefail
hook="$(cd "$(dirname "$0")/../scripts" && pwd)/guard-pr-title.sh"

fail=0
n=0
ng() { echo "FAIL: $1"; fail=1; }

# check <want 0|2> <prefixes option> <command>: RC is the hook's exit code
check() {
  n=$((n + 1))
  local want="$1" opt="$2" cmd="$3" rc
  jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' \
    | CLAUDE_PLUGIN_OPTION_PR_TITLE_PREFIXES="$opt" bash "$hook" >/dev/null 2>&1
  rc=$?
  [ "$rc" = "$want" ] || ng "want $want, got $rc (prefixes '$opt'): $cmd"
}

P='feat,fix,docs,refactor,test,chore'

# A title with a prefix passes
check 0 "$P" 'gh pr create --title "feat: add x" --body y'
check 0 "$P" "gh pr create --title 'fix: a b' --body y"
check 0 "$P" 'gh pr create -t "docs: x"'
check 0 "$P" 'gh pr create --title="chore: x"'
check 0 "$P" 'gh pr create --repo o/r --head b --base main --title "refactor: x" --body "b"'
check 0 "$P" 'gh pr create --title "fix(api): x"'
check 0 "$P" 'gh pr create --title "feat!: breaking"'
check 0 "$P" 'gh pr edit 12 --title "test: x"'
check 0 "$P" 'gh pr create --title "feat: 日本語のタイトル"'

# A title without one is stopped
check 2 "$P" 'gh pr create --title "add x" --body y'
check 2 "$P" "gh pr create --title 'Update README'"
check 2 "$P" 'gh pr create -t "x"'
check 2 "$P" 'gh pr create --title="x: y"'
check 2 "$P" 'gh pr create --title "feature: x"'
check 2 "$P" 'gh pr create --title "feat:x"'
check 2 "$P" 'gh pr create --title "Feat: x"'
check 2 "$P" 'gh pr edit 12 --title "x"'
check 2 "$P" 'gh pr create --repo o/r --head b --title "no prefix" --body "feat: in the body only"'
check 2 "$P" 'cd x && gh pr create --title "no prefix"'
check 2 "$P" $'gh pr create \\\n  --title "no prefix" \\\n  --body y'
check 2 "$P" 'gh pr create --title "chore, docs" --body y'

# Nothing to read: passes (no --title, a title built at run time, not a PR create/edit)
check 0 "$P" 'gh pr create --fill'
check 0 "$P" 'gh pr create --title "$(cat title.txt)" --body y'
check 0 "$P" 'gh pr create --title "$T"'
check 0 "$P" 'gh pr view 12'
check 0 "$P" 'gh pr merge 12'
check 0 "$P" 'gh issue create --title "no prefix"'
check 0 "$P" 'git commit -m "gh pr create --title x"'
check 0 "$P" 'echo "gh pr create --title x"'
check 0 "$P" 'gh pr create --title "unterminated'
check 0 "$P" 'ls -la'

# Mentioning the command is not running it: arguments, quoted text and heredoc bodies
check 0 "$P" 'echo gh pr create --title bad'
check 0 "$P" 'grep -n gh pr create --title x file'
check 0 "$P" $'git commit -F - <<EOF\nuse gh pr edit --title foo later\nEOF'
check 0 "$P" $'cat <<EOF\ngh pr create --title bad\nEOF'
check 0 "$P" $'cat <<-EOF\n\tgh pr create --title bad\n\tEOF'
check 0 "$P" 'man gh pr create --title bad'
# Prefixes that run the next word, and every command position, still count
check 2 "$P" 'GH_TOKEN=x gh pr create --title bad'
check 2 "$P" 'env GH_REPO=o/r gh pr create --title bad'
check 2 "$P" 'sudo gh pr create --title bad'
check 2 "$P" 'time gh pr create --title bad'
check 2 "$P" 'echo a; gh pr create --title bad'
check 2 "$P" 'echo a || gh pr create --title bad'
check 2 "$P" $'gh pr create --title "no prefix" --body "$(cat <<\'EOF\'\nbody\nEOF\n)"'
check 0 "$P" $'gh pr create --title "feat: x" --body "$(cat <<\'EOF\'\nbody\nEOF\n)"'

# The body or another command's --title is not the PR title
check 0 "$P" 'gh pr create --title "feat: x" --body "see --title no prefix"'
check 0 "$P" 'gh pr create --title "feat: x" && gh issue create --title "no prefix"'
check 0 "$P" $'gh pr create --title "feat: x" --body "$(cat <<\'EOF\'\n--title y\nEOF\n)"'

# The option: off when empty or unset, a custom list, a JSON array, invalid entries ignored
check 0 '' 'gh pr create --title "no prefix"'
n=$((n + 1))
jq -nc '{tool_name:"Bash",tool_input:{command:"gh pr create --title \"no prefix\""}}' | env -u CLAUDE_PLUGIN_OPTION_PR_TITLE_PREFIXES bash "$hook" >/dev/null 2>&1 \
  || ng "an unset option was not off"
check 0 'wip' 'gh pr create --title "wip: x"'
check 2 'wip' 'gh pr create --title "feat: x"'
check 2 '["feat","fix"]' 'gh pr create --title "docs: x"'
check 0 '["feat","fix"]' 'gh pr create --title "fix: x"'
check 0 'feat fix' 'gh pr create --title "fix: x"'
check 0 '.*' 'gh pr create --title "anything"'
check 2 'feat,.*' 'gh pr create --title "anything"'
check 0 'a|b,' 'gh pr create --title "anything"'

# A "<<WORD" inside quotes is text, not a heredoc: the title after it is still read
check 2 "$P" $'echo "<<EOF"\ngh pr create --title "bad title"'
check 2 "$P" $'echo \'<<EOF\'\ngh pr create --title "bad title"'
check 0 "$P" $'echo "<<EOF"\ngh pr create --title "feat: ok"'
# A heredoc in $( ) inside quotes still drops its body
check 0 "$P" $'gh pr create --title "feat: ok" --body "$(cat <<\'EOF\'\ngh pr create --title bad\nEOF\n)"'
check 0 "$P" $'cat <<EOF\ngh pr create --title bad\nEOF'
check 2 "$P" $'ls\ngh pr create --title "bad title"'
# A title that ends in ";" is still read
check 2 "$P" 'gh pr create --title="bad;" --body y'
check 0 "$P" 'gh pr create --title="feat: ok;" --body y'

# Broken input never blocks
n=$((n + 1))
printf 'not json' | CLAUDE_PLUGIN_OPTION_PR_TITLE_PREFIXES="$P" bash "$hook" >/dev/null 2>&1 || ng "invalid input was not passed"

if [ "$fail" = 0 ]; then echo "all $n pr-title checks passed"; else exit 1; fi
