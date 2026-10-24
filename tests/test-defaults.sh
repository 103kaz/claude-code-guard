#!/bin/bash
# Regression test: the default of every userConfig option in .claude-plugin/plugin.json must be what the hooks do when the
# option is not set. Claude Code does not pass the default of an option that is not set (checked on 2.1.306 for a multiple
# option: tests/manual-check-multiple.sh), so each hook's own default decides, and the two must not drift apart.
# When you add or change an option, add its check here.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$ROOT/.claude-plugin/plugin.json"
command -v jq >/dev/null 2>&1 || { echo "SKIP: this test needs jq."; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-defaults.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0
n=0
ng() { echo "FAIL: $1"; fail=1; }

# No option set: the hooks must run on their own defaults
for v in $(compgen -e | grep '^CLAUDE_PLUGIN_OPTION_'); do unset "$v"; done

# same <key> <what the hook does> <what plugin.json declares>
same() {
  n=$((n + 1))
  [ "$2" = "$3" ] || ng "$1: the hook's default is [$2] but plugin.json declares [$3]"
}
manifest_default() { jq -c ".userConfig.$1.default" "$manifest"; }

keys="$(jq -r '.userConfig | keys[]' "$manifest")"
for key in $keys; do
  decl="$(manifest_default "$key")"
  case "$key" in
    protected_branches)
      got="$(bash -c ". '$ROOT/scripts/lib/common.sh'; printf '%s' \"\$PROTECTED_LIST\"")"
      same "$key" "$got" "$(jq -r ".userConfig.$key.default | join(\", \")" "$manifest")"
      ;;
    pack_*)
      pack="${key#pack_}"
      got="$(bash -c ". '$ROOT/scripts/lib/common.sh'; if pack_on '$pack'; then echo true; else echo false; fi")"
      same "$key" "$got" "$decl"
      ;;
    confirm_push)
      # A work-branch push asks when the option is on and passes when it is off
      out="$(cd "$tmp" && jq -nc '{tool_name:"Bash",tool_input:{command:"git push origin feat/x"}}' | bash "$ROOT/scripts/guard-bash.sh" 2>/dev/null)"
      if grep -q '"permissionDecision": "ask"' <<<"$out"; then got=true; else got=false; fi
      same "$key" "$got" "$decl"
      ;;
    verify_max_retry)
      got="$(sed -n 's/^MAX_RETRY="\${CLAUDE_PLUGIN_OPTION_VERIFY_MAX_RETRY:-\([0-9]*\)}"$/\1/p' "$ROOT/scripts/verify-loop.sh")"
      same "$key (default)" "$got" "$decl"
      lo="$(sed -n 's/.*"\$MAX_RETRY" -ge \([0-9]*\) \].*/\1/p' "$ROOT/scripts/verify-loop.sh")"
      hi="$(sed -n 's/.*"\$MAX_RETRY" -le \([0-9]*\) \].*/\1/p' "$ROOT/scripts/verify-loop.sh")"
      same "$key (min)" "$lo" "$(jq -c ".userConfig.$key.min" "$manifest")"
      same "$key (max)" "$hi" "$(jq -c ".userConfig.$key.max" "$manifest")"
      ;;
    verify_missing_notice)
      # tests/test-verify.sh runs the hook with the variable unset and expects the notice, which is the default true
      same "$key" "true" "$decl"
      ;;
    *)
      ng "$key: no default check for this option. Add one to tests/test-defaults.sh"
      ;;
  esac
done

if [ "$fail" = 0 ]; then echo "all $n default checks passed"; else exit 1; fi
