#!/bin/bash
# code-guard: PreToolUse(Bash) guard.
# Stops operations an agent should not run in any project. exit 2 + stderr blocks and returns the reason to Claude.
# Core rules cannot be turned off; the packs (github, terraform, gcp, cloudflare) are toggled by userConfig.
#
# One layer of defense in depth, not a sandbox: the same operation through python etc. is not stopped.
# When you change this, add cases to tests/test-guard.sh and run it.
set -uo pipefail

# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/lib/common.sh" || { echo "BLOCKED by code-guard: cannot load lib/common.sh; blocking everything this hook covers." >&2; exit 2; }
need_cmd jq perl

input="$(cat)"
cmd="$(jq -er '.tool_input.command // ""' <<<"$input")" \
  || block "could not read the hook input (not valid JSON); blocking everything this hook covers"
cmd_raw="$cmd"
# Undo word-shape evasions before matching: \git -> git, g""it -> git
cmd="$(perl -pe 's/""//g; s/\x27\x27//g; s/(^|[\s;&|(])\\([A-Za-z])/$1$2/g' <<<"$cmd")"
# Shapes the regexes cannot read reliably (split command words, odd heredoc markers): ask, do not guess
ambiguous="$(perl "${BASH_SOURCE[0]%/*}/lib/ambiguous.pl" <<<"$cmd_raw" 2>/dev/null)"
# A failed check (missing file, syntax error, killed) is not "nothing found": ask instead of passing silently
ambiguous_rc=$?
[ "$ambiguous_rc" -ne 0 ] && ambiguous="the ambiguity check could not run (exit $ambiguous_rc); the command shape was not checked"

# Characters that can precede a command name: line start / space / ; & | ( ` / quote / path separator
P="(^|[[:space:];&|(\`\"'/])"

# awk program that drops heredoc bodies (data, not commands). In an unquoted heredoc (<<EOF) the shell runs $( ) and
# backticks, so those parts of the body are kept: a $( is followed to its matching ), across lines and past a ) inside
# quotes. A quoted heredoc (<<'EOF', <<"EOF") is data throughout
HEREDOC_AWK='function grab(s,   i, n, c, out, j) { out = ""; n = length(s)
    for (i = 1; i <= n; i++) { c = substr(s, i, 1)
      if (gd > 0) { out = out c
        if (gq != "") { if (c == gq) gq = ""; continue }
        if (c == "\"" || c == "\047") { gq = c; continue }
        if (c == "(") gd++; else if (c == ")") { gd--; if (gd == 0) out = out " " }
        continue }
      if (c == "$" && substr(s, i + 1, 1) == "(") { gd = 1; gq = ""; out = out " $("; i++; continue }
      if (c == "`") { j = index(substr(s, i + 1), "`")
        if (j) { out = out " " substr(s, i, j + 1); i += j } else { out = out " " substr(s, i); i = n } } }
    return out }
  { if (skip != "") { t = $0; if (dash) sub(/^\t+/, "", t); if (t == skip) { skip = ""; gd = 0; next }
    if (!q) { out = grab($0); if (out ~ /[^ ]/) print out }
    next }
  print
  l = $0; gsub(/<<</, "", l)
  gsub(/<<-?[[:space:]]*"/, "<<@@D", l); gsub(/<<-?[[:space:]]*\047/, "<<@@S", l)
  gsub(/"[^"]*"/, "", l); gsub(/\047[^\047]*\047/, "", l)
  if (match(l, /<<-?[[:space:]]*(@@[DS])?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
    s = substr(l, RSTART, RLENGTH); dash = (s ~ /^<<-/); q = (s ~ /@@[DS]/)
    gsub(/^<<-?[[:space:]]*(@@[DS])?|["\047]$/, "", s); skip = s } }'

# Where a command can sit: after line start / ; & | ( ` $( , or right after a quote of bash -c / eval / exec.
# Words between (env / timeout / sudo -u x / VAR="a b" prefixes; a quoted value is one word) and a path (/opt/homebrew/bin/git) are skipped.
# No match when no unquoted command name follows the words (echo "git push" is not caught; eval "git push" and bash -c "git push" are)
CMDPOS="((^|[;&|(\`]|\\\$\\()|((bash|sh|zsh|dash)[^;&|\"']*-[A-Za-z]*c[[:space:]]+[\"'])|((eval|exec)[[:space:]]+[\"']))[[:space:]]*((([^;&|\"'\`()[:space:]]|\"[^\"]*\"|'[^']*')+[[:space:]]+)*)([^[:space:];&|\"']*/)?"

# Operations that need approval are asked last, after every block rule has been passed
pending_ask=""
# Rules that can misfire go to ask instead of block (approve to pass a false positive).
# Not for certain-danger rules (push to a protected branch, secrets). The reason is joined to pending_ask and shown once at the end
soft_reason=""
# add_ask <reason>: join reasons so a heavy one is not hidden by a later light one
add_ask() {
  pending_ask="${pending_ask:+$pending_ask / }$1"
}
soft_block() {
  soft_reason="${soft_reason:+$soft_reason / }[may be a false positive; approve if it is] $1"
}

if pack_on terraform; then
# --- Terraform pack ---
TF="${P}terraform([[:space:]]+-[^[:space:]]+)*[[:space:]]+"
if grep -Eq "${TF}(destroy|import|taint|untaint|force-unlock)([[:space:]\"']|$)" <<<"$cmd"; then
  block "terraform destroy/import/taint/untaint/force-unlock are not allowed"
fi
# apply is allowed only for a reviewed saved plan file, with approval
if grep -Eq "${TF}apply([[:space:]\"']|$)" <<<"$cmd"; then
  if grep -Eq "${TF}plan([[:space:]\"']|$)" <<<"$cmd"; then
    block "do not run plan and apply in one command (show the plan to the user and get their OK before apply)"
  fi
  if grep -Eq "${TF}apply([^|;&]*)[[:space:]]-(auto-approve|destroy|target|replace|var|var-file|refresh-only)([[:space:]=]|$)" <<<"$cmd"; then
    block "do not use -auto-approve/-destroy/-target/-replace/-var/-var-file/-refresh-only with terraform apply (apply a saved plan file)"
  fi
  if ! grep -Eq "${TF}apply([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^-[:space:]][^[:space:]]*plan[^[:space:]]*([[:space:]\"';&|]|$)" <<<"$cmd"; then
    block "terraform apply is allowed only with a saved plan file (name contains plan): terraform apply <planfile>"
  fi
  add_ask "terraform apply: confirm the user has OKed applying this plan in chat before approving"
fi
if grep -Eq "${TF}state[[:space:]]+(rm|mv|push|pull|replace-provider)" <<<"$cmd"; then
  block "changing or dumping terraform state is not allowed"
fi
fi

