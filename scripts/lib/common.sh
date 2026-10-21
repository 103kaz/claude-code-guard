#!/bin/bash
# code-guard: shared helpers for the guard hooks. Source this file; do not run it.

# set -u hooks must not die on an unset HOME (exit 1 is a non-blocking error)
HOME="${HOME:-/nonexistent-home}"

# need_cmd <command>...: if any command is missing, block everything this hook covers (when unsure, stop).
need_cmd() {
  local c
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      echo "BLOCKED by code-guard: '$c' was not found, so the guard cannot read tool input and blocks everything it covers." >&2
      echo "Ask the user to install $c (macOS: brew install $c; Debian/Ubuntu: apt install $c)." >&2
      exit 2
    fi
  done
}

# block <reason>: stop the operation (exit 2) and return the reason to Claude.
block() {
  echo "BLOCKED by code-guard: $1" >&2
  echo "This is a policy block, not a hook failure. Do not retry it another way (another command, a script, python). Tell the user why it was blocked and give them the command to run themselves." >&2
  exit 2
}

# ask <reason>: show a confirmation to the user.
ask() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
  exit 0
}

# opt_bool <KEY> <default true|false>: read CLAUDE_PLUGIN_OPTION_<KEY>. Unreadable or invalid values use the default.
opt_bool() {
  local v
  eval "v=\"\${CLAUDE_PLUGIN_OPTION_$1:-}\""
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) echo true ;;
    false|0|no|off) echo false ;;
    *) echo "$2" ;;
  esac
}

# pack_on <name>: 0 when the pack is enabled (default enabled).
pack_on() {
  [ "$(opt_bool "PACK_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" true)" = true ]
}

# Protected branches: CLAUDE_PLUGIN_OPTION_PROTECTED_BRANCHES as a JSON array, or comma / space separated. Default main, master.
_pb="$(printf '%s' "${CLAUDE_PLUGIN_OPTION_PROTECTED_BRANCHES:-}" | tr -d '[]"' | tr ',' ' ')"
PROTECTED_LIST=""
set -f   # no glob expansion of the words below
for _b in $_pb; do
  # only plain branch-name characters and * (any run of them, as in release/*); anything else is ignored
  case "$_b" in *[!A-Za-z0-9._/*-]*|'') continue ;; esac
  PROTECTED_LIST="${PROTECTED_LIST:+$PROTECTED_LIST, }$_b"
done
set +f
[ -n "$PROTECTED_LIST" ] || PROTECTED_LIST="main, master"
PROTECTED_RE="$(printf '%s' "$PROTECTED_LIST" | sed -E 's/, /|/g; s/\./\\./g; s/\*/[A-Za-z0-9._\/-]*/g')"
unset _pb _b

# is_protected_branch <name>
is_protected_branch() {
  [ -n "$1" ] && grep -Eqx "$PROTECTED_RE" <<<"$1"
}

# secret_path_re: file paths the file-tool guard treats as secrets (grep -E, matched against the whole path).
# shellcheck disable=SC2034
SECRET_PATH_RE='(^|/)(\.env|\.env\.[A-Za-z0-9._-]+|\.dev\.vars(\.[A-Za-z0-9_-]+)?)$|\.tfvars(\.json)?$|\.tfstate(\.[A-Za-z0-9_-]+)?$|token[^/]*\.txt$|\.(pem|key|p8|p12|mobileprovision)$|(^|/)AuthKey_[^/]*$|firebase-adminsdk[^/]*\.json$|[Ss]ervice-?[Aa]ccount[^/]*\.json$|(^|/)\.ssh/|(^|/)\.aws/|(^|/)\.config/(gcloud|gh)/|(^|/)\.git-credentials$|(^|/)\.config/git/credentials$|(^|/)\.kube/|(^|/)\.docker/config\.json$'
# Home-level credential files; a project .npmrc (registry settings) is not covered
# shellcheck disable=SC2034
HOME_SECRET_FILES=".netrc .npmrc .pypirc"
