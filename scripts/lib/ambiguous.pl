#!/usr/bin/perl
# code-guard: shapes of a command string that the regex guards cannot read reliably.
# The guard does not try to parse the shell; it asks the user instead. Reads the command on stdin and prints a reason
# (one line) when the command is ambiguous. Prints nothing otherwise. Exits non-zero only when this script itself fails,
# which the caller treats as ambiguous too.
use strict;
use warnings;

local $/;
my $c = <STDIN>;
$c = "" unless defined $c;

sub say_reason { print "$_[0]\n"; exit 0 }

# The regexes below are bounded, but a huge command still costs time and a hook timeout lets the command through
say_reason('the command is longer than 100000 characters; the guards do not read it reliably') if length($c) > 100000;

# Scan 1: heredocs. The guards drop heredoc bodies from inspection, so a wrong guess about where a body is would hide
# the lines after it. Bodies that are plain data are recorded in @drop so the word checks below skip them.
my @drop;                    # [start, end) of heredoc bodies that are plain data
# an interpreter in the command may execute data (cat <<'EOF' | bash): then nothing is treated as plain data
my $has_interp = ($c =~ /(?:^|[\s;&|(`\/])(?:bash|sh|zsh|dash|eval|python[0-9.]*|node|perl|ruby|php|lua|osascript|swift|xargs|source|env)(?:\s|$)|(?:^|[;&|(])\s*\.\s/) ? 1 : 0;
{
  my @st = ('c');            # c: command, d: inside "...", s: inside '...'
  my $n = length $c;
  # arithmetic contexts where << is a shift: $((..)), $[..], ((..)), a[1<<b], let
  my $arith_at = ($c =~ /\$\(\(|\$\[|(?:^|[\s;&|(])\(\(|\w\[[^\]\n]{0,200}<<[^\]\n]{0,200}\]|(?:^|[\s;&|(])let\s+\S*<</) ? $-[0] : -1;
  for (my $i = 0; $i < $n; $i++) {
    my $ch = substr($c, $i, 1);
    my $top = $st[-1];
    my $nx = $i + 1 < $n ? substr($c, $i + 1, 1) : '';
    my $marker = ($ch eq '<' && $nx eq '<' && ($i + 2 >= $n || substr($c, $i + 2, 1) ne '<')
                  && substr($c, $i + 2) =~ /^-?[ \t]*["']?\w/);
    if ($top eq 's') {
      say_reason('a heredoc marker appears inside single quotes; the guards cannot tell where the heredoc body is') if $marker;
      pop @st if $ch eq "'";
      next;
    }
    if ($ch eq '\\') { $i++; next }
    if ($ch eq '$' && $nx eq '(') { push @st, 'c'; $i++; next }
    if ($top eq 'd') {
      say_reason('a heredoc marker appears inside double quotes; the guards cannot tell where the heredoc body is') if $marker;
      pop @st if $ch eq '"';
      next;
    }
    # command context
    if ($ch eq '"') { push @st, 'd'; next }
    if ($ch eq "'") { push @st, 's'; next }
    if ($ch eq ')' && @st > 1) { pop @st; next }
    if ($ch eq '#' && ($i == 0 || substr($c, $i - 1, 1) =~ /[\s;&|(]/)) {
      my $eol = index($c, "\n", $i);
      my $rest = $eol < 0 ? substr($c, $i) : substr($c, $i, $eol - $i);
      say_reason('a heredoc marker appears in a comment; the guards cannot tell where the heredoc body is') if $rest =~ /<<(?!<)/;
      $i = $eol < 0 ? $n : $eol;
      next;
    }
    if ($ch eq '<' && $nx eq '<') {
      if ($i + 2 < $n && substr($c, $i + 2, 1) eq '<') { $i += 2; next }    # here-string <<<
      my $le = index($c, "\n", $i);
      $le = $n if $le < 0;
      if ($arith_at >= 0 && $arith_at <= $le) {
        say_reason('a << appears together with an arithmetic expansion; the guards cannot tell whether it starts a heredoc');
      }
      # the terminator word: quotes and backslashes are removed (<<'END-1', <<"a b", <<E"O"F, <<\EOF)
      if (substr($c, $i + 2) =~ /^(-?)[ \t]*((?:"[^"]*"|'[^']*'|\\.|[^\s;&|<>()"'\\])+)/) {
        my ($dash, $raw, $mlen) = ($1, $2, length($&));
        my $quoted = ($raw =~ /["'\\]/) ? 1 : 0;
        my $word = $raw;
        $word =~ s/"([^"]*)"/$1/g;
        $word =~ s/'([^']*)'/$1/g;
        $word =~ s/\\(.)/$1/g;
        if ($word !~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
          say_reason('a heredoc terminator word other than letters, digits and _ (END-1, "a b"); the guards cannot tell where the body ends');
        }
        my $after = $i + 2 + $mlen;
        my $eol = index($c, "\n", $after);
        my $pos = $eol < 0 ? $n : $eol + 1;
        my $body_start = $pos;
        my ($found, $term_start) = (0, $pos);
        while ($pos < $n) {
          my $nl = index($c, "\n", $pos);
          my $line = $nl < 0 ? substr($c, $pos) : substr($c, $pos, $nl - $pos);
          my $line_start = $pos;
          $line =~ s/^\t+// if $dash;
          $pos = $nl < 0 ? $n : $nl + 1;
          if ($line eq $word) { $found = 1; $term_start = $line_start; last }
        }
        if (!$found) {
          say_reason('a heredoc has no terminator line; the guards cannot tell where the heredoc body ends');
        }
        # the rest of the marker's own line is still command text
        my $tail_end = $eol < 0 ? $n : $eol;
        if ($after < $tail_end) {
          my $tail = substr($c, $after, $tail_end - $after);
          my $dq = () = $tail =~ /(?<!\\)"/g;
          my $sq = () = $tail =~ /(?<!\\)'/g;
          say_reason('quotes on the line of a heredoc marker are unbalanced; the guards cannot tell where the heredoc body is')
            if ($dq % 2 || $sq % 2) && $top eq 'c' && @st == 1;
        }
        my $body = substr($c, $body_start, $term_start - $body_start);
        push @drop, [$body_start, $term_start] if !$has_interp && ($quoted || $body !~ /\$\((?!\()|`/);
        $i = $pos - 1;
      } else {
        say_reason('a heredoc marker whose terminator word cannot be read; the guards cannot tell where the heredoc body is');
      }
      next;
    }
  }
}

