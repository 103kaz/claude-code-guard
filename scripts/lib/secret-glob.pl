#!/usr/bin/perl
# code-guard: words that build a secret file name the regex rules cannot see.
#   - a glob or brace expansion that can expand to a secret name (cat .en?, cat .e{n,x}v, --include=*.tfvars)
#   - a name put together from quoted parts or backslashes (cat ".e"nv, cat \.env)
# Reads the command on stdin and prints the first such word. Prints nothing otherwise. The caller treats a failure of
# this script (non-zero exit) as ambiguous.
# A bare * / *.* / .* is not judged (too common). A leading dot must be written, as in the shell.
# The regex for literal names comes from SECRET_PATH_RE (lib/common.sh) through the environment.
use strict;
use warnings;

local $/;
my $c = <STDIN>;
$c = "" unless defined $c;
my $sre = $ENV{SRE} || '(?!)';

# sample names that the glob is tried against
my @names = (".env", ".env.local", ".env.production", ".dev.vars", "prod.tfvars", "terraform.tfstate",
             "terraform.tfstate.backup", "server.key", "server.pem", "id_rsa", "id_ed25519", "id_ecdsa",
             "AuthKey_X.p8", "cert.p12");

# [[ ... ]] compares strings with patterns; nothing there is a file name
$c =~ s/\[\[.*?\]\]/ /gs;

# a quoted or backslash-escaped character is literal: it is marked with \x00 in front
sub mark {
  my ($raw) = @_;
  my $out = "";
  while ($raw =~ /\G(?:"([^"]*)"|\x27([^\x27]*)\x27|\\(.)|(.))/gcs) {
    if (defined $1 || defined $2) { my $s = defined $1 ? $1 : $2; $out .= join("", map { "\x00$_" } split(//, $s)) }
    elsif (defined $3) { $out .= "\x00$3" }
    else { $out .= $4 }
  }
  return $out;
}

sub plain { (my $s = $_[0]) =~ s/\x00//g; return $s }

for my $raw ($c =~ /((?:"[^"]*"|\x27[^\x27]*\x27|\\.|[^\s;&|()<>`"\x27\\])+)/gs) {
  # quotes or a backslash inside the word (".e"nv, \.env). A word quoted as a whole ("server.key") is left to the
  # regex rules, which know about grep patterns
  my $had = ($raw =~ /["\x27\\]/ && $raw !~ /^(?:"[^"]*"|\x27[^\x27]*\x27)$/) ? 1 : 0;
  my $w = mark($raw);
  $w =~ s/^-[^=]*=// if $w =~ /^-/;        # --include=*.tfvars: the value
  next if $w =~ /^-/;
  my @alts = ($w);
  for (1 .. 8) {
    last unless grep { /(?<!\x00)\{[^{}]*,[^{}]*(?<!\x00)\}/ } @alts;
    @alts = map {
      /^(.*?)(?<!\x00)\{([^{}]*,[^{}]*)(?<!\x00)\}(.*)$/s
        ? do { my ($a, $b, $z) = ($1, $2, $3); map { "$a$_$z" } split(/(?<!\x00),/, $b, -1) }
        : $_
    } @alts;
  }
  for my $g (@alts) {
    my $base = $g;
    $base =~ s{^.*(?<!\x00)/}{}s;          # the last path part, after the braces are expanded
    my $glob = ($base =~ /(?:^|[^\x00])[?*\[]/) ? 1 : 0;
    if (!$glob) {
      next unless $had || $g ne $w;        # a plain literal word is left to the regex rules
      my $p = plain($g);
      next if $p =~ /\.(example|sample|template)$/;
      if ($p =~ /$sre/i) { print plain($raw); exit 0 }
      next;
    }
    next if plain($base) =~ /^[*.]*$/;
    my $re = "";
    while ($base =~ /\G(?:\x00(.)|(\*)|(\?)|(\[!?[^\]]+\])|(.))/gcs) {
      $re .= defined $1 ? quotemeta($1)
           : defined $2 ? "[^/]*"
           : defined $3 ? "[^/]"
           : defined $4 ? do { (my $k = $4) =~ s/^\[!/[^/; $k }
           : quotemeta($5);
    }
    for my $n (@names) {
      next if $n =~ /^\./ && plain($base) !~ /^\./;
      if ($n =~ /^$re$/) { print plain($raw); exit 0 }
    }
  }
}
exit 0;
