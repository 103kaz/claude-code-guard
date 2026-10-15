#!/bin/bash
# code-guard: PreToolUse(Read|Grep|Edit|Write|MultiEdit|NotebookEdit) guard.
# Plugins cannot ship permissions deny / ask, so the file-tool rules live here.
#   Read, Grep                          block secret files
#   Edit, Write, MultiEdit, NotebookEdit  block *.tfvars, .git/config, .git/hooks; ask for the harness files
# Grep is stopped only when its path is a secret file. A directory search that returns secrets cannot be stopped.
# Paths are compared in lower case: macOS volumes are usually case-insensitive (.ENV is .env).
# When you change this, add cases to tests/test-guard.sh and run it.
set -uo pipefail

# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/lib/common.sh" || { echo "BLOCKED by code-guard: cannot load lib/common.sh; blocking everything this hook covers." >&2; exit 2; }
need_cmd jq

input="$(cat)"
tool="$(jq -er '.tool_name // ""' <<<"$input")" \
  || block "could not read the hook input (not valid JSON); blocking everything this hook covers"
path="$(jq -er '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // ""' <<<"$input")" \
  || block "could not read the hook input (not valid JSON); blocking everything this hook covers"
[ -n "$path" ] || exit 0

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Normalize ~ and lower-case so the patterns see one form
path="${path/#\~/$HOME}"
path_l="$(lower "$path")"
home_l="$(lower "$HOME")"

is_secret() {
  local p="$1" f
  # Samples are fine
  case "$p" in *.env.example|*.env.sample|*.env.template|*.tfvars.example|*.tfvars.sample) return 1 ;; esac
  grep -Eqi "$SECRET_PATH_RE" <<<"$p" && return 0
  for f in $HOME_SECRET_FILES; do
    [ "$p" = "$home_l/$f" ] && return 0
  done
  return 1
}

case "$tool" in
  Read|Grep)
    if is_secret "$path_l"; then
      block "reading secret files (.env, *.tfvars, keys, CLI credentials) is not allowed: $path"
    fi
    ;;
  Edit|Write|MultiEdit|NotebookEdit)
    if grep -Eq '\.tfvars$|(^|/)\.git/(config|config\.worktree|hooks/)|(^|/)\.git/modules/[^/]+/(config|config\.worktree|hooks/)|(^|/)\.git/worktrees/[^/]+/config\.worktree$' <<<"$path_l"; then
      block "editing $path is not allowed (.tfvars, .git/config, .git/hooks)"
    fi
    if [[ "$path_l" == "$home_l/.claude/"* ]] \
       || grep -Eq '(^|/)\.claude/(settings[^/]*|hooks/.*|verify\.sh)$|(^|/)\.githooks/|(^|/)\.github/workflows/' <<<"$path_l"; then
      ask "editing $path (harness or CI file). Confirm the user has OKed this change in chat before approving"
    fi
    ;;
esac

exit 0
