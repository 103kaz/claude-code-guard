#!/usr/bin/perl
# code-guard: empty the quoted strings of a command that only searches for or prints text, so that the git push rules
# do not read them as a push. grep -n "git push *" f and echo "git push origin :" mention a push, they do not run one.
#
# This is an allow-list, not a shell parser. The command is changed only when the WHOLE command is made of
#   segments joined by && || ; |
# whose first word is grep, egrep, fgrep, rg, ag, echo, printf, head, tail, wc, ls or cat, and whose arguments are plain
# words (letters, digits and . / : = , @ % + -) or quoted strings with no $, backtick or backslash-escape that can run
# or hide anything. Anything else is printed unchanged: a $( ), a backtick, <( ) or >( ), a #, a newline, a lone &, a
# redirect, a glob, an option that runs a program (--pre, --pager), another command, a pipe to anything not on the list.
# Input: the command on stdin. Output: the command with 'single-quoted' and "double-quoted" arguments emptied, or unchanged.
use strict;
use warnings;

local $/;
my $c = <STDIN> // '';
$c =~ s/\n\z//;    # the caller passes the command as a here-string, which adds one newline; a newline inside is not allowed

my $cmd  = qr/(?:grep|egrep|fgrep|rg|ag|echo|printf|head|tail|wc|ls|cat)/;
my $word = qr/[A-Za-z0-9_.\/:=,@%+-]+/;
my $sq   = qr/'[^']*'/;
my $dq   = qr/"(?:[^"\\\$`]|\\[^\$`"\\\n])*"/;
my $ws   = qr/[ \t]+/;

# Options that make these tools run a program of their own
sub runs_program { return $_[0] =~ /\A--(?:pre|pre-glob|hostname-bin|pager|exec)(?:\z|=)/ ? 1 : 0; }

my $out = '';
my $pos = 0;
my $len = length $c;
pos($c) = 0;

sub fail { print $c; exit 0; }

# A zero-length match cannot repeat at the same position, so the end of the input is tested by position
sub at_end { return ((pos($c) // 0) >= $len) ? 1 : 0; }

$c =~ /\G[ \t]*/gc;
while (1) {
  # a command word
  $c =~ /\G($cmd)(?=[ \t]|\z|[;|&])/gc or fail();
  $out .= $1;
  # arguments
  while ($c =~ /\G($ws)/gc) {
    my $sp = $1;
    # an argument is one or more adjacent pieces: plain words and quoted strings
    my $arg = '';
    my $raw = '';
    my $got = 0;
    while (1) {
      if    ($c =~ /\G($sq)/gc)   { $raw .= $1; $arg .= "''"; $got = 1; }
      elsif ($c =~ /\G($dq)/gc)   { $raw .= $1; $arg .= '""'; $got = 1; }
      elsif ($c =~ /\G($word)/gc) { $raw .= $1; $arg .= $1;   $got = 1; }
      else { last; }
    }
    if (!$got) { pos($c) = pos($c) - length($sp); last; }   # whitespace before a separator or the end
    fail() if runs_program($raw);
    $out .= $sp . $arg;
  }
  # trailing whitespace, then a separator or the end
  $c =~ /\G([ \t]*)/gc; my $tail = $1;
  if (at_end()) { $out .= $tail; last; }
  if ($c =~ /\G(&&|\|\||;|\|)([ \t]*)/gc) {
    my ($sep, $after) = ($1, $2);
    # a separator must be followed by a command, not by the end ("a ;" is a complete command; "a &&" is not)
    $out .= $tail . $sep . $after;
    if (at_end()) { last if $sep eq ';'; fail(); }
    next;
  }
  fail();
}
print $out;
