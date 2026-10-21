#!/bin/bash
# Regression test for scripts/verify-loop.sh. Run it after changing the verify loop.
set -uo pipefail
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
hook="$SCRIPTS/verify-loop.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-verify.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
# On macOS /usr/bin/git is an xcrun shim. With HOME changed (below) it tries to write a cache outside the places the sandbox
# allows, and its error lands in the hook's stderr. Run the real git through a symlink found before HOME changes
if [ "$(uname)" = Darwin ]; then
  real_git="$(xcrun -f git 2>/dev/null)"
  if [ -x "$real_git" ]; then
    mkdir -p "$tmp/bin" && printf '#!/bin/bash\nexec "%s" "$@"\n' "$real_git" >"$tmp/bin/git" && chmod +x "$tmp/bin/git" && export PATH="$tmp/bin:$PATH"
  fi
fi
# The approvals are kept under $HOME, for both the hook and the user's terminal (where CLAUDE_PLUGIN_DATA is not set)
export HOME="$tmp/home"; mkdir -p "$HOME"
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
trust_script="$SCRIPTS/trust-verify.sh"
# trust_verify [answer]: the user's approval of the current .claude/verify.sh (the script asks on stdin)
trust_verify() { printf '%s\n' "${1:-yes}" | env -u CLAUDE_PLUGIN_DATA bash "$trust_script" "$repo" >"$tmp/trust.out" 2>&1; }
# set_verify writes the script and approves it; set_verify_untrusted only writes it
set_verify_untrusted() { printf '#!/bin/bash\n%s\n' "$1" >"$repo/.claude/verify.sh"; }
set_verify() { set_verify_untrusted "$1"; trust_verify; }
commit_all() { git -C "$repo" add -A && git -C "$repo" commit -qm "$1"; }

# No .claude/verify.sh: no failure, no stderr, no exit 2
echo a >"$repo/a.txt"
run_hook u1
[ "$RC" = 0 ] && [ -z "$ERR" ] || ng "acted without .claude/verify.sh (rc=$RC)"
rm -f "$repo/a.txt"

# No .claude/verify.sh and the tree changed in the turn: say how to make one, once per session (userConfig verify_missing_notice)
run_hook mn1 mark; run_hook mn1
[ "$RC" = 0 ] && [ -z "$OUT" ] || ng "said something with no .claude/verify.sh and no change"
echo a >"$repo/a.txt"
run_hook mn1
[ "$RC" = 0 ] && grep -q 'setup-verify' <<<"$OUT" || ng "no notice about the missing .claude/verify.sh after a change"
run_hook mn1; [ -z "$OUT" ] || ng "the missing verify.sh notice came twice in one session"
run_hook mn2 mark; echo b >>"$repo/a.txt"; run_hook mn2
grep -q 'setup-verify' <<<"$OUT" || ng "a new session did not get the missing verify.sh notice"
EXTRA_ENV="CLAUDE_PLUGIN_OPTION_VERIFY_MISSING_NOTICE=false"
run_hook mn3 mark; echo c >>"$repo/a.txt"; run_hook mn3
[ "$RC" = 0 ] && [ -z "$OUT" ] || ng "verify_missing_notice=false still said something"
EXTRA_ENV="CLAUDE_PLUGIN_OPTION_VERIFY_MISSING_NOTICE=garbage"
run_hook mn4 mark; echo d >>"$repo/a.txt"; run_hook mn4
grep -q 'setup-verify' <<<"$OUT" || ng "an invalid verify_missing_notice did not fall back to true"
EXTRA_ENV=""
# The record of the notice cannot be written: say nothing (it would come back on every stop)
mkdir -p "$state"; chmod 555 "$state"
run_hook mn5 mark; echo e >>"$repo/a.txt"; run_hook mn5
[ "$RC" = 0 ] && [ -z "$OUT" ] || ng "the missing verify.sh notice was shown although its record cannot be written"
chmod 755 "$state"
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

