#!/usr/bin/perl
# code-guard: does a shell in this command read its program from standard input? (echo "git push origin main" | bash,
# bash <<< "...", bash < <(...), ... | source /dev/stdin). The text it is fed is then a command, quoted or not.
# Input: the command on stdin. Exit 0: a shell reads stdin. Exit 1: none does. Not a shell parser: a segment (split at ; & | newline)
# counts when it is fed by a pipe, a here-string or a process substitution, its words before the shell are only wrappers
# (sudo env command exec nohup nice time xargs busybox, their options, VAR=x), and the shell is not given -c, -n or a script file.
use strict;
use warnings;

local $/;
my $c = <STDIN> // '';

# Separators and spaces inside quotes must not split a word; the quotes themselves stay, so "bash" is still seen
$c =~ s{("(?:[^"\\]|\\.)*"|'[^']*')}{ my $s = $1; $s =~ tr/;&|\n<>(){}# \t/_/; $s }gse;

my $shell = qr/(?:ba|z|da|k|c|tc|fi)?sh|\$SHELL|\$\{SHELL\}/;
my $wrap  = qr/(?:sudo|env|command|exec|nohup|nice|time|xargs|busybox)/;
my @parts = split /(\|\||&&|;|\n|\||&)/, $c;
my $delim = '';
for my $p (@parts) {
  if ($p =~ /\A(?:\|\||&&|;|\n|\||&)\z/) { $delim = $p; next }
  my $fed = $delim eq '|' || $p =~ /<<<|<[ \t]*<\(/;
  my $seg = $p;
  $seg =~ s/<[ \t]*<\(.*//s;                        # bash < <(cmd): the shell reads cmd's output, nothing after it is its argument
  $seg =~ s/[(){}]/ /g;
  my @w = grep { length } split /[ \t]+/, $seg;
  my @k;                                            # words without quotes and redirects
  while (@w) {
    my $x = shift @w;
    last if $x =~ /\A#/;
    if ($x =~ /\A\d*(?:<<<|<|>>?|>&|&>)(.*)\z/s) { shift @w if $1 eq ''; next }
    $x =~ s/["']//g;
    push @k, $x;
  }
  next unless $fed && @k;
  my $i = 0;
  $i++ while $i < @k && ($k[$i] =~ /\A-/ || $k[$i] =~ /\A\w+=/ || $k[$i] =~ /\A\{\}\z/ || ($k[$i] =~ m{\A(?:.*/)?$wrap\z}));
  next if $i >= @k;
  my $name = $k[$i]; (my $base = $name) =~ s{.*/}{};
  my @rest = @k[$i + 1 .. $#k];
  if ($base eq 'source' || $base eq '.') {
    exit 0 if @rest && $rest[0] =~ m{\A/dev/(?:stdin|fd/0)\z};
    next;
  }
  next unless $base =~ /\A$shell\z/ || $name =~ /\A\$/;
  my ($stdin_ok, $positional_ok) = (1, 0);
  while (@rest) {
    my $o = shift @rest;
    if ($o eq '--') { next }
    if ($o eq '-o' || $o eq '+o') { shift @rest; next }
    if ($o =~ /\A[-+]/) {
      if ($o =~ /\A-[A-Za-z]*[cn]/) { $stdin_ok = 0; last }
      $positional_ok = 1 if $o =~ /\A-[A-Za-z]*s/;
      next;
    }
    next if $o =~ m{\A/dev/(?:stdin|fd/0)\z};
    next if $positional_ok;
    $stdin_ok = 0; last;                            # a script file: stdin is not the program
  }
  exit 0 if $stdin_ok;
}
exit 1;
