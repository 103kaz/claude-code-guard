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

# Drop heredoc bodies (data, not commands): "cat <<EOF" followed by lines up to the delimiter. A body inside a quoted
# $(cat <<'EOF' ...) is dropped too, and the closing quote after the delimiter stays, so quotes still balance
my @kept;
my ($delim, $dash);
my @brk;    # what joins each kept line to the next
my @ctx;    # open quote or $( contexts, kept across lines
for my $line (split /\n/, $cmd, -1) {
  if (defined $delim) {
    my $t = $line;
    $t =~ s/\A\t+// if $dash;
    undef $delim if $t eq $delim;
    next;
  }
  push @kept, $line;
  # A "<<WORD" counts only outside quotes, or inside a $( ) that is inside quotes ("$(cat <<'EOF'"); echo "<<EOF" is text
  for (my $k = 0; $k < length $line; $k++) {
    my $ch = substr($line, $k, 1);
    my $top = @ctx ? $ctx[-1] : '';
    if ($top eq "'") { pop @ctx if $ch eq "'"; next; }
    if ($ch eq '\\') { $k++; next; }
    if ($top eq '"') {
      if ($ch eq '"') { pop @ctx; next; }
      if ($ch eq '$' && substr($line, $k + 1, 1) eq '(') { push @ctx, '('; $k++; }
      next;
    }
    if ($ch eq "'" || $ch eq '"') { push @ctx, $ch; next; }
    if ($ch eq '$' && substr($line, $k + 1, 1) eq '(') { push @ctx, '('; $k++; next; }
    if ($ch eq ')' && $top eq '(') { pop @ctx; next; }
    if (substr($line, $k, 3) eq '<<<') { $k += 2; next; }    # a here-string, not a heredoc
    if (substr($line, $k) =~ /\A<<(-?)[ \t]*(["']?)([A-Za-z_][A-Za-z0-9_]*)\2/) {
      ($dash, $delim) = ($1 eq '-', $3);
      last;
    }
  }
  # A newline outside quotes ends a command like ";" does (shellwords would read it as plain white space)
  push @brk, @ctx ? "\n" : " ; ";
}
$cmd = '';
$cmd .= $kept[$_] . ($_ < $#kept ? $brk[$_] : '') for 0 .. $#kept;

my @w = eval { shellwords($cmd) };
exit 0 if $@ || !@w;

sub is_sep { my $x = shift; return $x =~ /\A(?:&&|\|\||;|\|)\z/ || $x =~ /;\z/; }

# gh is a command only at the start, after a separator, or after prefixes that run the next word (VAR=x, sudo, env, time ...);
# "echo gh pr create ..." and "grep -n gh pr create" only mention it
sub at_command_position {
  my $i = shift;
  while ($i > 0) {
    my $p = $w[$i - 1];
    return 1 if is_sep($p);
    return 0 unless $p =~ /\A[A-Za-z_][A-Za-z0-9_]*=/ || $p =~ /\A(?:sudo|env|command|time|nohup|exec|nice)\z/;
    $i--;
  }
  return 1;
}

for my $i (0 .. $#w - 2) {
  next unless $w[$i] eq 'gh' && $w[$i + 1] eq 'pr' && $w[$i + 2] =~ /\A(?:create|edit)\z/;
  next unless at_command_position($i);
  my $title;
  for my $j ($i + 3 .. $#w) {
    # --title=... is read before the separator check: a title that ends in ";" is still the title
    if ($w[$j] =~ /\A--title=(.*)\z/s) { $title = $1; last; }
    last if is_sep($w[$j]);
    if (($w[$j] eq '--title' || $w[$j] eq '-t') && $j < $#w) { $title = $w[$j + 1]; last; }
  }
  next unless defined $title;
  next if $title =~ /\A[\$`]/ || $title eq '';    # built at run time: cannot be read
  next if $title =~ /\A(?:$prefixes)(?:\([^)]+\))?!?:\s/;
  (my $one = $title) =~ s/\s+/ /g;
  print "BAD\t$one";
  exit 0;
}
exit 0;
