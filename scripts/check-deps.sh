#!/bin/bash
# code-guard: SessionStart. Say which of jq / perl is missing, before the guards block everything they cover.
# Prints nothing when both are present (stdout of SessionStart goes into the context). Never blocks: exit 0.
# Uses only shell builtins, because jq or perl may be the missing one.
# When you change this, add cases to tests/test-check-deps.sh and run it.
set -uo pipefail

missing=""
for c in jq perl; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
[ -z "$missing" ] && exit 0

printf 'code-guard: not found:%s. The guards need them to read tool input, and block everything they cover until they are installed. Tell the user to install them (macOS: brew install%s; Debian/Ubuntu: apt install%s).\n' "$missing" "$missing" "$missing"
exit 0
