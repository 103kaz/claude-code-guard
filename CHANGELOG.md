# Changelog

## Unreleased

- `confirm_push` now defaults to `false`: a push to a work branch no longer asks. Pushes to protected branches are still blocked, and a force push or a push whose target cannot be read still asks. Set `confirm_push` to `true` in the plugin settings to ask on every push as before.

## 0.3.0

- **Breaking:** `/code-guard:review-loop`, `/code-guard:doc-code-consistency` and the `doc_check_before_pr` setting are removed, together with the three docs-check hooks (`doc-check.sh`). code-guard keeps the guards, the verify loop and `/code-guard:setup-verify`.

## 0.2.2 (2026-10-22)

- The Bash guard no longer blocks a command that only reads a protected path. A protected path (`~/.claude` hooks / settings / plugins, `.claude/settings*`, `.githooks`, `.git/config`, `.git/hooks`) is now judged by the write target only: the word after a redirect `>`, the destination of `cp` / `install` / `rsync`, and any argument of the other write commands. `cp ~/.claude/settings.json .`, a redirect to another file in the same command, and `awk '$1 > 3' ~/.claude/hooks/a.sh` pass. When the destination cannot be read for sure (quotes, `\`, `$`, a trailing `+`, `-t`, an option after the first operand) or the command is `ln`, all the arguments are judged as before.
- `trust-verify.sh` shows valid UTF-8 text (Japanese comments, for example) as is. Control characters are still shown as `^X`; ESC-like, direction-changing and invisible characters as `<U+XXXX>`; bytes that are not UTF-8 as `M-X`.
- The README says that a push to `main` is blocked in a scratch repository too, that the sandbox `excludedCommands` match only the start of a command, and how to keep `.claude/verify.sh` as a thin entry that calls a project script (the approval does not cover the called file).

## 0.2.1 (2026-10-21)

- With `doc_check_before_pr` on, typing `/code-guard:doc-code-consistency` yourself now counts as the check. It does not go through the Skill tool, so it was never recorded and `gh pr create` stayed blocked. A `UserPromptSubmit` hook records the commit when the prompt starts with the command.

## 0.2.0 (2026-10-21)

- The verify loop runs `.claude/verify.sh` only while its content is the one the user approved with `scripts/trust-verify.sh` (SHA-256, per project directory, kept under `~/.claude/code-guard/verify-trust/`; `trust-verify.sh` shows the whole file). An unapproved or changed script is skipped and the user is told once per session. **Existing projects must approve their `verify.sh` once.** Claude running `trust-verify.sh` asks.
- `scripts/check-enabled.sh`: a SessionStart hook for the user's own settings that warns when a project's settings switch code-guard off (`enabledPlugins`, or `disableAllHooks`). The plugin cannot do this itself.
- A SessionStart hook names `jq` or `perl` when it is missing (silent otherwise, never blocks), so the problem shows before the guards start blocking.
- The README, spec and plugin descriptions now present the plugin as a harness plus loops (verify loop, review loop, docs check).
- `gh api -X Delete` (and other mixed-case methods) is now read as a mutating method. A bare `*`, `*.*` or `.*` is expanded in the current directory and blocked when a secret file name is among the matches (`cat *` next to `prod.tfvars`). `protected_branches` takes `*` (`release/*`). An MCP tool without a SQL word in its name now asks for `GRANT x TO`, `REVOKE x FROM`, `COPY t FROM/TO`, `MERGE t USING`, `CALL f(`, and `DELETE t WHERE`.
- The verify loop tells the user once per session, after files changed, when `.claude/verify.sh` is missing and how to create it (`/code-guard:setup-verify`). `verify_missing_notice` (default `true`) turns it off.
- `/code-guard:review-loop`: runs verify, review and fix over the branch diff until a lap finds nothing.

## 0.1.0 (2026-10-21)

- First version: Bash / file-tool / MCP guards, the github / terraform / gcp / cloudflare packs, the verify loop, `/code-guard:setup-verify`, and `/code-guard:doc-code-consistency`.

### Known limits

- The guards do not parse the shell. Ambiguous shapes (quoted or split command names and subcommands, `git push` arguments built from quotes or expansions, line continuations in a command with a guarded command word, odd heredoc markers or terminators, a failing check) ask instead of being judged. The same operation through python and similar interpreters is not stopped.
- Heredoc bodies are treated as data unless the command contains a known interpreter (`bash`, `sh`, `eval`, `python` and similar). The `$( )` and backtick parts of an unquoted heredoc (`<<EOF`) are still judged, because the shell runs them. A body run by another program (`ssh host <<EOF`, `ksh`, `./x.sh` after writing it) is not asked.
- Brace expansion and `$@` in a `git push` argument (`ma{in,}`, `{main,x}`), and a `git push` run by `xargs`, `parallel` or `find -exec` (`echo main | xargs git push origin`), are not read: a push to a protected branch written that way is asked, not blocked (with `confirm_push` off too).
- A `branch` / `ref` nested anywhere in an MCP tool's input counts, so an unrelated nested field named `ref` that holds `main` blocks the call. A read tool whose name has the word `push` (`get_status_push`) is judged as a branch-writing tool.
- A command longer than 100000 characters is asked without being read.
- A secret file name built at run time is read only when a command substitution uses `printf`, `rev`, `tr`, `base64 -d`, `xxd -r` or `echo -e` (asked). A name built from a variable (`f=.e; cat ${f}nv`, `f=$(printf .e%snv); cat $f`), by another command, or by ANSI-C quoting (`cat $'\x2eenv'`) passes. Such a substitution asks even where it is not run (inside single quotes) or only cleans up text (`$(git branch --show-current | tr -d '\n')`).
- A word that is only `*`, `*.*` or `.*` is expanded in the current directory of the hook, so a `cd dir && cat *` is not looked at (the directory the command moves to is not read).
- When a grep or rg is in the command, quoted strings without a slash are not inspected for `*.pem` / `*.key` (`grep -rn foo . ; cat "server.key"` passes).
- Secret names are matched without case, except `.Key` (a common JSON field). Other spellings of a field path such as `jq '.ITEM.KEY'` are blocked as key files.
- `cat -- -m "<file>"`: a value after `--` that follows a message flag is treated as message text.
- For an MCP tool without `query`, `sql`, `execute`, `exec` or `migration` in its name, SQL is found only by the shapes listed in the spec. Other forms pass (`DO $$ ... $$`, `EXEC sp_x`). Text that reads like one of those shapes asks, so plain messages such as "call me (555-1234)", "grant access to bob", "create type definitions", "we drop index cards" or "drop table soon" ask too, including those sent to a chat or mail tool. This is kept on purpose: narrowing the shape (to a statement that starts a sentence or ends with `;`) would let `run` / `statement` tools pass a statement written without them.
- A repository can switch the plugin off through `enabledPlugins` in its own settings. The plugin cannot notice (it runs no hooks then); `scripts/check-enabled.sh` registered in the user's settings warns about the two project settings files, not about managed settings or other places.
- Per-project configuration is not handled.
- The approval of a `verify.sh` is a hash checked just before the run; a file changed between the check and the run is not caught. The approval covers `verify.sh` itself, not the files it calls. The ask on `trust-verify.sh` does not see a name built at run time. `bash .claude/verify.sh` typed by Claude is not stopped (the loop's own run is what the approval gates).