# Outside git: run only when a file changed since the mark (not on every stop)
git_repo="$repo"
repo="$tmp/plain"
mkdir -p "$repo/.claude"
set_verify 'exit 1'
echo a >"$repo/a.txt"
run_hook ng1 mark; run_hook ng1
[ "$RC" = 0 ] || ng "ran verification outside git with no change (rc=$RC)"
sleep 1; echo b >>"$repo/a.txt"
run_hook ng1
[ "$RC" = 2 ] || ng "did not verify a change outside git (rc=$RC)"
# A rename and a delete keep the modification times but change the file list
echo c >"$repo/b.txt"
run_hook ng3 mark; mv "$repo/b.txt" "$repo/c.txt"; run_hook ng3
[ "$RC" = 2 ] || ng "did not verify a rename outside git (rc=$RC)"
run_hook ng4 mark; rm "$repo/c.txt"; run_hook ng4
[ "$RC" = 2 ] || ng "did not verify a delete outside git (rc=$RC)"
# Without a mark outside git, run (nothing to compare with)
run_hook ng2
[ "$RC" = 2 ] || ng "did not verify outside git without a mark (rc=$RC)"

# A repository with no commit yet: a change to a staged file is seen
repo="$tmp/nocommit"
git init -q -b main "$repo"
mkdir -p "$repo/.claude"
set_verify 'exit 1'
echo a >"$repo/s.txt"; git -C "$repo" add -A
run_hook nc1 mark
echo b >"$repo/s.txt"; git -C "$repo" add -A
run_hook nc1
[ "$RC" = 2 ] || ng "did not verify a re-staged change in a repository with no commit (rc=$RC)"
repo="$git_repo"

# --- Trust: a verify.sh runs only after the user approved its content ---
# A cloned repository's verify.sh must not run on its own: it is not run, and the user is told how to approve it
repo="$tmp/untrusted"
git init -q -b main "$repo"
git -C "$repo" config user.name t; git -C "$repo" config user.email t@t; git -C "$repo" config commit.gpgsign false
mkdir -p "$repo/.claude"
echo init >"$repo/README"
set_verify_untrusted "touch \"$tmp/ran-untrusted\"; exit 1"
git -C "$repo" add -A && git -C "$repo" commit -qm init
run_hook t1 mark; echo a >"$repo/a.txt"
run_hook t1
[ "$RC" = 0 ] || ng "an unapproved verify.sh stopped the turn (rc=$RC)"
[ ! -e "$tmp/ran-untrusted" ] || ng "an unapproved verify.sh was run"
grep -q 'systemMessage' <<<"$OUT" && grep -q 'trust-verify.sh' <<<"$OUT" || ng "the user was not told how to approve (out=$OUT)"
# Said once per session, not on every stop
run_hook t1
[ -z "$OUT" ] && [ -z "$ERR" ] || ng "the approval notice repeated in the same session"
[ ! -e "$tmp/ran-untrusted" ] || ng "an unapproved verify.sh was run on the second stop"
# Answering anything but yes does not approve
trust_verify no
run_hook t2 mark; echo b >>"$repo/a.txt"
run_hook t2
[ ! -e "$tmp/ran-untrusted" ] || ng "a refused approval still ran verify.sh"
# After approval it runs
trust_verify yes
run_hook t3 mark; echo c >>"$repo/a.txt"
run_hook t3
[ "$RC" = 2 ] && [ -e "$tmp/ran-untrusted" ] || ng "an approved verify.sh did not run (rc=$RC)"
# Changing the content takes the approval away
rm -f "$tmp/ran-untrusted"
printf '#!/bin/bash\ntouch "%s"; exit 1\n# changed\n' "$tmp/ran-untrusted" >"$repo/.claude/verify.sh"
run_hook t4 mark; echo d >>"$repo/a.txt"
run_hook t4
[ "$RC" = 0 ] && [ ! -e "$tmp/ran-untrusted" ] || ng "a changed verify.sh ran on the old approval (rc=$RC)"
grep -q 'trust-verify.sh' <<<"$OUT" || ng "no approval notice after the content changed"
# The approval belongs to the repository: another repository with the same content is not approved
repo2="$tmp/untrusted2"
git init -q -b main "$repo2"; mkdir -p "$repo2/.claude"
cp "$repo/.claude/verify.sh" "$repo2/.claude/verify.sh"
trust_verify yes
rm -f "$tmp/ran-untrusted"
repo_saved="$repo"; repo="$repo2"
run_hook t5 mark; echo e >"$repo2/e.txt"
run_hook t5
[ ! -e "$tmp/ran-untrusted" ] || ng "an approval for one repository ran another repository's verify.sh"
repo="$repo_saved"
# trust-verify.sh without a verify.sh fails
repo="$tmp/noverify"; mkdir -p "$repo"
trust_verify yes
[ $? -ne 0 ] || ng "trust-verify.sh succeeded with no .claude/verify.sh"
repo="$git_repo"

