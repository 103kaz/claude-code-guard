#!/bin/bash
# Regression test for scripts/verify-loop.sh. Run it after changing the verify loop.
set -uo pipefail
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
hook="$SCRIPTS/verify-loop.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-verify.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0
n=0
ng() { echo "FAIL: $1"; fail=1; }

repo="$tmp/repo"
state="$tmp/data/verify"
mkdir -p "$repo/.claude"
git init -q -b main "$repo"
git -C "$repo" config user.name t
git -C "$repo" config user.email t@t
git -C "$repo" config commit.gpgsign false
echo init >"$repo/README"
git -C "$repo" add -A && git -C "$repo" commit -qm init

# run_hook <session> [mark]: result goes to RC / OUT (stdout) / ERR (stderr)
run_hook() {
  n=$((n + 1))
  OUT="$(printf '{"session_id":"%s"}' "$1" | CLAUDE_PLUGIN_DATA="$tmp/data" CLAUDE_PROJECT_DIR="$repo" ${EXTRA_ENV:+env $EXTRA_ENV} bash "$hook" ${2:-} 2>"$tmp/hook.err")"
  RC=$?
  ERR="$(cat "$tmp/hook.err")"
}
set_verify() { printf '#!/bin/bash\n%s\n' "$1" >"$repo/.claude/verify.sh"; }
commit_all() { git -C "$repo" add -A && git -C "$repo" commit -qm "$1"; }

# No .claude/verify.sh: do nothing and say nothing
echo a >"$repo/a.txt"
run_hook u1
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] || ng "acted without .claude/verify.sh (rc=$RC)"
rm -f "$repo/a.txt"

set_verify 'exit 1'
commit_all verify

# Unchanged since the start of the turn: do not run
run_hook s1 mark; run_hook s1
[ "$RC" = 0 ] || ng "ran verification with no change"

# A commit made in the turn counts
run_hook s1 mark
echo c >"$repo/committed.txt"; commit_all committed
run_hook s1
[ "$RC" = 2 ] || ng "did not verify a change committed in the turn"

# Changes that were there before the turn do not run it; a change added in the turn does
echo pre >"$repo/pre-existing.txt"
run_hook s2 mark; run_hook s2
[ "$RC" = 0 ] || ng "stopped for a change that was there before the turn"
echo more >>"$repo/pre-existing.txt"
run_hook s2
[ "$RC" = 2 ] || ng "did not verify a change added in the turn"
rm -f "$repo/pre-existing.txt"

# Without a mark, run only when the tree has changes
run_hook s3
[ "$RC" = 0 ] || ng "ran without a mark and with a clean tree"
echo x >"$repo/change.txt"
run_hook s3
[ "$RC" = 2 ] || ng "did not verify with no mark and a changed tree"

# Stops up to 3 times in a turn, asks for a report on the last one, passes the 4th with a systemMessage
run_hook s4 mark
echo y >>"$repo/change.txt"
run_hook s4; [ "$RC" = 2 ] || ng "did not stop on a failed verification (1st)"
run_hook s4; [ "$RC" = 2 ] || ng "did not stop on a failed verification (2nd)"
run_hook s4; [ "$RC" = 2 ] || ng "did not stop on a failed verification (3rd)"
grep -q 'last verification' <<<"$ERR" || ng "the last round did not ask for a report"
run_hook s4; [ "$RC" = 0 ] || ng "did not pass on the 4th failure (infinite loop guard)"
grep -q 'systemMessage' <<<"$OUT" || ng "the user was not told the limit was exceeded"

# A new turn counts failures from 0 again
run_hook s5 mark; echo z >>"$repo/change.txt"
run_hook s5; run_hook s5
run_hook s5 mark; echo w >>"$repo/change.txt"
run_hook s5
grep -q 'attempt 1/3' <<<"$ERR" || ng "the failure count carried over to a new turn"

# Another session's count is separate
run_hook s6 mark; echo v >>"$repo/change.txt"
run_hook s6
grep -q 'attempt 1/3' <<<"$ERR" || ng "another session's count leaked in"

# A corrupt count file still stops
echo abc >"$state/s6.count"
run_hook s6
[ "$RC" = 2 ] || ng "a corrupt count file let the stop through"

