#!/usr/bin/perl
# code-guard: split a shell command at its top-level separators and report a segment that matches a sandbox
# excludedCommands pattern when the command has more than one segment.
# Input: env CG_CMD (the command) and CG_PATTERNS (one pattern per line; * matches any run of characters).
# Output: the first matching segment, or nothing.
# This is a scanner for quotes, $'..', $( ), $(( )), backticks, comments, redirects and heredocs, not a shell parser.
# When the command cannot be read to the end (an unterminated quote or substitution), it reports nothing.
use strict;
use warnings;

my $c = $ENV{CG_CMD} // '';
my @patterns = grep { length } split /\n/, ($ENV{CG_PATTERNS} // '');
exit 0 unless @patterns;

$c =~ s/\\\n//g;    # a line continuation joins the lines
my $n = length $c;

# Each skip_* takes the index just after the opening mark and returns the index just after the closing mark,
# or -1 when the command ends first.
sub skip_sq {
  my ($i) = @_;
  my $e = index($c, "'", $i);
  return $e < 0 ? -1 : $e + 1;
}

sub skip_bt {
  my ($i) = @_;
  while ($i < $n) {
    my $ch = substr($c, $i, 1);
    if ($ch eq '\\') { $i += 2; next; }
    return $i + 1 if $ch eq '`';
    $i++;
  }
  return -1;
}

sub skip_ansi {    # $'...' : a backslash escapes the next character
  my ($i) = @_;
  while ($i < $n) {
    my $ch = substr($c, $i, 1);
    if ($ch eq '\\') { $i += 2; next; }
    return $i + 1 if $ch eq "'";
    $i++;
  }
  return -1;
}

sub skip_arith {    # after "$((" : up to the matching "))"
  my ($i) = @_;
  my $depth = 2;
  while ($i < $n) {
    my $ch = substr($c, $i, 1);
    $depth++ if $ch eq '(';
    if ($ch eq ')') { $depth--; return $i + 1 if $depth == 0; }
    $i++;
  }
  return -1;
}

# After "$(" or "$((" has been recognised at $i (pointing at the "$"): the end of the substitution
sub skip_dollar_paren {
  my ($i) = @_;
  return skip_arith($i + 3) if substr($c, $i, 3) eq '$((';
  return skip_cmdsub($i + 2);
}

sub skip_dq {
  my ($i) = @_;
  while ($i < $n) {
    my $ch = substr($c, $i, 1);
    if ($ch eq '\\') { $i += 2; next; }
    return $i + 1 if $ch eq '"';
    if ($ch eq '$' && substr($c, $i + 1, 1) eq '(') { $i = skip_dollar_paren($i); return -1 if $i < 0; next; }
    if ($ch eq '`') { $i = skip_bt($i + 1); return -1 if $i < 0; next; }
    $i++;
  }
  return -1;
}

# Skip the bodies of the pending heredocs, starting at the first character after a newline
sub skip_bodies {
  my ($i, $pending) = @_;
  while (my $p = shift @$pending) {
    my ($delim, $dash) = @$p;
    my $found = 0;
    while ($i < $n) {
      my $eol = index($c, "\n", $i);
      $eol = $n if $eol < 0;
      my $line = substr($c, $i, $eol - $i);
      $i = $eol < $n ? $eol + 1 : $n;
      $line =~ s/^\t+// if $dash;
      if ($line eq $delim) { $found = 1; last; }
    }
    return -1 unless $found;
  }
  return $i;
}

sub skip_cmdsub {    # after "$(" : up to the matching ")"
  my ($i) = @_;
  my $depth = 1;
  my @pending;
  while ($i < $n) {
    my $ch = substr($c, $i, 1);
    if ($ch eq "'") { $i = skip_sq($i + 1); return -1 if $i < 0; next; }
    if ($ch eq '"') { $i = skip_dq($i + 1); return -1 if $i < 0; next; }
    if ($ch eq '`') { $i = skip_bt($i + 1); return -1 if $i < 0; next; }
    if ($ch eq '\\') { $i += 2; next; }
    if ($ch eq '$' && substr($c, $i + 1, 1) eq '(') { $i = skip_dollar_paren($i); return -1 if $i < 0; next; }
    if ($ch eq '$' && substr($c, $i + 1, 1) eq "'") { $i = skip_ansi($i + 2); return -1 if $i < 0; next; }
    my $rest = substr($c, $i, 40);
    if ($rest =~ /\A<<</) { $i += 3; next; }
    if ($rest =~ /\A<<(-?)[ \t]*(["']?)([A-Za-z_][A-Za-z0-9_]*)\2/) {
      push @pending, [$3, $1 eq '-'];
      $i += length $&; next;
    }
    if ($ch eq "\n" && @pending) { $i = skip_bodies($i + 1, \@pending); return -1 if $i < 0; next; }
    if ($ch eq '(') { $depth++; $i++; next; }
    if ($ch eq ')') { $depth--; return $i + 1 if $depth == 0; $i++; next; }
    $i++;
  }
  return -1;
}

my @seg;
my $cur = '';
my @pending;
sub flush { my $s = $cur; $s =~ s/^\s+|\s+$//g; push @seg, $s if length $s; $cur = ''; }

my $i = 0;
while ($i < $n) {
  my $ch = substr($c, $i, 1);
  my $next;
  if ($ch eq "'") { $next = skip_sq($i + 1); }
  elsif ($ch eq '"') { $next = skip_dq($i + 1); }
  elsif ($ch eq '`') { $next = skip_bt($i + 1); }
  elsif ($ch eq '$' && substr($c, $i + 1, 1) eq "'") { $next = skip_ansi($i + 2); }
  elsif ($ch eq '$' && substr($c, $i + 1, 1) eq '(') { $next = skip_dollar_paren($i); }
  if (defined $next) {
    exit 0 if $next < 0;    # cannot be read to the end: report nothing
    $cur .= substr($c, $i, $next - $i);
    $i = $next; next;
  }
  if ($ch eq '\\' && $i + 1 < $n) { $cur .= substr($c, $i, 2); $i += 2; next; }
  # A comment runs to the end of the line; # inside a word (a#b) is not one
  if ($ch eq '#' && ($cur eq '' || $cur =~ /\s\z/)) {
    my $eol = index($c, "\n", $i);
    $i = $eol < 0 ? $n : $eol;
    next;
  }
  my $rest = substr($c, $i, 40);
  if ($rest =~ /\A<<</) { $cur .= '<<<'; $i += 3; next; }
  if ($rest =~ /\A<<(-?)[ \t]*(["']?)([A-Za-z_][A-Za-z0-9_]*)\2/) {
    push @pending, [$3, $1 eq '-'];
    $cur .= $&; $i += length $&; next;
  }
  # 2>&1, >&2, &>file, &>>file, >|file: the & or | is part of a redirect, not a separator
  if ($rest =~ /\A(?:[0-9]*>&[0-9-]*|&>>?|>\|)/) { $cur .= $&; $i += length $&; next; }
  if ($ch eq "\n") {
    flush();
    $i++;
    if (@pending) { $i = skip_bodies($i, \@pending); exit 0 if $i < 0; }
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
  $p =~ s/:\*\z/ */;    # the older "git push:*" form means "git push *"
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
