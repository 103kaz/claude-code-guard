#!/bin/bash
# code-guard: the user's approval of a project's .claude/verify.sh. Source this file; do not run it.
# A verify.sh from a cloned repository is code someone else wrote, so the verify loop runs it only while its content
# matches what the user approved with scripts/trust-verify.sh. The record is kept per project directory under the plugin data directory.

verify_trust_dir() { printf '%s' "${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/code-guard}/verify-trust"; }

# verify_trust_file <project dir>: where the approved hash of that project's verify.sh is kept
verify_trust_file() {
  local root
  root="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s' "$(verify_trust_dir)" "$(printf '%s' "$root" | cksum | tr -c '0-9\n' '_' | head -n 1)"
}

# verify_sha <file>: SHA-256 of the content
verify_sha() { perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)' "$1" 2>/dev/null; }

# verify_trusted <project dir> <verify.sh>: succeeds only when the content is the one the user approved
verify_trusted() {
  local f want got
  f="$(verify_trust_file "$1")" || return 1
  want="$(cat "$f" 2>/dev/null)" || return 1
  got="$(verify_sha "$2")"
  [ -n "$got" ] && [ "$got" = "$want" ]
}
