#!/bin/bash
# code-guard: the user's approval of a project's .claude/verify.sh. Source this file; do not run it.
# A verify.sh from a cloned repository is code someone else wrote, so the verify loop runs it only while its content
# matches what the user approved with scripts/trust-verify.sh. The record is kept per project directory.
# The place is under $HOME, not under CLAUDE_PLUGIN_DATA: the hook has that variable and the user's terminal does not,
# so a place that depends on it would be written in one directory and read in another.
# It sits under ~/.claude, so Claude's writes there are already stopped (Bash: block, file tools: ask).

verify_trust_dir() { printf '%s' "${HOME:-/nonexistent-home}/.claude/code-guard/verify-trust"; }

# verify_sha <file>: SHA-256 of the content
verify_sha() { perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)' "$1" 2>/dev/null; }

# verify_trust_file <project dir>: where the approved hash of that project's verify.sh is kept (named by the SHA-256 of the real path)
verify_trust_file() {
  local root key
  root="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  key="$(printf '%s' "$root" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)' 2>/dev/null)"
  [ -n "$key" ] || return 1
  printf '%s/%s' "$(verify_trust_dir)" "$key"
}

# verify_trusted <project dir> <verify.sh>: succeeds only when the content is the one the user approved.
# A symlink never counts: its target can change without the link changing
verify_trusted() {
  local f want got
  [ ! -L "$2" ] || return 1
  f="$(verify_trust_file "$1")" || return 1
  want="$(cat "$f" 2>/dev/null)" || return 1
  got="$(verify_sha "$2")"
  [ -n "$got" ] && [ "$got" = "$want" ]
}
