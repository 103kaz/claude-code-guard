#!/usr/bin/perl
# code-guard: split a shell command at its top-level separators and report a segment that matches a sandbox
# excludedCommands pattern when the command has more than one segment.
# Input: env CG_CMD (the command) and CG_PATTERNS (one pattern per line; * matches any run of characters).
# Output: the first matching segment, or nothing.
use strict;
use warnings;

my $c = $ENV{CG_CMD} // '';
my @patterns = grep { length } split /\n/, ($ENV{CG_PATTERNS} // '');
exit 0 unless @patterns;

$c =~ s/\\\n//g;    # a line continuation joins the lines
my @seg;
my $cur = '';
my ($sq, $dq) = (0, 0);
my @pending;        # heredoc terminators waiting for the end of the line
my $n = length $c;
my $i = 0;

sub flush { my $s = $cur; $s =~ s/^\s+|\s+$//g; push @seg, $s if length $s; $cur = ''; }

while ($i < $n) {
  my $ch = substr($c, $i, 1);
  if ($sq) { $cur .= $ch; $sq = 0 if $ch eq "'"; $i++; next; }
  if ($dq) {
    if ($ch eq '\\' && $i + 1 < $n) { $cur .= substr($c, $i, 2); $i += 2; next; }
    $cur .= $ch; $dq = 0 if $ch eq '"'; $i++; next;
  }
  if ($ch eq "'") { $sq = 1; $cur .= $ch; $i++; next; }
  if ($ch eq '"') { $dq = 1; $cur .= $ch; $i++; next; }
  if ($ch eq '\\' && $i + 1 < $n) { $cur .= substr($c, $i, 2); $i += 2; next; }
  my $rest = substr($c, $i);
  if ($rest =~ /\A<<</) { $cur .= '<<<'; $i += 3; next; }
  if ($rest =~ /\A<<(-?)[ \t]*(["']?)([A-Za-z_][A-Za-z0-9_]*)\2/) {
    push @pending, [$3, $1 eq '-'];
    $cur .= $&; $i += length $&; next;
  }
  # 2>&1, >&2, &>file, &>>file: the & is part of a redirect, not a separator
  if ($rest =~ /\A(?:[0-9]*>&[0-9-]*|&>>?)/) { $cur .= $&; $i += length $&; next; }
  if ($ch eq "\n") {
    flush();
    $i++;
    while (my $p = shift @pending) {
      my ($delim, $dash) = @$p;
      while ($i < $n) {
        my $eol = index($c, "\n", $i);
        $eol = $n if $eol < 0;
        my $line = substr($c, $i, $eol - $i);
        $i = $eol < $n ? $eol + 1 : $n;
        $line =~ s/^\t+// if $dash;
        last if $line eq $delim;
      }
    }
    next;
  }
  if ($rest =~ /\A(?:&&|\|\|)/) { flush(); $i += 2; next; }
  if ($ch =~ /[;|&]/) { flush(); $i++; next; }
  $cur .= $ch; $i++;
}
flush();

exit 0 if @seg < 2;

my @re = map {
  my $p = $_;
  $p =~ s/^\s+|\s+$//g;
  # "git push *" also matches a bare "git push" (the trailing space-star allows no argument)
  my $tail = $p =~ s/ \*\z// ? '(?: .*)?' : '';
  my $r = join '.*', map { quotemeta } split /\*/, $p, -1;
  qr/\A$r$tail\z/;
} @patterns;

for my $s (@seg) {
  my $t = $s;
  $t =~ s/\s+/ /g;
  for my $r (@re) {
    if ($t =~ $r) { print $t; exit 0; }
  }
}
