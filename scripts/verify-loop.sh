#!/bin/bash
# code-guard: verify loop. Called from two hooks.
#   verify-loop.sh mark   UserPromptSubmit: record the working tree state at the start of the turn and reset the failure count
#   verify-loop.sh        Stop: when the tree changed since the start of the turn, run the project's .claude/verify.sh.
#                         On failure, exit 2 with the output on stderr so Claude fixes it
#
# - "Changed" compares a fingerprint of HEAD, tracked diffs and untracked files. Commits made in the turn count;
#   changes that were already there (not made by Claude) do not. Without a mark, run when the tree has changes.
#   Outside git, a file modified after the mark counts; without a mark it runs
# - Stops at most VERIFY_MAX_RETRY times in one turn (userConfig verify_max_retry, default 3). The last round tells Claude to
#   report to the user if it cannot fix it. If it still fails the user is told through systemMessage and the stop passes
# - No .claude/verify.sh: do nothing, say nothing
# - A self-reporting aid, not enforcement
set -uo pipefail

MAX_RETRY="${CLAUDE_PLUGIN_OPTION_VERIFY_MAX_RETRY:-3}"
case "$MAX_RETRY" in ''|*[!0-9]*) MAX_RETRY=3 ;; esac
{ [ "$MAX_RETRY" -ge 1 ] && [ "$MAX_RETRY" -le 10 ]; } || MAX_RETRY=3
TIMEOUT_SEC="${CODE_GUARD_VERIFY_TIMEOUT:-600}"   # the override exists for tests
case "$TIMEOUT_SEC" in ''|*[!0-9]*) TIMEOUT_SEC=600 ;; esac
TIMEOUT_SEC=$((10#$TIMEOUT_SEC))
[ "$TIMEOUT_SEC" -ge 1 ] || TIMEOUT_SEC=600
mode="${1:-stop}"

input="$(cat)"
session="$(jq -r '.session_id // "nosession"' <<<"$input" 2>/dev/null || echo nosession)"
root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$root" || exit 0

state_dir="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/code-guard}/verify"
mkdir -p "$state_dir" 2>/dev/null || state_dir="${TMPDIR:-/tmp}/code-guard-verify" && mkdir -p "$state_dir"
key="$(printf '%s' "$session" | tr -c 'A-Za-z0-9_-' '_')"
count_file="$state_dir/$key.count"
mark_file="$state_dir/$key.mark"

in_git() { git rev-parse --git-dir >/dev/null 2>&1; }

# Fingerprint of the working tree: HEAD, tracked diffs, untracked files (name and content)
fingerprint() {
  {
    git rev-parse -q --verify HEAD 2>/dev/null
    # With no commit yet there is no HEAD to diff against: take the index and the working tree separately
    if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
      git diff HEAD --binary 2>/dev/null
    else
      git diff --cached --binary 2>/dev/null
      git diff --binary 2>/dev/null
    fi
    git ls-files -o --exclude-standard -z 2>/dev/null | while IFS= read -r -d '' f; do
      printf '%s ' "$f"
      git hash-object -- "$f" 2>/dev/null
    done
  } | git hash-object --stdin
}

# Notice shown to the user (not passed to Claude)
system_message() {
  if command -v jq >/dev/null; then
    jq -n --arg m "$1" '{systemMessage: $m}'
  else
    echo "$1" >&2
  fi
}

if [ "$mode" = mark ]; then
  rm -f "$count_file"
  # Outside git the mark is an empty file whose modification time is the start of the turn
  if in_git; then fingerprint >"$mark_file"; else rm -f "$mark_file"; : >"$mark_file"; fi
  exit 0
fi

verify="$root/.claude/verify.sh"
[ -f "$verify" ] || exit 0

# Do not verify when nothing changed since the start of the turn
if in_git; then
  if [ -f "$mark_file" ]; then
    [ "$(fingerprint)" != "$(cat "$mark_file")" ] || exit 0
  else
    [ -n "$(git status --porcelain 2>/dev/null)" ] || exit 0
  fi
elif [ -f "$mark_file" ]; then
  # Outside git: a file modified after the mark
  [ -n "$(find . -type f -newer "$mark_file" -not -path './.git/*' -print 2>/dev/null | head -n 1)" ] || exit 0
fi

# Run even when the execute bit is missing. Time out (perl alarm; timeout is missing on macOS) so a hung check cannot block the turn forever
run_verify() {
  # verify.sh runs in its own process group. On time-out the group gets TERM, then KILL after 2 seconds, so a child that
  # ignores TERM or a background process cannot keep the output pipe open. A leftover background process is killed on exit too
  perl -e 'my $pid = fork(); if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$pid; select(undef, undef, undef, 2); kill "KILL", -$pid;
      print "\ncode-guard: verify.sh was cut off after $ENV{CG_TIMEOUT} seconds.\n"; exit 124 };
    alarm $ENV{CG_TIMEOUT}; waitpid($pid, 0); my $st = $?; alarm 0; kill "KILL", -$pid;
    exit($st & 127 ? 128 + ($st & 127) : $st >> 8)' bash "$verify" 2>&1
}
out="$(CG_TIMEOUT="$TIMEOUT_SEC" run_verify)"
rc=$?

if [ "$rc" = 0 ]; then
  rm -f "$count_file"
  exit 0
fi

count="$(cat "$count_file" 2>/dev/null || true)"
case "$count" in ''|*[!0-9]*) count=0 ;; esac
count=$((count + 1))

if [ "$count" -gt "$MAX_RETRY" ]; then
  rm -f "$count_file"
  system_message "code-guard: .claude/verify.sh failed ${MAX_RETRY} times in a row and the turn was ended anyway."
  exit 0
fi
if ! { echo "$count" >"$count_file"; } 2>/dev/null; then
  # Cannot keep the count (unwritable state directory): stop here instead of looping forever
  system_message "code-guard: .claude/verify.sh failed but the retry count cannot be saved (state directory not writable), so the turn was ended without retries. Last output: $(tail -n 20 <<<"$out" | tail -c 1500)"
  exit 0
fi

{
  echo "code-guard verify loop: .claude/verify.sh failed (attempt ${count}/${MAX_RETRY}). Fix the cause before finishing."
  if [ "$count" = "$MAX_RETRY" ]; then
    echo "This is the last verification. If you cannot fix it, report the failing check and the remaining problem to the user, then finish."
  fi
  echo "--- output (last 80 lines, at most 6000 bytes) ---"
  tail -n 80 <<<"$out" | tail -c 6000
} >&2
exit 2