# The whole file is shown (no cut-off), and control characters are made visible, so what is approved is what was read
repo="$tmp/longfile"; mkdir -p "$repo/.claude"
{ echo '#!/bin/bash'; for i in $(seq 1 250); do echo "# filler $i"; done; echo 'echo LASTLINE-AFTER-250'; printf 'echo hidden\rshown\n'; } >"$repo/.claude/verify.sh"
trust_verify yes
grep -q 'LASTLINE-AFTER-250' "$tmp/trust.out" || ng "trust-verify.sh did not show the whole file"
grep -q '\^M' "$tmp/trust.out" || ng "trust-verify.sh printed a carriage return as is"

# Valid UTF-8 (Japanese comments) is shown as is. What can hide code (ESC, a bidi override, a zero-width space) and
# bytes that are not UTF-8 are still made visible
repo="$tmp/utf8file"; mkdir -p "$repo/.claude"
{ echo '#!/bin/bash'; echo '# 日本語のコメント'; printf 'echo a\033[2Jb\n'; printf 'echo \xe2\x80\xaeevil\n'; printf 'echo x\xe2\x80\x8by\n'; printf 'echo \xff\xfe\n'; printf 'echo p\xe3\x85\xa4q\n'; } >"$repo/.claude/verify.sh"
trust_verify yes
grep -q '日本語のコメント' "$tmp/trust.out" || ng "trust-verify.sh did not show valid UTF-8 as is"
grep -q '\^\[\[2J' "$tmp/trust.out" || ng "trust-verify.sh printed ESC as is"
grep -q 'U+202E' "$tmp/trust.out" || ng "trust-verify.sh did not make a bidi override visible"
grep -q 'U+200B' "$tmp/trust.out" || ng "trust-verify.sh did not make a zero-width space visible"
grep -q 'U+3164' "$tmp/trust.out" || ng "trust-verify.sh did not make a Hangul filler visible"
grep -q 'M-\^?' "$tmp/trust.out" || ng "trust-verify.sh did not make an invalid byte visible"
! grep -q $'\xe2\x80\xae' "$tmp/trust.out" || ng "trust-verify.sh printed a bidi override as is"

# Relative invocation from the scripts directory works (the lib is found without a slash in $0)
repo="$tmp/relative"; mkdir -p "$repo/.claude"; set_verify_untrusted 'exit 0'
( cd "$SCRIPTS" && printf 'yes\n' | env -u CLAUDE_PLUGIN_DATA bash trust-verify.sh "$repo" >"$tmp/trust.out" 2>&1 ) || ng "trust-verify.sh failed when run as bash trust-verify.sh"

# A symlink is not approved: its target can change without the hash of the link changing
repo="$tmp/symlink"; mkdir -p "$repo/.claude"
printf '#!/bin/bash\nexit 1\n' >"$tmp/target.sh"; ln -s "$tmp/target.sh" "$repo/.claude/verify.sh"
trust_verify yes
[ $? -ne 0 ] || ng "trust-verify.sh approved a symlinked verify.sh"
echo a >"$repo/a.txt"; git init -q -b main "$repo" 2>/dev/null
run_hook sl1 mark; echo b >>"$repo/a.txt"; run_hook sl1
[ "$RC" = 0 ] || ng "a symlinked verify.sh ran (rc=$RC)"

# The notice comes again in the same session when the content changes after it was shown (a silent skip would look like a pass)
repo="$tmp/renotice"; git init -q -b main "$repo"; mkdir -p "$repo/.claude"
set_verify_untrusted 'exit 1'
run_hook rn1 mark; echo a >"$repo/a.txt"; run_hook rn1
grep -q 'trust-verify.sh' <<<"$OUT" || ng "no first notice"
run_hook rn1; [ -z "$OUT" ] || ng "the same unapproved content was announced twice"
printf '#!/bin/bash\nexit 1\n# edited\n' >"$repo/.claude/verify.sh"
run_hook rn1
grep -q 'trust-verify.sh' <<<"$OUT" || ng "no new notice after the content changed in the same session"
repo="$git_repo"

if [ "$fail" = 0 ]; then echo "all $n verify loop checks passed"; fi
exit "$fail"
