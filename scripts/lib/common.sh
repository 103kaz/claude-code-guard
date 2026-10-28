#!/bin/bash
# code-guard: shared helpers for the guard hooks. Source this file; do not run it.

# set -u hooks must not die on an unset HOME (exit 1 is a non-blocking error)
HOME="${HOME:-/nonexistent-home}"

# norm_path <path>: ~ expanded, // and /./ folded, dir/.. dropped (~//.netrc and ~/x/../.netrc are ~/.netrc). Symlinks are not resolved
norm_path() {
  sed -E -e ':a' -e 's#/\./#/#g; s#//+#/#g; s#/[^/]+/\.\./#/#; ta' <<<"${1/#\~/$HOME}"
}

# claude_config_dirs: the directory CLAUDE_CONFIG_DIR moves the user's settings and plugins to, one per line: as written
# (absolute, normalized, no trailing /) and, when it exists and differs, its real path (a symlink; /tmp is /private/tmp on
# macOS). Fails when the variable is not set. ~/.claude is protected whether or not it is set.
claude_config_dirs() {
  local d="${CLAUDE_CONFIG_DIR:-}" r
  [ -n "$d" ] || return 1
  # shellcheck disable=SC2088 # a literal ~ (a value from a settings env block is not expanded by a shell)
  case "$d" in /*|'~'|'~/'*) ;; *) d="$PWD/$d" ;; esac
  d="$(norm_path "$d")"
  d="${d%/}"
  [ -n "$d" ] || return 1
  printf '%s\n' "$d"
  if r="$(cd -P "$d" 2>/dev/null && pwd -P)" && [ "$r" != "$d" ]; then printf '%s\n' "$r"; fi
  return 0
}

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

# Protected branches: CLAUDE_PLUGIN_OPTION_PROTECTED_BRANCHES. Claude Code passes a multiple option as one string with the values
# joined by commas (main,release/*; checked with tests/manual-check-multiple.sh). An option that is not set has no variable and
# an empty list is an empty string; both give the default, main, master. A JSON array and a space separated list are read too.
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