# --- Secret files and values (core) ---
# Text of git commit / gh pr·issue (-m / --body / --title values and heredoc bodies) is never executed, so it is excluded.
# A commit message that merely mentions ".env.local" is not blocked. A double-quoted value with $( or a backtick, and such a
# line of an unquoted heredoc, are kept: the shell runs them ("$(cat .env)").
# Commands containing bash -c / eval / python etc. are not excluded: the string may be executed
cmd_msg="$cmd"
# -m / --message / --body / --title values are message text everywhere. -b / -t are message flags only inside a
# gh pr|issue create|edit|comment|review|close segment (cat -b ".env" and gh pr view 1; cat -b ".env" are reads)
msg_flags='-m|--message|--body|--title'
if grep -Eq "${P}(git([[:space:]]+-[^[:space:]]+)*[[:space:]]+(commit|tag)|gh[[:space:]]+(pr|issue)[[:space:]]+(create|edit|comment|review|close)|cat|tee)([[:space:]]|$)" <<<"$cmd" \
   && ! grep -Eq "${P}(bash|sh|zsh|dash|eval|python[0-9.]*|node|perl|ruby|php|lua|osascript|swift|xargs|source|env)([[:space:]]|$)|(^|[;&|(])[[:space:]]*\.[[:space:]]" <<<"$cmd"; then
  # $dq: a double-quoted value with no $( and no backtick (nothing in it runs), the only kind dropped as message text
  cmd_msg="$(awk "$HEREDOC_AWK" <<<"$cmd" \
    | MSGFLAGS="$msg_flags" perl -0pe 'my $dq = qr/"(?:[^"\\\$\x60]|\\.|\$(?!\())*"/; s/(?<=\s)($ENV{MSGFLAGS})([ =])($dq|\x27[^\x27]*\x27)/$1$2""/gs' \
    | perl -0pe 'my $dq = qr/"(?:[^"\\\$\x60]|\\.|\$(?!\())*"/; 1 while s/((?:^|[;&|\n])[ \t]*gh[ \t]+(?:pr|issue)[ \t]+(?:create|edit|comment|review|close)(?:[^;&|"\x27\n]|"(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27)*?[ \t])(-b|-t)([ =])($dq|\x27[^\x27]*\x27)/$1-X$2$3""/s' 2>/dev/null)" || cmd_msg="$cmd"
fi
# JS/TS properties (e.key, event.key, item.key ...) are not key files. Drop them only when they are the search pattern of
# grep / rg (the first non-option argument); cat data.key is still a read of a key file
cmd_sec="$cmd_msg"
if grep -Eq "${P}(grep|egrep|fgrep|rg|ag)[[:space:]]" <<<"$cmd_msg"; then
  cmd_sec="$(perl -pe 's/((?:^|[\s;&|(])(?:grep|egrep|fgrep|rg|ag)(?:\s+-[^\s\x27"]+)*\s+(?:-e\s+)?)["\x27]?(?:[A-Za-z_]\w*\.)*(?:e|ev|evt|event|item|props|entry|row|obj|data|node|child|el|prev|next|ctx|opts|options)\.key\b["\x27]?/$1""/g' <<<"$cmd_msg")"
fi
# *.tfvars regardless of name (prod.tfvars too). Samples such as *.tfvars.example are allowed.
# A name can follow a redirect (<.env), a rev (HEAD:.env) or an option (--env-file=.env), not only a space or quote.
# terraform -var-file=x.tfvars only hands the file to terraform, so it keeps passing
if grep -Eq '(^|[/[:space:]"'"'"'<>=:])([[:alnum:]_*-]+\.tfvars|\.env)([^.[:alnum:]_-]|$)|\.tfvars\.json|[a-z_]*token[a-z_]*\.txt|\.tfstate(\.[a-z]+)?([[:space:]"'"'"';|&)]|$)|\.ssh/|id_(rsa|ed25519|ecdsa)' <<<"$(sed -E 's/-var-file=/-var-file@/g' <<<"$cmd_sec")"; then
  block "access to secret files (*.tfvars / .env / *.tfstate / *token*.txt / keys) is not allowed"
fi
# *.pem / *.key look the same as code search patterns (grep "setting.key " src/).
# Quoted grep / rg patterns without a "/" are not inspected (path-like "keys/a.key" and unquoted a.key are).
# This only affects *.pem / *.key, not the .env or *.tfvars rules
cmd_key="$cmd_sec"
if grep -Eq "${P}(grep|egrep|fgrep|rg|ag)[[:space:]]" <<<"$cmd_sec"; then
  cmd_key="$(sed -E "s/\"[^\"/]*\"//g; s/'[^'/]*'//g" <<<"$cmd_sec")"
fi
if grep -Eq '(^|[^$[:alnum:]_-])[[:alnum:]_-]+\.(pem|key)([[:space:]"'"'"';|&)]|$)' <<<"$cmd_key"; then
  block "access to secret files (*.tfvars / .env / *.tfstate / *token*.txt / keys) is not allowed"
fi
# .env.local / .env.production etc. (.env.example / .sample / .template are allowed) and wrangler .dev.vars
if grep -Eq '(^|[/[:space:]"'"'"'<>=:])(\.env\.[A-Za-z0-9._-]+|\.dev\.vars(\.[A-Za-z0-9_-]+)?)([[:space:]"'"'"';|&)]|$)' <<<"$(sed -E 's#\.env\.(example|sample|template)#.env-ok#g' <<<"$cmd_msg")"; then
  block "access to secret files (.env.* / .dev.vars) is not allowed"
