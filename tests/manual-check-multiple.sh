#!/bin/bash
# Manual check, not run by CI: in what shape does Claude Code pass a userConfig option with "multiple": true to a hook?
# scripts/lib/common.sh reads CLAUDE_PLUGIN_OPTION_PROTECTED_BRANCHES as a JSON array or as a comma / space separated list.
# This script prints the value a hook actually receives, so that the real shape can be written down.
# It runs `claude -p` against a throwaway plugin, so it needs a logged-in claude, network access and a few short model calls.
# Run it from a terminal, not from inside a sandboxed session.
#   bash tests/manual-check-multiple.sh
set -uo pipefail

command -v claude >/dev/null 2>&1 || { echo "claude was not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq was not found" >&2; exit 2; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/multiple.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
echo "Claude Code: $(claude --version)"

# A plugin with one multiple option and a UserPromptSubmit hook that writes the option's raw value to a file
p="$tmp/multicheck"
mkdir -p "$p/.claude-plugin" "$p/hooks"
cat > "$p/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "multicheck",
  "version": "0.0.1",
  "description": "shape of a multiple userConfig option",
  "userConfig": {
    "branches": { "type": "string", "multiple": true, "title": "Branches", "description": "check", "default": ["dflt-a", "dflt-b"] }
  }
}
EOF
cat > "$p/hooks/hook.sh" <<'EOF'
#!/bin/bash
# $1: file to write. Writes the raw value, or <unset> when the variable does not exist, with no trailing newline
printf '%s' "${CLAUDE_PLUGIN_OPTION_BRANCHES-<unset>}" > "$1"
EOF
cat > "$p/hooks/hooks.json" <<EOF
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash \"\${CLAUDE_PLUGIN_ROOT}/hooks/hook.sh\" \"$tmp/value\""}]}]}}
EOF

# probe <label> <settings-json>: run claude -p with the settings and print what the hook received
probe() {
  local label="$1" settings="$2" raw
  rm -f "$tmp/value"
  (cd "$tmp" && claude -p "Reply with the single word ok." --plugin-dir "$p" --settings "$settings" >"$tmp/out" 2>&1)
  if [ -e "$tmp/value" ]; then
    raw="$(cat -v "$tmp/value")"
    printf '%-34s -> received: [%s]\n' "$label" "$raw"
  else
    printf '%-34s -> the hook did not run (see below)\n' "$label"
    sed 's/^/      | /' "$tmp/out" | tail -n 8
  fi
}

# The plugin id of a --plugin-dir plugin is not documented, so both likely spellings are tried
for id in "multicheck@inline" "multicheck"; do
  echo "--- pluginConfigs key: $id"
  probe "no setting (the default)"       '{}'
  probe 'two values ["main","release/*"]' "{\"pluginConfigs\":{\"$id\":{\"options\":{\"branches\":[\"main\",\"release/*\"]}}}}"
  probe 'one value ["main"]'              "{\"pluginConfigs\":{\"$id\":{\"options\":{\"branches\":[\"main\"]}}}}"
  probe 'empty list []'                   "{\"pluginConfigs\":{\"$id\":{\"options\":{\"branches\":[]}}}}"
  probe 'a value with a space ["a b","c"]' "{\"pluginConfigs\":{\"$id\":{\"options\":{\"branches\":[\"a b\",\"c\"]}}}}"
done
echo
echo "Read the lines above: a value that differs from the default (dflt-a, dflt-b) shows the key was applied."
echo "If every line shows only the default, --settings did not carry pluginConfigs; tell the maintainer."
