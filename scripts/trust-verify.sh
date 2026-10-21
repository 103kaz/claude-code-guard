#!/bin/bash
# code-guard: approve a project's .claude/verify.sh so the verify loop may run it.
#   bash trust-verify.sh [project dir]     (default: $CLAUDE_PROJECT_DIR, else the current directory)
# Run it yourself in a terminal. Shows the whole script (control characters made visible) and its hash, then asks on stdin; only "yes" approves.
# The approval is for this content in this directory: changing the file (or using a copy elsewhere) asks again.
# When you change this, add cases to tests/test-verify.sh and run it.
set -uo pipefail

# shellcheck source=lib/verify-trust.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/verify-trust.sh" || { echo "code-guard: cannot load lib/verify-trust.sh" >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "code-guard: perl was not found (macOS: it ships with the system; Debian/Ubuntu: apt install perl)." >&2; exit 1; }

root="${1:-${CLAUDE_PROJECT_DIR:-.}}"
root="$(cd "$root" 2>/dev/null && pwd -P)" || { echo "code-guard: no such directory: ${1:-}" >&2; exit 1; }
verify="$root/.claude/verify.sh"
[ -f "$verify" ] || { echo "code-guard: $verify does not exist." >&2; exit 1; }
[ ! -L "$verify" ] || { echo "code-guard: $verify is a symlink; its target can change without the link changing, so it is not approved. Make it a regular file." >&2; exit 1; }

sha="$(verify_sha "$verify")"
[ -n "$sha" ] || { echo "code-guard: cannot read $verify." >&2; exit 1; }

echo "File:   $verify"
echo "SHA256: $sha"
echo "--- content (all of it; valid UTF-8 text is shown as is; control characters are shown as ^X, invisible or direction-changing characters as <U+XXXX>, bytes that are not UTF-8 as M-X) ---"
# Like cat -v, but a valid UTF-8 character that is printable passes through. Control, format (bidi overrides, zero-width),
# line/paragraph separator, private-use and unassigned characters are shown as <U+XXXX>
perl -e '
  my $u8 = qr/[\xC2-\xDF][\x80-\xBF]|\xE0[\xA0-\xBF][\x80-\xBF]|[\xE1-\xEC\xEE\xEF][\x80-\xBF]{2}|\xED[\x80-\x9F][\x80-\xBF]|\xF0[\x90-\xBF][\x80-\xBF]{2}|[\xF1-\xF3][\x80-\xBF]{3}|\xF4[\x80-\x8F][\x80-\xBF]{2}/;
  local $/; binmode STDIN; my $s = <STDIN>; my $o = "";
  while ($s =~ /\G(?:($u8)|(.))/gcs) {
    if (defined $1) {
      my $ch = $1; utf8::decode(my $c = $ch);
      $o .= ($c =~ /^[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Zs}\p{Co}\p{Cn}\p{Cs}\p{Mn}\p{Me}\x{115F}\x{1160}\x{2800}\x{3164}\x{FFA0}]$/ && $c ne "\x{3000}") ? sprintf("<U+%04X>", ord $c) : $ch;
    } else {
      my $b = ord $2;
      if ($b == 10 || $b == 9) { $o .= $2 }
      elsif ($b < 32) { $o .= "^" . chr($b + 64) }
      elsif ($b == 127) { $o .= "^?" }
      elsif ($b < 128) { $o .= $2 }
      else { my $l = $b - 128; $o .= "M-" . ($l < 32 ? "^" . chr($l + 64) : $l == 127 ? "^?" : chr($l)) }
    }
  }
  binmode STDOUT; print $o' <"$verify"
echo "--- end ---"
printf 'The verify loop will run this script at the end of every turn that changes files. Approve it? Type "yes": '
read -r answer
[ "$answer" = yes ] || { echo "Not approved."; exit 1; }

f="$(verify_trust_file "$root")" || exit 1
mkdir -p "$(dirname "$f")" && printf '%s' "$sha" >"$f" || { echo "code-guard: cannot write the approval ($f)." >&2; exit 1; }
echo "Approved."
