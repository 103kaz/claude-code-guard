#!/usr/bin/perl
# code-guard: read the --title of a gh pr create / gh pr edit command and report it when it does not start with one of
# the configured prefixes ("feat:", "fix(scope):" ...).
# Input: env CG_CMD (the command) and CG_PREFIXES (prefixes joined by |, plain word characters only).
# Output: "BAD<TAB>title" for a title that does not match, nothing otherwise (no --title, no gh pr create, a title built
# by a substitution or variable, or a command that cannot be split into words).
# This splits the command into shell words; it is not a shell parser.
use strict;
use warnings;
use Text::ParseWords qw(shellwords);

my $cmd = $ENV{CG_CMD} // '';
my $prefixes = $ENV{CG_PREFIXES} // '';
exit 0 unless length $cmd && $prefixes =~ /\A[A-Za-z0-9_|-]+\z/;

$cmd =~ s/\\\n//g;    # a line continuation joins the lines
my @w = eval { shellwords($cmd) };
exit 0 if $@ || !@w;

sub is_sep { my $x = shift; return $x =~ /\A(?:&&|\|\||;|\|)\z/ || $x =~ /;\z/; }

for my $i (0 .. $#w - 2) {
  next unless $w[$i] eq 'gh' && $w[$i + 1] eq 'pr' && $w[$i + 2] =~ /\A(?:create|edit)\z/;
  my $title;
  for my $j ($i + 3 .. $#w) {
    last if is_sep($w[$j]);
    if (($w[$j] eq '--title' || $w[$j] eq '-t') && $j < $#w) { $title = $w[$j + 1]; last; }
    if ($w[$j] =~ /\A--title=(.*)\z/s) { $title = $1; last; }
  }
  next unless defined $title;
  next if $title =~ /\A[\$`]/ || $title eq '';    # built at run time: cannot be read
  next if $title =~ /\A(?:$prefixes)(?:\([^)]+\))?!?:\s/;
  (my $one = $title) =~ s/\s+/ /g;
  print "BAD\t$one";
  exit 0;
}
exit 0;
