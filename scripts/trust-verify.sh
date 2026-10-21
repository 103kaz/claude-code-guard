#!/bin/bash
# code-guard: approve a project's .claude/verify.sh so the verify loop may run it.
#   bash trust-verify.sh [project dir]     (default: $CLAUDE_PROJECT_DIR, else the current directory)
# Run it yourself in a terminal after reading the script. Shows the script and its hash, then asks on stdin; only "yes" approves.
# The approval is for this content in this directory: changing the file (or using a copy elsewhere) asks again.
# When you change this, add cases to tests/test-verify.sh and run it.
set -uo pipefail

# shellcheck source=lib/verify-trust.sh
. "${BASH_SOURCE[0]%/*}/lib/verify-trust.sh" || { echo "code-guard: cannot load lib/verify-trust.sh" >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "code-guard: perl was not found (macOS: it ships with the system; Debian/Ubuntu: apt install perl)." >&2; exit 1; }

root="${1:-${CLAUDE_PROJECT_DIR:-.}}"
root="$(cd "$root" 2>/dev/null && pwd -P)" || { echo "code-guard: no such directory: ${1:-}" >&2; exit 1; }
verify="$root/.claude/verify.sh"
[ -f "$verify" ] || { echo "code-guard: $verify does not exist." >&2; exit 1; }

sha="$(verify_sha "$verify")"
[ -n "$sha" ] || { echo "code-guard: cannot read $verify." >&2; exit 1; }

echo "File:   $verify"
echo "SHA256: $sha"
echo "--- content (first 200 lines) ---"
head -n 200 "$verify"
echo "--- end ---"
printf 'The verify loop will run this script at the end of every turn that changes files. Approve it? Type "yes": '
read -r answer
[ "$answer" = yes ] || { echo "Not approved."; exit 1; }

f="$(verify_trust_file "$root")" || exit 1
mkdir -p "$(dirname "$f")" && printf '%s' "$sha" >"$f" || { echo "code-guard: cannot write the approval ($f)." >&2; exit 1; }
echo "Approved."
