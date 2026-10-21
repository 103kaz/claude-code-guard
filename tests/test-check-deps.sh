#!/bin/bash
# Regression test for scripts/check-deps.sh. Run it after changing the dependency check.
set -uo pipefail
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
hook="$SCRIPTS/check-deps.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-check-deps.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0
# The cases below symlink the real jq and perl into a PATH directory, so the host must have them
for c in jq perl; do
  command -v "$c" >/dev/null 2>&1 || { echo "SKIP: this test needs '$c' on the host PATH to build its fake PATH."; exit 1; }
done
ng() { echo "FAIL: $1"; fail=1; }

# bin_with <dir> <command>...: a PATH directory holding only the named commands (symlinks to the real ones)
bin_with() {
  local d="$1" c p
  shift
  mkdir -p "$d"
  for c in "$@"; do
    p="$(command -v "$c")" && ln -s "$p" "$d/$c"
  done
}

# run_hook <path-dir>: result goes to RC / OUT (stdout) / ERR (stderr)
run_hook() {
  OUT="$(PATH="$1" "$BASH" "$hook" 2>"$tmp/hook.err" </dev/null)"
  RC=$?
  ERR="$(cat "$tmp/hook.err")"
}

# Both present: do nothing and say nothing
bin_with "$tmp/both" jq perl
run_hook "$tmp/both"
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] || ng "spoke or failed with jq and perl present (rc=$RC out=$OUT)"

# jq missing: say so, name only jq, never block (exit 0)
bin_with "$tmp/nojq" perl
run_hook "$tmp/nojq"
[ "$RC" = 0 ] || ng "jq missing: exit $RC (must not fail the session)"
case "$OUT" in *jq*) ;; *) ng "jq missing: jq not named: $OUT" ;; esac
case "$OUT" in *perl*) ng "jq missing: perl named although present: $OUT" ;; esac
case "$OUT" in *"brew install jq"*"apt install jq"*) ;; *) ng "jq missing: no install hint: $OUT" ;; esac

# perl missing
bin_with "$tmp/noperl" jq
run_hook "$tmp/noperl"
[ "$RC" = 0 ] || ng "perl missing: exit $RC"
case "$OUT" in *perl*) ;; *) ng "perl missing: perl not named: $OUT" ;; esac
case "$OUT" in *jq*) ng "perl missing: jq named although present: $OUT" ;; esac

# Both missing: both named in one message
mkdir -p "$tmp/none"
run_hook "$tmp/none"
[ "$RC" = 0 ] || ng "both missing: exit $RC"
case "$OUT" in *jq*perl* | *perl*jq*) ;; *) ng "both missing: not both named: $OUT" ;; esac

# hooks.json registers it on SessionStart
grep -q '"SessionStart"' "$SCRIPTS/../hooks/hooks.json" || ng "hooks.json has no SessionStart"
grep -q 'check-deps.sh' "$SCRIPTS/../hooks/hooks.json" || ng "hooks.json does not run check-deps.sh"

[ "$fail" = 0 ] && echo "all test-check-deps cases passed" || exit 1
