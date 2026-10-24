#!/usr/bin/perl
# code-guard: empty the quoted strings that a read-only command only searches for or prints, so that the git push rules
# do not read them as a push. grep -n "git push *" f and echo "git push origin :" mention a push, they do not run one.
# Input: the command on stdin. Output: the same command with, in each segment (split at ; & | and a newline) whose first
# word is grep, egrep, fgrep, rg, ag, echo or printf, every 'single-quoted' string and every "double-quoted" string
# that has no $( or backtick emptied. A string that can run a command, an unquoted word, and every other segment are kept.
# When the command cannot be read to the end (an unterminated quote), it is printed unchanged.
use strict;
use warnings;

local $/;
my $c = <STDIN> // '';
my $n = length $c;

# Split into segments at the separators outside quotes. @parts holds [text, separator] pairs
my @parts;
my $cur = '';
my $i = 0;
my $ok = 1;
while ($i < $n) {
  my $ch = substr($c, $i, 1);
  if ($ch eq "'") {
    my $e = index($c, "'", $i + 1);
    if ($e < 0) { $ok = 0; last; }
    $cur .= substr($c, $i, $e - $i + 1); $i = $e + 1; next;
  }
  if ($ch eq '"') {
    my $j = $i + 1;
    while ($j < $n) {
      my $d = substr($c, $j, 1);
      if ($d eq '\\') { $j += 2; next; }
      last if $d eq '"';
      $j++;
    }
    if ($j >= $n) { $ok = 0; last; }
    $cur .= substr($c, $i, $j - $i + 1); $i = $j + 1; next;
  }
  if ($ch eq '\\' && $i + 1 < $n) { $cur .= substr($c, $i, 2); $i += 2; next; }
  # $( ... ) and `...` outside quotes stay in the segment as they are: they are not blanked, and a separator inside one
  # only splits the segment earlier, which blanks less, never more
  if ($ch =~ /[;|&\n]/) {
    my $sep = $ch;
    $i++;
    while ($i < $n && substr($c, $i, 1) =~ /[;|&]/) { $sep .= substr($c, $i, 1); $i++; }
    push @parts, [$cur, $sep];
    $cur = '';
    next;
  }
  $cur .= $ch; $i++;
}
if (!$ok) { print $c; exit 0; }
push @parts, [$cur, ''];

# A double-quoted string that can run a command ($( ) or a backtick) is kept
sub blank_quoted {
  my ($s) = @_;
  my $out = '';
  while ($s =~ /\G(\\.|'[^']*'|"(?:[^"\\]|\\.)*"|[^'"\\]+|.)/gs) {
    my $t = $1;
    if ($t =~ /\A'/) { $out .= "''"; }
    elsif ($t =~ /\A"/) { $out .= ($t =~ /\$\(|`/) ? $t : '""'; }
    else { $out .= $t; }
  }
  return $out;
}

my $res = '';
for my $p (@parts) {
  my ($text, $sep) = @$p;
  if ($text =~ /\A\s*(?:\S*\/)?(?:grep|egrep|fgrep|rg|ag|echo|printf)(?:\s|\z)/) {
    $text = blank_quoted($text);
  }
  $res .= $text . $sep;
}
print $res;