# verify_max_retry from userConfig (1-10); invalid values fall back to 3
EXTRA_ENV="CLAUDE_PLUGIN_OPTION_VERIFY_MAX_RETRY=1"
run_hook m1 mark; echo m >>"$repo/change.txt"
run_hook m1; [ "$RC" = 2 ] || ng "max_retry=1: 1st did not stop"
grep -q 'attempt 1/1' <<<"$ERR" && grep -q 'last verification' <<<"$ERR" || ng "max_retry=1: wrong count or no last-round message"
run_hook m1; [ "$RC" = 0 ] || ng "max_retry=1: 2nd did not pass"
EXTRA_ENV="CLAUDE_PLUGIN_OPTION_VERIFY_MAX_RETRY=99"
run_hook m2 mark; echo q >>"$repo/change.txt"
run_hook m2
grep -q 'attempt 1/3' <<<"$ERR" || ng "an out-of-range max_retry did not fall back to 3"
EXTRA_ENV=""

# Run even without the execute bit
chmod -x "$repo/.claude/verify.sh"
run_hook s7
[ "$RC" = 2 ] || ng "skipped a verify.sh without the execute bit"

# Success passes; output is returned to Claude on failure
set_verify 'exit 0'
run_hook s7; [ "$RC" = 0 ] || ng "a successful verification did not pass"
set_verify 'echo "boom line" >&2; exit 1'
run_hook s8
grep -q 'boom line' <<<"$ERR" || ng "verification output was not returned to Claude"

# Time out
if true; then
  set_verify 'sleep 30'
  EXTRA_ENV="CODE_GUARD_VERIFY_TIMEOUT=1"
  run_hook t1 mark; echo t >>"$repo/change.txt"
  run_hook t1
  [ "$RC" = 2 ] && grep -q 'cut off' <<<"$ERR" || ng "a hung verify.sh was not cut off (rc=$RC)"
  EXTRA_ENV=""
fi

# A child that ignores TERM, or a background process, must not hold the turn past the time-out (plus the 2 second KILL grace)
for body in 'trap "" TERM; sleep 8' '( trap "" TERM; sleep 8 ) & wait'; do
  set_verify "$body"
  EXTRA_ENV="CODE_GUARD_VERIFY_TIMEOUT=1"
  run_hook to1 mark; echo "$RANDOM" >>"$repo/change.txt"
  start=$SECONDS
  run_hook to1
  took=$((SECONDS - start))
  [ "$RC" = 2 ] && grep -q 'cut off after 1 seconds' <<<"$ERR" || ng "time-out message missing or rc wrong (rc=$RC): $body"
  [ "$took" -le 6 ] || ng "time-out took ${took}s for: $body"
done
# A verify.sh that exits 124 by itself is not reported as a time-out; a leading zero in the setting is not "disabled"
set_verify 'exit 124'
EXTRA_ENV=""
run_hook to2 mark; echo "$RANDOM" >>"$repo/change.txt"
run_hook to2
grep -q 'cut off' <<<"$ERR" && ng "an own exit 124 was reported as a time-out"
set_verify 'sleep 4'
EXTRA_ENV="CODE_GUARD_VERIFY_TIMEOUT=01"
run_hook to3 mark; echo "$RANDOM" >>"$repo/change.txt"
run_hook to3
grep -q 'cut off after 1 seconds' <<<"$ERR" || ng "CODE_GUARD_VERIFY_TIMEOUT=01 did not time out"
EXTRA_ENV=""

# A verify.sh killed by a signal is a failure, not a success
set_verify 'kill -KILL $$'
run_hook k1 mark; echo k >>"$repo/change.txt"
run_hook k1
[ "$RC" = 2 ] || ng "a verify.sh killed by a signal passed (rc=$RC)"

# An unwritable state directory must not loop forever: pass with a notice
set_verify 'exit 1'
EXTRA_ENV="CLAUDE_PLUGIN_DATA=/dev/null/x TMPDIR=/dev/null/y"
run_hook w1
[ "$RC" = 0 ] && grep -q 'systemMessage' <<<"$OUT" || ng "an unwritable state directory kept stopping (rc=$RC)"
EXTRA_ENV=""

if [ "$fail" = 0 ]; then echo "all $n verify loop checks passed"; fi
exit "$fail"
