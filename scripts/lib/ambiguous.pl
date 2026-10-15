#!/usr/bin/perl
# code-guard: shapes of a command string that the regex guards cannot read reliably.
# The guard does not try to parse the shell; it asks the user instead. Reads the command on stdin and prints a reason
# (one line) when the command is ambiguous. Prints nothing otherwise. Never exits non-zero for a normal input.
use strict;
use warnings;

local $/;
my $c = <STDIN>;
$c = "" unless defined $c;

sub say_reason { print "$_[0]\n"; exit 0 }

# A command word the guards care about, then its global options (a value of -C / -c is skipped; atomic so the regex
# cannot reinterpret the value as the subcommand)
my $ctl = qr/(?:^|[\s;&|(])(?:git|gh|wrangler|terraform)/;
my $opt = qr/(?>(?:\s+(?:-[Cc]\s+(?:"[^"]*"|'[^']*'|\S+)|-\S+))*)/;

# 1. The subcommand word has a quote or backslash inside: git "push", git pu\sh
if ($c =~ /$ctl$opt\s+\S*["'\\]\S*/) {
  say_reason('a command word is split by quotes or a backslash (git "push", git pu\sh); the guards cannot read it reliably');
}

# 2. A push argument with a quote, backslash or expansion in the middle of a word: ma"in, ma\in, ma${x}in, --no-"verify"
if ($c =~ /(?:^|[\s;&|(])git$opt\s+push\b[^|;&\n]*[\w.\/=-](?:["'\\]|\$\{?)\w/) {
  say_reason('a git push argument is built from quotes, backslashes or expansions (ma"in, ${x}); the target cannot be read reliably');
}

# 3. Line continuation inside the command words: git \<newline> push, .e\<newline>nv
if ($c =~ /$ctl$opt\s*\\\n/ || $c =~ /\w\\\n\w/) {
  say_reason('a line continuation splits the command words; the guards cannot read it reliably');
}

# 4. A heredoc marker (<<) where it may not be a heredoc: inside quotes, in arithmetic, or in a comment.
# The guards drop heredoc bodies from inspection, so a wrong guess would hide the lines after it.
# Real heredocs (<<WORD, <<'WORD', <<-WORD) are skipped up to their terminator so a body with quotes does not confuse the scan.
{
  my @st = ('c');            # c: command, d: inside "...", s: inside '...'
  my $n = length $c;
  my $arith = ($c =~ /\$\(\(/) ? 1 : 0;
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
      if ($arith) {
        say_reason('a << appears together with an arithmetic expansion; the guards cannot tell whether it starts a heredoc');
      }
      if (substr($c, $i + 2) =~ /^(-?)[ \t]*(["']?)(\w+)\2/) {
        my ($dash, $word) = ($1, $3);
        my $after = $i + 2 + length($&);
        my $eol = index($c, "\n", $after);
        my $pos = $eol < 0 ? $n : $eol + 1;
        my $found = 0;
        while ($pos < $n) {
          my $nl = index($c, "\n", $pos);
          my $line = $nl < 0 ? substr($c, $pos) : substr($c, $pos, $nl - $pos);
          $line =~ s/^\t+// if $dash;
          $pos = $nl < 0 ? $n : $nl + 1;
          if ($line eq $word) { $found = 1; last }
        }
        # the rest of the marker's own line is still command text: continue from the end of that line, then jump
        my $tail_end = $eol < 0 ? $n : $eol;
        if ($after < $tail_end) {
          my $tail = substr($c, $after, $tail_end - $after);
          # scan the tail by recursion-free simple rule: quotes in the tail are balanced in real commands
          my $dq = () = $tail =~ /(?<!\\)"/g;
          my $sq = () = $tail =~ /(?<!\\)'/g;
          say_reason('quotes on the line of a heredoc marker are unbalanced; the guards cannot tell where the heredoc body is')
            if ($dq % 2 || $sq % 2) && $top eq 'c' && @st == 1;
        }
        $i = $pos - 1;
        $i = $n if !$found;
      }
      next;
    }
  }
}
exit 0;