fi
# Globs and brace expansion build a secret name the rules above cannot see (cat .en?, cat .e{n,x}v, --include=*.tfvars).
# Each unquoted word with ? * [ or {a,b} is matched against sample secret names. A bare * / *.* / .* is not judged
# (too common), and a leading dot must be written, as in the shell
# Names built from quotes or backslashes (cat ".e"nv) are read the same way (lib/secret-glob.pl)
if [[ "$cmd_sec" == *[\?\*\[\{\"\'\\]* ]]; then
  glob_hit="$(SRE="$SECRET_PATH_RE" perl "${BASH_SOURCE[0]%/*}/lib/secret-glob.pl" <<<"$cmd_sec" 2>/dev/null)"
  glob_rc=$?
  [ -n "$glob_hit" ] && block "a glob, brace or quoted pattern ($glob_hit) can expand to a secret file name (.env, *.tfvars, keys); name the files explicitly"
  [ "$glob_rc" -ne 0 ] && soft_block "the secret-name check for globs could not run (exit $glob_rc); the command was not checked for it"
fi
# iOS signing assets (*.p8 *.p12 *.mobileprovision AuthKey_*) and Firebase / GCP service account keys
if grep -Eq '(^|[/[:space:]"'"'"'])AuthKey_[[:alnum:]_]+|(^|[^$[:alnum:]_*-])[[:alnum:]_-]+\.(p8|p12|mobileprovision)([[:space:]"'"'"';|&)]|$)|firebase-adminsdk[^[:space:]]*\.json|[Ss]ervice-?[Aa]ccount[^[:space:]]*\.json' <<<"$cmd"; then
  block "access to signing assets (*.p8 / *.p12 / *.mobileprovision / AuthKey_*) and service account keys is not allowed"
fi
# CLI credentials: cloud (~/.aws, ~/.config/gcloud), GitHub (gh token), container and Kubernetes, home .netrc / .npmrc / .pypirc,
# macOS keychain values, git credentials (store files and the credential helpers). A project .npmrc (registry settings) is not covered.
# // and /./ are collapsed first (~//.netrc is ~/.netrc)
if grep -Eq '\.aws/(credentials|config|sso/cache|cli/cache)|\.config/(gh/hosts\.yml|gcloud/|git/credentials)|\.git-credentials|\.kube/config|\.docker/config\.json|(~|\$HOME|\$\{HOME\}|/Users/[^/[:space:]]+|/home/[^/[:space:]]+)/\.(netrc|npmrc|pypirc)([^[:alnum:]_.-]|$)' <<<"$(sed -E 's#/(\./)+#/#g; s#//+#/#g' <<<"$cmd_sec")" \
   || grep -Eq "${P}(git[^|;&]*[[:space:]]|git-)credential(-[a-z]+)?[[:space:]]+(fill|get)([[:space:]]|$)" <<<"$cmd_msg" \
   || grep -Eq "${P}gh[[:space:]]+auth[[:space:]]+(token|status([^|;&]*)[[:space:]](-t|--show-token))([[:space:]\"']|$)" <<<"$cmd" \
   || grep -Eq "${P}security[[:space:]]+(find-(generic|internet)-password([^|;&]*)[[:space:]]-[a-zA-Z]*[wg]([[:space:]]|$)|dump-keychain)" <<<"$cmd"; then
  block "reading CLI credentials (~/.aws, ~/.config/gcloud, gh token, git credentials, ~/.kube, ~/.docker, ~/.netrc, keychain values) is not allowed"
fi

# --- GCP pack: cloud operations that lose data, secret values ---
if pack_on gcp; then
  if grep -Eq 'gcloud([^|;&]*)(compute[[:space:]]+(disks|instances|snapshots|resource-policies|images)[[:space:]]+delete|projects[[:space:]]+delete|storage[[:space:]]+(rm|buckets[[:space:]]+delete)|sql[[:space:]]+instances[[:space:]]+delete)' <<<"$cmd" \
     || grep -Eq "${P}gsutil([^|;&]*)[[:space:]](rm|rb)([[:space:]]|$)" <<<"$cmd"; then
    block "deleting cloud disks / instances / projects / storage is not allowed"
  fi
  if grep -Eq 'gcloud([^|;&]*)(secrets[[:space:]]+versions[[:space:]]+access|auth[[:space:]]+(application-default[[:space:]]+)?print-(access|identity)-token)' <<<"$cmd"; then
    block "printing Secret Manager values or access tokens is not allowed"
  fi
fi

# --- Cloudflare pack (wrangler): deploys that bypass Git, deleting or changing resources and secrets are for a human ---
if pack_on cloudflare \
   && grep -Eq "${P}wrangler(([[:space:]]+(-c|--config|-e|--env|--cwd)[[:space:]]+[^[:space:]]+)|([[:space:]]+-[^[:space:]]+))*[[:space:]]+(deploy|publish|delete|rollback|versions[[:space:]]+deploy|pages[[:space:]]+(deploy|publish)|pages[[:space:]]+(project|deployment)[[:space:]]+delete|(r2|kv|d1|queues|vectorize|hyperdrive)([[:space:]]+[^|;&[:space:]]+)*[[:space:]]+delete|secret[[:space:]]+(put|delete|bulk))([[:space:]\"']|$)" <<<"$cmd"; then
  block "wrangler deploy / delete / rollback / secret changes are not allowed (deploys that bypass Git and resource or secret changes are for a human)"
fi

# --- Changes to the harness itself (disabling the guard) (core) ---
# Ways to write a file: a redirect, in-place editors (sed / perl / ruby -i, awk -i inplace), file commands, dd / rsync,
# downloads to a file (curl -o / -O, wget -O), and git commands that write the working tree (checkout, restore, apply, am)
WRITE_FILE_RE='>[[:space:]]*[^&[:space:]]|sed[[:space:]]+(-[a-zA-Z]*i|--in-place)|(perl|ruby)([[:space:]]+-[^[:space:]]+)*[[:space:]]+-[a-zA-Z]*i|awk[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-i[[:space:]]*inplace|(^|[[:space:];&|(`])(rm|mv|cp|tee|chmod|ln|truncate|install|dd|rsync)[[:space:]]|(curl|wget)[^|;&]*[[:space:]](-[a-zA-Z]*[oO]|--output(-document)?|--remote-name)([[:space:]=]|$)'
# git writes count only next to the path in the same segment (git checkout b && cat .claude/hooks/x is a read)
WRITE_RE="${WRITE_FILE_RE}|git[^|;&]*[[:space:]](checkout|restore|apply|am)[[:space:]]"
# Drop harmless redirects (>/dev/null, 2>&1) before judging writes
cmd_nr="$(sed -E 's#[0-9]*>>?[[:space:]]*/dev/null##g; s#[0-9]*>&[0-9-]##g' <<<"$cmd")"
# A grep / rg search pattern (the first quoted argument after options) is not a write target, so it is dropped
# (grep -n '>' .claude/settings.json is not a write). A > outside quotes and arguments after the pattern stay
cmd_nr="$(perl -pe 's/((?:^|[\s;&|(])(?:grep|egrep|fgrep|rg|ag)(?:\s+-[^\s\x27"]+)*\s+(?:-e\s+)?)("(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27)/$1""/g' <<<"$cmd_nr" 2>/dev/null)" || cmd_nr="$cmd"
# ~/.claude (hooks, settings, plugins) and the project .claude/settings*, .githooks, .git/config, .git/hooks are blocked.
# Project .claude/hooks and .claude/verify.sh are asked. To reduce false positives, (1) heredoc bodies (content, not the
# target) are dropped, and (2) a write operation and a protected path must be in the same segment, split at && / || / newline.
# The split ignores quotes and does not split on ; or | (so sed -i 's/a/b/;s/c/d/' .githooks/x is caught).
# Trailing backslash lines are joined first. A << inside quotes is read as a heredoc and the rest is skipped (a known gap; this is not a sandbox)
# After cd / pushd, relative arguments are relative to the new directory: a copy of the command with them joined to it
# (cd .githooks && rm pre-push -> rm .githooks/pre-push) is judged too. A cd to a variable stops the joining
cmd_cd=""
# Subshells ( ) and groups { } are followed (a subshell's cd ends with it), popd goes back, cd options (-P, --) are skipped,
# a glob target (cd .gi?) is resolved when it names one directory, and a redirect without a space (x>hooks/y) and an
# --opt=value are read as paths
if [[ "$cmd_nr" == *cd* || "$cmd_nr" == *pushd* ]]; then
  cmd_cd="$(perl -0ne 'exit unless /(?:^|[;&|(){}\n])\s*(?:cd|pushd)(?:\s|$)/;
  my ($d, $out, @sub, @dirs) = ("", "");
  for my $seg (split /(&&|\|\||[;|\n(){}])/) {
    if ($seg =~ /^(?:&&|\|\||[;|\n(){}])$/) {
      push @sub, $d if $seg eq "("; $d = (@sub ? pop @sub : "") if $seg eq ")";
      $out .= "\n"; next }
    $seg =~ s/(?<=\S)(\d*>>?|<)/ $1/g; $seg =~ s/(\d*>>?|<)(?=[^\s>&])/$1 /g;
    my @w = split " ", $seg;
    if (@w && $w[0] eq "popd") { $d = @dirs ? pop @dirs : ""; next }
    if (@w && $w[0] =~ /^(?:cd|pushd)$/) {
      push @dirs, $d if $w[0] eq "pushd";
      my @a = @w[1 .. $#w]; shift @a while @a && $a[0] =~ /^(?:-[LPe@]+|--)$/;
      my $t = @a ? $a[0] : "~"; $t =~ s/["\x27]//g;
      if ($t =~ /[\$`]/) { $d = ""; next }
      if ($t =~ /[*?\[]/) { my @m = grep { -d } glob($d eq "" || $t =~ m{^[/~]} ? $t : "$d/$t"); $t = $m[0] if @m == 1; $t =~ s{^\Q$d\E/}{} if @m == 1 && $d ne "" }
      $d = ($t =~ m{^[/~]} || $d eq "") ? $t : "$d/$t";
      1 while $d =~ s{(^|/)\.(?:/|$)}{$1};
      1 while $d =~ s{(^|/)(?!\.\.(?:/|$))[^/]+/\.\.(?:/|$)}{$1};
      $d =~ s{/+$}{}; next }
    if ($d eq "" || !@w) { $out .= $seg; next }
    my ($i, @r) = (0);
    push @r, $w[$i++] while $i < @w && $w[$i] =~ /^\w+=/;
    push @r, $w[$i++] if $i < @w;
    for (; $i < @w; $i++) {
      my ($p, $v) = $w[$i] =~ /^(\d*>>?|<|of=|--[A-Za-z-]+=)?(.*)$/s; $p = "" unless defined $p;
      $v = "$d/$v" if $v ne "" && $v !~ m{^[-+/~\$&]};
      push @r, "$p$v" }
    $out .= join(" ", @r) }
  print $out' <<<"$cmd_nr" 2>/dev/null)"
fi
# // and /./ in a path are one /, and dir/.. is dropped (~/.claude//settings.json, .git/./hooks, ~/./.gitconfig);
# a URL scheme (https://) is left alone
cmd_home="$(sed -E -e ':a' -e 's#([^:/])//+#\1/#g; s#/\./#/#g; s#(^|[[:space:]=<>])\./#\1#g; s#(^|[[:space:]=<>/])([^/.[:space:]][^/[:space:]]*|\.[^/.[:space:]][^/[:space:]]*)/\.\./#\1#; ta' -e 's#(~|\$HOME|\$\{HOME\}|'"$HOME"')/\.claude/#HOMECLAUDE/#g; s#(~|\$HOME|\$\{HOME\}|'"$HOME"')/\.gitconfig([^[:alnum:]_.-]|$)#HOMEGITCONFIG\2#g' <<<"$cmd_nr${cmd_cd:+$'\n'$cmd_cd}" \
  | awk "$HEREDOC_AWK" \
  | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' \
  | awk '{ gsub(/&&|\|\|/, "\n"); print }')"
while IFS= read -r seg; do
  [ -z "$seg" ] && continue
  # chmod +x does not change content, so it is not a write. Arguments run up to ; & | < >.
  # A redirect (chmod +x f > .githooks/x) stays and is judged as a write
  seg_w="$(sed -E 's#(^|[[:space:];&|(`])chmod[[:space:]]+[ugoa]*\+x([[:space:]]+[^;&|<>()`[:space:]]+)*#\1#g' <<<"$seg")"
  if grep -Eq "$WRITE_RE" <<<"$seg_w"; then
    if grep -Eq 'HOMECLAUDE/(hooks|settings|plugins)|\.claude/settings|\.githooks|\.git/(config|hooks)|\.git/modules/[^[:space:]]*/(config|hooks)|HOMEGITCONFIG|\.config/git/config' <<<"$seg_w"; then
      block "changing the harness (~/.claude hooks / settings / plugins, .claude/settings*, .githooks, .git/config, .git/hooks, ~/.gitconfig, ~/.config/git/config) through Bash is not allowed (chmod +x alone is fine)"
    elif grep -Eq '\.claude/(hooks|verify\.sh)' <<<"$seg_w"; then
      add_ask "changing .claude/hooks / .claude/verify.sh: confirm the user has OKed this change in chat before approving"
    elif grep -Eq '\.github/workflows' <<<"$seg_w"; then
      add_ask "changing .github/workflows (a path that uses Secrets): confirm the user has OKed this change in chat before approving"
    fi
  fi
done <<<"$cmd_home"
# ask only adds a confirmation, so look at the whole command instead of segments (catches git add .claude/hooks && git commit -m "<a@b>")
if [ -z "$pending_ask" ] \
   && grep -Eq "$WRITE_FILE_RE" <<<"$cmd_home" \
   && grep -Eq '\.claude/(hooks|verify\.sh)|\.github/workflows' <<<"$cmd_home"; then
  add_ask "changing .claude/hooks / .claude/verify.sh / .github/workflows: confirm the user has OKed this change in chat before approving"
fi
# Reading (git config core.hooksPath / --get) is fine. Setting a value (other than .githooks) and --unset are blocked
# git config keys are case-insensitive (core.hookspath is the same key)
if grep -Eiq "${P}git([[:space:]]+-[^[:space:]]+)*[[:space:]]+config([^|;&]*)core\.hooksPath" <<<"$cmd_msg" \
   && { grep -Eq "config([^|;&]*)[[:space:]](--)?(unset|unset-all|remove-section)([[:space:]]|$)" <<<"$cmd_msg" \
        || grep -Eiq 'core\.hooksPath[[:space:]]+[^[:space:];&|]' <<<"$cmd_msg"; } \
   && ! grep -Eiq 'core\.hooksPath[[:space:]]+\.githooks([[:space:];&|]|$)' <<<"$cmd_msg"; then
  block "changing core.hooksPath is not allowed (it disables git hooks)"
fi
# A one-off override also drops hooks: git -c / --config-env, GIT_CONFIG_* env vars, including another config file.
# An alias can hide push or --no-verify (git -c alias.p='push --no-verify' p slips past the push rules too)
GITCFG_KEY="[\"']?(core\.hookspath|include(if)?\.|alias\.)"
if grep -Eiq "${P}git[^|;&]*[[:space:]](-c[[:space:]]*|--config-env[[:space:]=]+)${GITCFG_KEY}" <<<"$cmd" \
   || grep -Eiq "GIT_CONFIG_(KEY_[0-9]+=|PARAMETERS=[^;&|]*)${GITCFG_KEY}|GIT_CONFIG(_GLOBAL|_SYSTEM)?=" <<<"$cmd"; then
  block "changing core.hooksPath / include / alias through git -c / --config-env / GIT_CONFIG_* is not allowed (it can bypass hooks and push rules)"
fi
# A persistent alias / include is blocked for the same reason (reading git config --get alias.x is fine)
if grep -Eiq "${P}git([[:space:]]+-[^[:space:]]+)*[[:space:]]+config([^|;&]*)[[:space:]](alias\.[^[:space:]]+|include(if)?\.[^[:space:]]+)[[:space:]]+[^[:space:];&|]" <<<"$cmd"; then
  block "setting alias / include through git config is not allowed (it can bypass hooks and push rules)"
fi
# Removing or renaming a whole core / alias / include section drops core.hooksPath with it (old --remove-section and new remove-section)
if grep -Eiq "${P}git([[:space:]]+-[^[:space:]]+)*[[:space:]]+config([^|;&]*)[[:space:]](--)?(remove|rename)-section[[:space:]]+[\"']?(core|alias|include(if)?)([.\"'[:space:]]|$)" <<<"$cmd_msg"; then
  block "removing or renaming the core / alias / include section of git config is not allowed (it can drop core.hooksPath)"
fi
# Moving the global config (HOME= / XDG_CONFIG_HOME= for a git command) makes git read another .gitconfig, which can set hooksPath / alias
# Either a prefix of the git command itself (HOME=x [VAR=y] git, env HOME=x git) or an export before a git command
ASSIGN="[A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|'[^']*'|[^[:space:];&|])*[[:space:]]+"
if grep -Eq "(^|[[:space:];&|(])(env[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)?(${ASSIGN})*(HOME|XDG_CONFIG_HOME)=(\"[^\"]*\"|'[^']*'|[^[:space:];&|])*[[:space:]]+(${ASSIGN})*([^[:space:];&|]*/)?git[[:space:]]" <<<"$cmd_msg" \
   || { grep -Eq "(^|[[:space:];&|(])export[[:space:]]+(HOME|XDG_CONFIG_HOME)=" <<<"$cmd_msg" && grep -Eq "${CMDPOS}git[[:space:]]" <<<"$cmd_msg"; }; then
  block "running git with HOME= / XDG_CONFIG_HOME= changed is not allowed (git would read another global config, which can bypass hooks and push rules)"
fi

# --- git push: direct push to a protected branch / force push / hook bypass (core) ---
# git global options, including the ones that take a value (-C "a b", --git-dir <dir>)
GITOPTS="(-[Cc][[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]]+)|--(git-dir|work-tree|namespace|exec-path|super-prefix|config-env)[[:space:]]+(\"[^\"]*\"|[^[:space:]]+)|-[^[:space:]]+)"
GIT_PUSH="${CMDPOS}git([[:space:]]+${GITOPTS})*[[:space:]]+push"
GIT="${CMDPOS}git([[:space:]]+${GITOPTS})*[[:space:]]+"
# Hook bypass on commit and merge: --no-verify (and abbreviations) and commit -n. Quoted text is not an option
cmd_nq="$(sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g" <<<"$cmd_msg")"
if grep -Eq "${GIT}(commit|merge|am|rebase|cherry-pick|revert|pull)([^|;&]*)[[:space:]]--no-v[a-z]*([^[:alnum:]-]|$)" <<<"$cmd_nq" \
   || grep -Eq "${GIT}commit([^|;&]*)[[:space:]]-[A-Za-z]*n[A-Za-z]*([^[:alnum:]-]|$)" <<<"$cmd_nq"; then
  block "git commit / merge with --no-verify (commit -n) is not allowed (it skips the git hooks)"
fi
# git also accepts abbreviated long options (--del, --no-ver) and combined short options (-ud)
if grep -Eq "${GIT_PUSH}([^|;&]*)[[:space:]](--no-v[a-z]*|--mi[a-z]*|--de[a-z]*|--pru[a-z]*|--all?|-[A-Za-z]*d[A-Za-z]*)([^[:alnum:]-]|$)" <<<"$cmd_msg"; then
  block "git push --no-verify / --mirror / --delete (-d) / --prune / --all is not allowed"
fi
# For refspec matching: drop -o / --push-option values and strip quotes and backslashes ("":feat/x becomes :feat/x after shell expansion)
# Also strip the leading $ of $'...' and $"..." ($':feat/y' becomes :feat/y)
cmd_refspec="$(sed -E "s/(^|[[:space:]])(-o|--push-option)([[:space:]]+|=)(\"[^\"]*\"|'[^']*'|[^[:space:]]+)//g; s/\\\$([\"'])/\\1/g; s/[\"'\\\\]//g" <<<"$cmd_msg")"
# ANSI-C escapes ($'\x3afeat/y') cannot be resolved from the string, so stop them
if grep -Eq "${GIT_PUSH}([^|;&]*)[[:space:]]\\\$'[^']*\\\\" <<<"$cmd_msg"; then
  block "escapes inside git push $'...' (\\x3a etc.) are not allowed because the refspec cannot be checked"
fi
# A refspec starting with ":" (git push origin :feat/x) deletes the remote branch, like --delete
if grep -Eq "${GIT_PUSH}([^|;&]*)[[:space:]]:[^[:space:]:]" <<<"$cmd_refspec"; then
  block "git push with a refspec starting with a colon (deleting a remote branch) is not allowed"
fi
# A lone ":" pushes all matching branches, a protected one included
if grep -Eq "${GIT_PUSH}([^|;&]*)[[:space:]]\+?:([[:space:]]|$)" <<<"$cmd_refspec"; then
  block "git push with a lone ':' (all matching branches) is not allowed (it can push a protected branch)"
fi
# A wildcard refspec is blocked when its destination (the source when there is no ':') can match a protected branch
# (refs/heads/*:refs/heads/*, ma*). feat/* cannot
wild_hit="$(PROT="$PROTECTED_LIST" perl -ne 'next unless /\bgit\b[^;&|\n]*?\spush\b([^;&|)\n]*)/;
  for my $r (split " ", $1) { next if $r =~ /^-/ || $r !~ /\*/; $r =~ s/^\+//;
    my $dst = $r =~ /:(.*)$/ ? $1 : $r; $dst =~ s{^(refs/)?heads/}{};
    (my $re = quotemeta $dst) =~ s/\\\*/.*/g;
    for my $b (split /, /, $ENV{PROT}) { if ($b =~ /^$re$/) { print $r; exit } } }' <<<"$cmd_refspec" 2>/dev/null)"
[ -n "$wild_hit" ] && block "git push with a wildcard refspec that can reach a protected branch ($wild_hit) is not allowed"
if grep -Eq "${GIT_PUSH}([[:space:]\"';&|)]|$)" <<<"$cmd_msg"; then
  # Is the push target a protected branch: named in the refspec, or on a protected branch with no refspec / HEAD (git push, git push origin HEAD)
  push_main=0
  # heads/main without refs/ is the same ref for git
  if grep -Eq "${GIT_PUSH}([^|;&]*)[[:space:]:+\"']((refs/)?heads/)?(${PROTECTED_RE})([[:space:]\"';&|)]|$)" <<<"$cmd_msg"; then
    push_main=1
  fi
  # The directory git will act on: the last -C <dir>, else --work-tree / --git-dir, read from the git words before "push"
  push_dir="$(perl -ne 'if (/\bgit((?:\s+(?:-C\s+(?:"[^"]*"|\x27[^\x27]*\x27|\S+)|-c\s+\S+|--(?:git-dir|work-tree|namespace|exec-path|super-prefix|config-env)(?:=|\s+)\S+|-\S+))*)\s+push\b/) { my $o = $1; my $d = "";
      while ($o =~ /-C\s+("[^"]*"|\x27[^\x27]*\x27|\S+)/g) { $d = $1 }
      if ($d eq "" && $o =~ /--(?:work-tree|git-dir)(?:=|\s+)(\S+)/) { $d = $1 }
      $d =~ s/^["\x27]|["\x27]$//g; print $d; exit }' <<<"$cmd_msg")"
  # cd / pushd and GIT_DIR= before the push move it to another repository: follow them (a variable is not resolved)
  # Quoted text is not a command (echo "a; cd /tmp"). GIT_DIR= counts only as a prefix of the push itself or an export.
  # A cd that is not joined to the push by && may fail and leave the push where it was (cd x || true; git push),
  # so then both places are checked (push_sure=0)
  IFS=$'\037' read -r push_cd push_gitdir push_unknown push_sure <<<"$(perl -0ne 'exit unless /(?:^|[\s;&|(`])(?:\S*\/)?git\b[^;&|\n]*?\s+push\b/;
      my $pre = substr($_, 0, $-[0]); my ($d, $g, $u, $sure) = ("", "", 0, 1); my @stack;
      # keep the text of a quoted word, but its separators and spaces cannot start or end a command
      $pre =~ s{"((?:[^"\\]|\\.)*)"|\x27([^\x27]*)\x27}{ my $s = defined $1 ? $1 : $2; $s =~ s/[;&|\n(){}]/_/g; $s =~ s/[ \t]/\x01/g; $s }gse;
      # a cd inside a finished subshell (cd x && make) does not move the push
      1 while $pre =~ s/\([^()]*\)//g;
      while ($pre =~ /(?:^|[;&|(\n{])\s*(?:builtin\s+)?(cd|pushd|popd)(?:[ \t]+((?:-[LPe@]+[ \t]+|--[ \t]+)*)([^\s;&|()]+))?/g) {
        my ($c, $t) = ($1, $3);
        $sure = 0 if substr($pre, $+[0]) =~ /;|\|\||\n|(?<!\|)\|(?!\|)/;
        if ($c eq "popd") { $d = @stack ? pop @stack : ""; next }
        push @stack, $d if $c eq "pushd";
        $t = "~" unless defined $t; $t =~ s/\x01/ /g;
        if ($t =~ /[\$`*?\[]/ || $t eq "-") { $u = 1; next }
        $t =~ s{^~(?=/|$)}{$ENV{HOME}}; $d = ($t =~ m{^/} || $d eq "") ? $t : "$d/$t" }
      my ($tail) = $pre =~ /([^;&|(\n]*)$/;
      while ($tail =~ /(?:^|\s)GIT_DIR=(\S+)/g) { $g = $1 }
      $g =~ s/\x01/ /g;
      while ($pre =~ /(?:^|[;&|(\n])\s*export\s+GIT_DIR=(\S+)/g) { $g = $1 }
      $u = 1 if $g =~ /[\$`]/;
      print "$d\037$g\037$u\037$sure"' <<<"$cmd_msg")"
  [ "${push_unknown:-0}" = 1 ] && soft_block "git push after cd / GIT_DIR= with a variable: the repository (and its branch) cannot be read"
  case "$push_dir" in /*) push_dir_eff="$push_dir" ;; "") push_dir_eff="${push_cd:-.}" ;; *) push_dir_eff="${push_cd:-.}/$push_dir" ;; esac
  # git_at <args>: run git where the push will run
  git_at() {
    if [ -n "$push_gitdir" ]; then GIT_DIR="$push_gitdir" git -C "$push_dir_eff" "$@"; else git -C "$push_dir_eff" "$@"; fi
  }
  cur_branch="$(git_at rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  # A cd that may not have happened: the push may run where it started, so a protected branch there counts too
  if [ "${push_sure:-1}" = 0 ] && [ -n "$push_cd" ] && ! is_protected_branch "$cur_branch"; then
    alt_branch="$(git -C "${push_dir:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    is_protected_branch "$alt_branch" && { cur_branch="$alt_branch"; push_dir_eff="${push_dir:-.}"; }
  fi
  # Positional arguments after push, minus options and their values (remote, refspec...). Quotes are removed ('HEAD' is HEAD)
  push_args="$(perl -ne 'if (/\bpush\b([^;&|)]*)/) { my @w = split " ", $1; my @p; while (@w) { my $x = shift @w; $x =~ s/["\x27]//g; if ($x =~ /^(-o|--push-option|--repo|--receive-pack|--exec)$/) { shift @w; next } next if $x =~ /^-/; push @p, $x } print join(" ", @p) }' <<<"$cmd_msg")"
  read -r -a push_pos <<<"$push_args"
  if [ "$push_main" = 0 ] && is_protected_branch "$cur_branch"; then
    if [ "${#push_pos[@]}" -le 1 ]; then
      push_main=1
    else
      for r in "${push_pos[@]:1}"; do
        # head is HEAD on a case-insensitive file system (the macOS default)
        case "$(tr '[:lower:]' '[:upper:]' <<<"$r")" in HEAD|+HEAD|@|+@) push_main=1 ;; esac
      done
    fi
  fi
  if [ "$push_main" = 1 ]; then
    # First-push exception: no remote-tracking ref locally AND the remote itself has no branch (ls-remote exit 2),
    # allow with approval unless forced. An unreachable remote or any other result blocks
    first_push=0
    if [ -z "$(git_at for-each-ref --count=1 refs/remotes 2>/dev/null)" ] \
       && ! grep -Eq "${GIT_PUSH}([^|;&]*)[[:space:]](-f|--force|--force-with-lease)([[:space:]=]|$)|[[:space:]]\+[^[:space:]]" <<<"$cmd_msg"; then
      GIT_TERMINAL_PROMPT=0 perl -e 'alarm 15; exec @ARGV' env ${push_gitdir:+GIT_DIR="$push_gitdir"} git -C "$push_dir_eff" ls-remote --exit-code --heads "${push_pos[0]:-origin}" >/dev/null 2>&1
      [ $? = 2 ] && first_push=1
    fi
    if [ "$first_push" = 1 ]; then
      add_ask "git push (first push to a protected branch): the remote has nothing yet. Confirm the user has OKed this first push to this repository and branch in chat before approving"
    else
      block "pushing to a protected branch (${PROTECTED_LIST}) is not allowed, force included (create a branch and open a PR)"
    fi
  fi
fi
# Force push to a non-protected branch is allowed with approval: it rewrites history, so only when the user OKed that target in chat
# A refspec starting with "+" (git push origin +feat/x) is also a force push
if grep -Eq "${GIT_PUSH}([^|;&]*)[[:space:]](-f|--force|--force-with-lease)" <<<"$cmd_msg" \
   || grep -Eq "${GIT_PUSH}([^|;&]*)[[:space:]]\+[^[:space:]]" <<<"$cmd_refspec"; then
  add_ask "git push --force: overwrites remote history. Confirm the user has OKed a force push of this branch in chat before approving"
fi

# Ordinary push to a work branch (no force): ask unless confirm_push is off
if [ -z "$pending_ask" ] && [ "$(opt_bool CONFIRM_PUSH true)" = true ] \
   && grep -Eq "${GIT_PUSH}([[:space:]\"';&|)]|$)" <<<"$cmd_msg"; then
  add_ask "git push: confirm the user wants this push before approving"
fi

if pack_on github; then
# --- GitHub pack ---
# graphql with a query read from a variable or a file: a mutation cannot be ruled out
if grep -Eq "${P}gh[[:space:]]+api[[:space:]]+graphql([[:space:]]|$)" <<<"$cmd" \
   && grep -Eq "query=[\"']?(\\$|@)" <<<"$cmd"; then
  soft_block "gh api graphql with a query taken from a variable or a file (a mutation cannot be ruled out)"
fi
if grep -Eq 'gh([^|;&]*)[[:space:]](secret[[:space:]]+(set|delete)|variable[[:space:]]+delete|repo[[:space:]]+delete|release[[:space:]]+delete)' <<<"$cmd"; then
  block "changing GitHub secrets and deleting repos / releases are not allowed"
fi
# Manual workflow runs are allowed only with approval, after the user OKed them in chat
if grep -Eq 'gh([^|;&]*)[[:space:]]workflow[[:space:]]+run' <<<"$cmd"; then
  add_ask "gh workflow run: confirm the user has OKed this run in chat before approving"
fi
if grep -Eq 'gh([^|;&]*)[[:space:]]pr[[:space:]]+merge([^|;&]*)[[:space:]](--admin|--auto)' <<<"$cmd"; then
  block "gh pr merge --admin / --auto is not allowed (merge a checked PR normally)"
elif grep -Eq 'gh([^|;&]*)[[:space:]]pr[[:space:]]+merge([[:space:]]|$)' <<<"$cmd"; then
  add_ask "gh pr merge: confirm the user has OKed merging this PR in chat before approving"
fi
# gh_api_settings_ok <command>: 0 for a lone mutating gh api call to a repository-settings path.
# Only commands made of safe characters (no quotes, pipes, expansions) are split into tokens and matched on method x path x field.
# Exactly one positional argument; unknown flags are rejected
gh_api_settings_ok() {
  local c=" $1 " a m="" path="" input=0 i=2 key
  local -a t keys=()
  c="${c// 2>&1 / }"; c="${c// 2>&1 / }"   # drop only a standalone 2>&1
  [[ "$c" =~ ^[][[:alnum:]_./=:@,[:space:]-]+$ ]] || return 1
  read -ra t <<<"$c"
  [ "${t[0]:-}" = gh ] && [ "${t[1]:-}" = api ] || return 1
  while [ "$i" -lt "${#t[@]}" ]; do
    a="${t[$i]}"; i=$((i + 1))
    case "$a" in
      -X|--method) m="${t[$i]:-}"; i=$((i + 1)) ;;
      --method=*) m="${a#*=}" ;;
      -f|-F|--field|--raw-field) key="${t[$i]:-}"; i=$((i + 1)); [[ "${key#*=}" != @* ]] || return 1; keys+=("${key%%=*}") ;;
      --field=*|--raw-field=*) key="${a#*=}"; [[ "${key#*=}" != @* ]] || return 1; keys+=("${key%%=*}") ;;   # a value of @file can send a local file, so reject it
      --input) input=1; i=$((i + 1)) ;;
      --input=*) input=1 ;;
      -H|--header|-q|--jq|-t|--template) i=$((i + 1)) ;;
      --header=*|--jq=*|--template=*|-i|--include|--silent|--verbose) ;;
      -*) return 1 ;;
      *) [ -z "$path" ] || return 1; path="$a" ;;
    esac
  done
  m="$(tr '[:lower:]' '[:upper:]' <<<"$m")"
  if [ -z "$m" ]; then
    { [ "${#keys[@]}" -gt 0 ] || [ "$input" = 1 ]; } && m=POST || return 1
  fi
  local rest
  [[ "$path" =~ ^repos/[^/]+/[^/]+(/.*)?$ ]] || return 1
  rest="${BASH_REMATCH[1]}"
  case "$rest" in
    "")
      # The repository itself: PATCH only, and only feature / merge-method / description / security keys (not visibility, rename, default branch, archive)
      [ "$m" = PATCH ] && [ "$input" = 0 ] || return 1
      for key in ${keys[@]+"${keys[@]}"}; do
        [[ "$key" =~ ^(delete_branch_on_merge|allow_[a-z_]+|has_[a-z_]+|description|homepage|web_commit_signoff_required|(squash_)?merge_commit_(title|message)|security_and_analysis\[[a-z_]+\]\[status\])$ ]] || return 1
      done ;;
    /rulesets) [ "$m" = POST ] ;;
    /rulesets/[0-9]*) [[ "$rest" =~ ^/rulesets/[0-9]+$ ]] && { [ "$m" = PUT ] || [ "$m" = DELETE ]; } ;;
    /private-vulnerability-reporting|/vulnerability-alerts) [ "$m" = PUT ] || [ "$m" = DELETE ] ;;
    /actions/permissions|/actions/permissions/*) [[ "$rest" =~ ^/actions/permissions(/[A-Za-z0-9_-]+)*$ ]] && [ "$m" = PUT ] ;;
    *) return 1 ;;
  esac
}
# Mutating gh api calls can bypass ask and block rules, so they are blocked (GET only).
# Exception: a lone call to a repository-settings path (the repo itself, rulesets, private-vulnerability-reporting, vulnerability-alerts, actions/permissions)
# is allowed with approval. Methods and fields are narrowed per path (gh_api_settings_ok)
if grep -Eq "${P}gh[[:space:]]+api([^|;&]*)[[:space:]](-X|--method)[[:space:]=]*[\"']?(POST|PUT|PATCH|DELETE|post|put|patch|delete)" <<<"$cmd" \
   || { grep -Eq "${P}gh[[:space:]]+api([^|;&]*)[[:space:]](-[fF][^[:space:]]*|--field|--raw-field|--input)([[:space:]=]|$)" <<<"$cmd" \
        && ! { grep -Eq "${P}gh[[:space:]]+api[[:space:]]+graphql([[:space:]]|$)" <<<"$cmd" \
               && ! grep -Eiq 'mutation|--input' <<<"$cmd"; }; }; then
  if [ "$(wc -l <<<"$cmd" | tr -d ' ')" -le 1 ] && gh_api_settings_ok "$cmd"; then
    add_ask "gh api (repository settings change): confirm the user has OKed this repository and setting in chat before approving"
  else
    block "mutating gh api requests (POST/PUT/PATCH/DELETE, -f/-F/--input) are not allowed (except a lone call to a repository-settings path)"
  fi
fi
fi

# --- git operations that discard uncommitted work (ask) (core) ---
# Untracked files are not in git history and cannot be restored after clean or reset --hard
if grep -Eq "${GIT}clean([[:space:]\"']|$)" <<<"$cmd_msg" && ! grep -Eq "${GIT}clean([^|;&]*)[[:space:]](-[a-zA-Z]*n[a-zA-Z]*|--dry-run)([[:space:]]|$)" <<<"$cmd_msg"; then
  add_ask "git clean: deletes untracked files. Confirm the user has OKed this in chat before approving"
elif grep -Eq "${GIT}(reset([^|;&]*)[[:space:]]--hard|stash[[:space:]]+(drop|clear)|branch([^|;&]*)[[:space:]]-D|checkout[[:space:]]+(-f|--force|--|\.)|checkout([^|;&]*)[[:space:]]--|switch([^|;&]*)[[:space:]](-f|--force|--discard-changes))([[:space:]\"']|$)" <<<"$cmd_msg"; then
  add_ask "destructive git operation (reset --hard / checkout -- / stash drop / branch -D ...): loses uncommitted changes or a branch. Confirm the user has OKed this in chat before approving"
elif grep -Eq "${GIT}restore([[:space:]\"']|$)" <<<"$cmd_msg" \
     && ! { grep -Eq "${GIT}restore([^|;&]*)[[:space:]](--staged|-S)([[:space:]]|$)" <<<"$cmd_msg" && ! grep -Eq "${GIT}restore([^|;&]*)[[:space:]](--worktree|-W)([[:space:]]|$)" <<<"$cmd_msg"; }; then
  add_ask "git restore: discards working tree changes. Confirm the user has OKed this in chat before approving"
fi
# Deletes whose targets come from another command (xargs rm, find -delete / -exec rm): the files cannot be listed beforehand
if grep -Eq "${P}xargs([^|;&]*)[[:space:]]rm([[:space:]]|$)|${P}find[[:space:]][^|;&]*[[:space:]](-delete|-exec(dir)?[[:space:]]+rm)([[:space:]]|$)" <<<"$cmd_msg"; then
  add_ask "xargs rm / find -delete / find -exec rm: deletes files chosen at run time. Confirm the user has OKed this in chat before approving"
fi

# --- Operations that change the machine, run fetched code, or delete the home directory (core) ---
# The receiving side may be a path (/bin/sh), wrapped (env / sudo -E / command), or another interpreter (python3, perl, node ...).
#   - a shell anywhere later in the pipe (curl | grep -v '#' | bash still runs the fetched text)
#   - an interpreter right after curl, or after tee / cat only (they pass the text through unchanged)
#   - an interpreter later that reads its program from stdin (no arguments, or -). curl | jq | perl -ne '...' reads data
PIPE_WRAP="((sudo|env|command|exec|nohup|nice)([[:space:]]+-[^[:space:]]+)*[[:space:]]+)*([^[:space:]|;&]*/)?"
PIPE_INTERP="(python[0-9.]*|perl|ruby|node|deno|bun|php|lua|osascript)"
if grep -Eq "(curl|wget)([^;&]*)\|[[:space:]]*${PIPE_WRAP}(ba|z|da|k|c|tc|fi)?sh([[:space:]\"';&|)]|$)" <<<"$cmd" \
   || grep -Eq "(curl|wget)[^;&|]*(\|[[:space:]]*(sudo[[:space:]]+)?(tee|cat)([[:space:]][^;&|]*)?)*\|[[:space:]]*${PIPE_WRAP}${PIPE_INTERP}([[:space:]\"';&|)]|$)" <<<"$cmd" \
   || grep -Eq "(curl|wget)([^;&]*)\|[[:space:]]*${PIPE_WRAP}${PIPE_INTERP}[[:space:]]*(-[[:space:]]*)?([;&|)]|$)" <<<"$cmd"; then
  block "piping curl/wget output into a shell or interpreter is not allowed (do not run code from an untrusted source)"
fi
# Forms other than a pipe: process substitution (bash <(curl ...)) and passing fetched text to bash -c / eval (bash -c "$(curl ...)").
FETCH="[[:space:]]*(command[[:space:]]+)?([^[:space:]()]*/)?(curl|wget)[[:space:]]"
SHELL_OPTS="(bash|sh|zsh|dash)([[:space:]]+-[^[:space:]]+)*"
if grep -Eq "${P}${SHELL_OPTS}[[:space:]]+(<[[:space:]]*)?<\(${FETCH}" <<<"$cmd" \
   || grep -Eq "(^|[;&|(\`]|\\\$\()[[:space:]]*(source|\.)[[:space:]]+(<[[:space:]]*)?<\(${FETCH}" <<<"$cmd" \
   || grep -Eq "${P}(${SHELL_OPTS}[[:space:]]+-[A-Za-z]*c|eval)[[:space:]]+[\"']?(\\\$\(|\`)${FETCH}" <<<"$cmd"; then
  soft_block "runs code fetched by curl/wget through process substitution or bash -c / eval (do not run code from an untrusted source). Confirm the user has OKed the source and contents in chat before approving"
fi
if grep -Eq "${P}rm[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*[rR][A-Za-z]*[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(/|~|\\\$HOME|\\\$\\{HOME\\}|\"\\\$HOME\")/?\*?([[:space:]\"';&|]|$)" <<<"$cmd"; then
  block "rm -r on the root or home directory is not allowed"
fi
# rm -r in the working tree is asked (untracked files cannot be restored even with git; same as git clean).
# No confirmation when every target is a build artifact or a temp directory. A variable ($dir) has unknown contents, so it is asked
rm_targets="$(perl -ne 'while (/(?:^|[\s;&|(])rm\s+((?:-\S+\s+)*)([^;&|<>]*)/g) { my ($o, $a) = ($1, $2); next unless $o =~ /(^|\s)(-[A-Za-z]*[rR]|--recursive)/; for (split " ", $a) { s/^["\x27]|["\x27]$//g; print "$_\n" } }' <<<"$cmd_msg" 2>/dev/null)"
if [ -n "$rm_targets" ]; then
  # The root or the home directory anywhere in the list, after -- or long options too (rm -rf -- ~, rm --recursive /)
  while IFS= read -r t; do
    case "$t" in
      /|/\*|'~'|'~/'|'~/*'|'$HOME'|'$HOME/'|'$HOME/*'|'${HOME}'|'${HOME}/'|'${HOME}/*') block "rm -r on the root or home directory is not allowed" ;;
    esac
  done <<<"$rm_targets"
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    if grep -Eq '(^|/)\.\.(/|$)' <<<"$t" || ! grep -Eq '^(\./)?([^/]+/)*(node_modules|dist|build|out|coverage|\.next|\.nuxt|\.turbo|\.cache|\.parcel-cache|target|DerivedData|\.build|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.tox|\.venv|venv)/?$|^/(private/)?tmp/|^/var/folders/|^(~|\$HOME|\$\{HOME\})/Library/(Caches|Developer/Xcode/DerivedData)/' <<<"$t"; then
      add_ask "rm -r: deletes a directory that is not a build artifact ($t). Untracked files cannot be restored. Confirm the user has OKed this in chat before approving"
      break
    fi
  done <<<"$rm_targets"
fi
if grep -Eq "${P}sudo[[:space:]]" <<<"$cmd"; then
  add_ask "sudo: an administrator operation. Confirm the user has OKed this in chat before approving"
elif grep -Eq "${P}launchctl[[:space:]]+(bootstrap|load|enable)([[:space:]]|$)" <<<"$cmd" \
     || { grep -Eq "${P}crontab([[:space:]]|$)" <<<"$cmd" && ! grep -Eq "${P}crontab[[:space:]]+-l([[:space:]]|$)" <<<"$cmd"; } \
     || grep -Eq "${P}defaults[[:space:]]+(-currentHost[[:space:]]+)?(write|delete)([[:space:]]|$)" <<<"$cmd"; then
  add_ask "launchctl registration / crontab / defaults write: leaves machine settings behind. Confirm the user has OKed this in chat before approving"
fi

[ -n "$ambiguous" ] && soft_block "$ambiguous"
[ -n "$soft_reason" ] && add_ask "$soft_reason"
[ -n "$pending_ask" ] && ask "$pending_ask"
exit 0