# The text the word checks read: plain heredoc bodies and double/single quoted -m / --body values of git commit and
# gh pr/issue are data, not commands (the guards drop them too). A value with $( or a backtick is kept.
my $s = $c;
for my $r (reverse @drop) { substr($s, $r->[0], $r->[1] - $r->[0]) = '' }
if ($s =~ /(?:^|[\s;&|(])(?:git\s+(?:-\S+\s+)*(?:commit|tag)|gh\s+(?:pr|issue)\s+(?:create|edit|comment|review|close))\b/
    && !$has_interp) {
  $s =~ s/(?<=\s)(?:-m|--message|--body|--title)([ =])("(?:[^"\\\$`]|\\[^\$`])*"|\x27[^\x27]*\x27)/-m$1""/g;
}

# A command word the guards care about (optionally with a path), then its global options (a value of -C / -c is
# skipped; atomic so the regex cannot reinterpret the value as the subcommand)
my $cw  = qr/(?:git|gh|wrangler|terraform)/;
my $ctl = qr/(?:^|[\s;&|(`])(?:[^\s;&|()`]*\/)?${cw}/;
my $opt = qr/(?>(?:\s+(?:-[Cc]\s+(?:"[^"]*"|'[^']*'|\S+)|-\S+))*)/;
# words that run the next word as a command: skipped when looking for the command name
my $wrap = qr/^(?:sudo|env|command|exec|time|nohup|nice|xargs|timeout|builtin)$/;

# a quote at one end only (`b"` from X="a git b", `"git` from bash -c "git ...") is not a split word
sub one_end { $_[0] =~ /^["'][^"'\\]*$/ || $_[0] =~ /^[^"'\\]*["']$/ }

sub word_rules {
  my ($t) = @_;

  # 1. The command name itself is quoted or split: "git" push, g"i"t push, gi\t push, $'git' push, /usr/bin/"git" push.
  # Only the word in command position counts, so grep "git" and echo "git" are not asked.
  for my $seg (split /[;&|\n(`]+/, $t) {
    my @w = split ' ', $seg;
    while (@w && ($w[0] =~ /^\w+=/ || $w[0] =~ /^-/ || $w[0] =~ /^\d+$/ || $w[0] =~ $wrap || one_end($w[0]))) { shift @w }
    next unless @w;
    my $w = $w[0];
    next unless $w =~ /["'\\]/;
    (my $u = $w) =~ s/^\\(?=[A-Za-z])//;                    # \git is undone by the guards
    $u =~ s/\$(?=["'])//g;                                    # $'git' and $"git" are ANSI-C / locale quotes
    $u =~ s/["'\\]//g;
    if ($u =~ m{^(?:.*/)?${cw}\z}) {
      say_reason('the command name is quoted or split (g"i"t, "git", gi\t, $\'git\'); the guards cannot read it reliably');
    }
  }

  # 2. The subcommand word has a quote or backslash inside: git "push", git pu\sh
  while ($t =~ /$ctl$opt\s+(\S{0,500}["'\\]\S{0,500})/g) {
    (my $cand = $1) =~ s/[;&|)]+$//;
    next if $cand !~ /["'\\]/ || one_end($cand);
    say_reason('a command word is split by quotes or a backslash (git "push", git pu\sh); the guards cannot read it reliably');
  }

  # 3. A push argument built from quotes, backslashes or expansions: ma"in, ma\in, ma${x}in, $B, ma$(echo in), `echo main`
  if ($t =~ /(?:^|[\s;&|(`])(?:\S*\/)?git$opt\s+push\b[^|;&\n]{0,2000}(?:[\w.\/=-](?:["'\\]|\$\{?)\w|\$[\w{(]|`)/) {
    say_reason('a git push argument is built from quotes, backslashes or expansions (ma"in, $B, ${x}); the target cannot be read reliably');
  }

  # 4. Line continuation inside a command that has a guarded command word, or inside a word: git push \<newline> main, .e\<newline>nv
  if ($t =~ /$ctl[^\n;&|]{0,2000}\\\n/ || $t =~ /\w\\\n\w/) {
    say_reason('a line continuation splits the command words; the guards cannot read it reliably');
  }
}

word_rules($s);

# The text inside bash -c "..." / eval "..." is a command too. Quotes nested in it ("git "push" ...", \"push\") are
# read by the shell as part of the words, so check the payload on its own. The earliest one covers the later ones.
if ($s =~ /(?:^|[\s;&|(`])(?:(?:bash|sh|zsh|dash)\b[^;&|\n"']{0,200}?\s-[A-Za-z]*c\s+|(?:eval|exec)\s+)["']/) {
  word_rules(substr($s, $+[0]));
}

exit 0;
