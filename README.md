# code-guard

[日本語](README.ja.md)

A Claude Code plugin that builds a harness into your project. The harness is hooks that stop dangerous operations. A verify loop runs your project's checks before Claude finishes a turn, and `/code-guard:setup-verify` creates the script it runs. The review loop and the docs check were removed in 0.3.0.

## What it does not guarantee

- The guards read command strings and file paths. They are not a sandbox. The same operation routed through python or another interpreter is not stopped.
- The guards do not parse the shell. Shapes they cannot read (a quoted or split command name or subcommand, a `git push` argument built from quotes or expansions, a line continuation inside a guarded command, an odd heredoc marker) are sent to a confirmation (ask) instead of being judged. See [Known limits](CHANGELOG.md#known-limits).
- Grep is stopped only when its `path` is a secret file. A directory search whose results include secret files cannot be stopped.
- The verify loop makes Claude fix failures. It is not enforcement: a turn can still end without running `verify.sh`.
- The hook input format and the plugin mechanism can change between Claude Code versions. See [Tested versions](#tested-versions).
- A repository can switch the plugin off: `enabledPlugins` in the project's `.claude/settings.json` overrides the user's settings. Claude's own edits to those files are stopped (asked or blocked), but a setting that arrived with a cloned repository is not. The plugin cannot detect this itself (a switched-off plugin runs no hooks); see [When a repository switches the plugin off](#when-a-repository-switches-the-plugin-off).

## Install

See [docs/setup.md](docs/setup.md) for the terminal and the desktop app, how to check the install, settings, update and uninstall. In short, run these in your shell, then start a new session:

```bash
claude plugin marketplace add 103kaz/claude-code-guard
claude plugin install code-guard@claude-code-guard
```

Requires bash 3.2+, `jq` and `perl`, on macOS or Linux. Windows is not supported. If `jq` or `perl` is missing, the guards block everything they cover and say how to install the tool. A SessionStart hook also names the missing tool when a session opens (silent when both are present).

## What is guarded

Each decision is one of: **block** (exit 2, cannot be approved), **ask** (a confirmation to the user), or pass.

### Core rules (cannot be turned off)

| Area | Block | Ask |
|---|---|---|
| Protected branches | push to a protected branch (a bare `git push` on one, `heads/main`, and a repository reached through `cd` or `GIT_DIR=` included), a lone `:` or a wildcard refspec | first push to an empty remote |
| Push shape | `--no-verify`, `--mirror`, `--delete` / `-d` / `:ref`, `--prune`, `--all` | force push (`+ref` included), every work-branch push when `confirm_push` is on |
| Hook bypass | `core.hooksPath`, `git -c`, `--config-env`, `GIT_CONFIG_*`, alias / include settings, removing the core / alias / include section, git with `HOME=` / `XDG_CONFIG_HOME=`, writes to `~/.gitconfig` / `~/.config/git/config`, `--no-verify` on commit / merge (`commit -n`) | |
| Secrets | `.env` / `.env.*` (samples excluded), `*.tfvars`, `*.tfstate`, `*token*.txt`, `*.pem`, `*.key`, `~/.ssh`, signing assets, service account keys, CLI credentials, git credentials (`~/.git-credentials`, `git credential fill`), keychain values. Names after `<`, `rev:` and `--opt=` (except terraform's `-var-file=`), and globs or braces that expand to one (`.en?`, `.e{n,x}v`) are included. Names are matched without case (`.ENV`) | a command substitution that builds a string (`cat $(printf .e%snv)`) |
| Harness | Bash writes to `~/.claude` settings / hooks / plugins, `.claude/settings*`, `.githooks`, `.git/config`, `.git/hooks` (submodules under `.git/modules/` included). Writes are redirects, `sed` / `perl` / `ruby -i`, `awk -i inplace`, file commands, `dd`, `rsync`, `curl -o`, `wget -O`, and `git checkout` / `restore` / `apply` / `am`; relative paths after `cd` count. Only the write target is judged, so reading a protected path (`cp ~/.claude/settings.json .`) is not blocked | Bash writes to `.claude/hooks`, `.claude/verify.sh`, `.github/workflows` |
| Fetched code | `curl` / `wget` piped to a shell (`/bin/sh`, `env bash` ..., at any later stage) or an interpreter (`python3`, `perl`, `node` ...; right after `curl`, or later when it reads its program from stdin) | process substitution, `bash -c "$(curl ...)"`, `eval` |
| Deleting | `rm -r` on `/` or `~` (after `--` and long options too) | `rm -r` outside build directories, `git clean`, `reset --hard`, `restore`, `checkout [<rev>] --`, `stash drop`, `branch -D`, `xargs rm`, `find -delete` / `-exec rm` |
| Machine settings | | `sudo`, `launchctl` registration, `crontab`, `defaults write` |

Protected branches are judged by branch name, not by whether the repository is a throwaway. A push to `main` in a scratch repository is blocked too, unless it is a first push (no force, no remote-tracking branch yet) to a reachable, empty remote; that one asks. To test pushing, use a work branch.

Text that only appears in a commit message or PR body (`-m`, `--body`, heredoc) is not judged, unless the command also contains `bash -c`, `eval`, python and similar. A `$(...)` or backtick inside a double-quoted value or an unquoted heredoc runs, so it is judged. The `git push` refspec rules (`:`, a lone `:`, wildcards, brace expansion) judge the text with its quotes stripped, so a command that only searches for or prints such text (`grep -n "git push *" f`) would read like a push. When the whole command is made of `grep`, `egrep`, `fgrep`, `rg`, `ag`, `echo`, `printf`, `head`, `tail`, `wc`, `ls` and `cat` segments joined by `&&`, `||`, `;` and `|`, and every argument is a plain word or a quoted string without `$`, a backtick or an escape, its quoted strings are not read. Any other command, including one with `$(...)`, `<(...)`, a `#`, a newline, a redirect, an option that runs a program (`--pre`, `--pager`) or any other command, is judged as before. An unquoted mention (`echo git push *`) is still judged.

### File tools (`guard-file.sh`)

Plugins cannot ship permission rules, so these live in a hook.

| Tool | Block | Ask |
|---|---|---|
| Read, Grep | secret files (same patterns as the core secret rules) | |
| Edit, Write, MultiEdit, NotebookEdit | `*.tfvars`, `.git/config`, `.git/hooks`, `~/.gitconfig`, `~/.config/git/config` | `~/.claude`, `.claude/settings*`, `.claude/hooks`, `.claude/verify.sh`, `.githooks`, `.github/workflows` |

### MCP tools (`guard-mcp.sh`)

A tool whose name contains `delete`, `destroy`, `drop`, `purge`, `remove`, `truncate`, `wipe`, `erase`, `deploy`, `publish`, `unpublish`, `rollback` or `secret` asks, and so do `merge_pull_request`, `merge_branch`, `push_files`, `push_branch`, `force_push`, `create_or_update_file`, `update_file`, `create_commit` and `update_ref`. Those that write to a branch (`push_files`, `push_branch`, `force_push`, `create_or_update_file`, `update_file`, `create_commit`, `update_ref`, and `delete_file`, `create_file`, `write_file`, `edit_file`, `commit_files` when given a branch) are blocked when their `branch` or `ref` argument (at any depth of the input) is a protected branch. A tool whose name has the word `push` (`git_push`, `push`) is treated the same way (a `refspec` is read by its destination) and asks when it is given a `branch`, `ref` or `refspec`, or when `push` is the last word of its name (`git_push` with no argument pushes the current branch). Tools named `query`, `sql`, `execute`, `exec`, `statement`, `statements`, `migration`, `migrations` or `migrate` ask when the input contains a data-changing keyword (`DROP`, `DELETE`, `UPDATE`, `INSERT`, `MERGE`, `GRANT`, `REVOKE`, `COPY` and similar; comments are removed first). Any other tool is judged only by the values of fields named `sql`, `statement`, `statements` or `stmt` (at any depth), with the same keyword rule; its other fields (`text`, `message`, `query`, `q`) are not read, so a message that reads like a statement passes, and so does SQL in a field with another name. Tools whose name starts with `get`, `list`, `search`, `read`, `describe`, `fetch`, `find`, `view` or `show` are not judged by their input unless the name also has a word that writes (`get_or_create`, `find_and_replace`: `or`, `and`, `then`, `create`, `update`, `insert`, `upsert`, `set`, `put`, `write`, `add`, `apply`, `replace`, `save`, `edit`, `modify`, `send`). Without `jq` or `perl` the MCP guard blocks every MCP call.

### Commands chained to a sandbox-excluded command (`guard-chain.sh`)

With the sandbox on, a command listed in `sandbox.excludedCommands` runs outside the sandbox only as the whole command. Chained with `&&`, `||`, `;`, `|` or a newline it runs inside the sandbox and fails (a git write under `.git`, a `gh` call). The guard reads `sandbox.enabled` and `sandbox.excludedCommands` from `~/.claude/settings.json`, `.claude/settings.json` and `.claude/settings.local.json`, and blocks such a chain with a message to run each command in its own call. Quoted text, redirects such as `2>&1` and heredoc bodies are not separators. A pattern matches a whole segment; a trailing space-star (`git push *`) or `:*` also matches the bare command, and a one-word pattern (`git`) matches only the bare command. A command that cannot be read to the end (an unterminated quote) passes. Not seen: a chain inside `$(...)` or `bash -c "..."`, an environment prefix (`FOO=1 git push && ls`), a subshell, `if ...; then ...; fi`. It does nothing when the sandbox is off, no pattern is set, or the settings cannot be read. It is a usability aid, not a security guard, and has no setting to turn it off.

### Packs

On by default. Turn one off when its policy does not fit how you work. Secret reads stay in the core even when a pack is off.

| Pack | Decisions |
|---|---|
| `github` | block: `gh secret set/delete`, `gh variable delete`, `gh repo delete`, `gh release delete`, `gh pr merge --admin/--auto`, `gh repo edit --visibility`, mutating `gh api` (a lone call to a repository-settings path asks). ask: `gh pr merge`, `gh workflow run`, `gh release create`, `gh gist create` |
| `terraform` | block: `destroy`, `import`, `taint`, `untaint`, `force-unlock`, state changes, plan + apply in one command, `-auto-approve` and similar. ask: `apply` of a saved plan file. `terraform fmt` runs after Edit / Write of `.tf` files |
| `gcp` | block: deleting disks, instances, projects, storage, SQL instances, `gsutil rm/rb`, Secret Manager values and access tokens |
| `cloudflare` | block: `wrangler` deploy / delete / rollback / secret changes |

## Verify loop

When files changed during a turn and the project has `.claude/verify.sh`, the Stop hook runs it. On failure the last 80 lines of output go back to Claude (exit 2). After `verify_max_retry` failures in one turn (default 3) the user is told and the stop passes. With no `.claude/verify.sh` the loop does not run; if files changed, the user is told once per session that it can be created with `/code-guard:setup-verify` (turn off with `verify_missing_notice`).

"Changed" compares a fingerprint of HEAD, the tracked diff and the untracked files against the one taken when the prompt was submitted, so changes that were already there do not trigger it. Outside git, a file modified, renamed or deleted after the prompt was submitted counts.

A `verify.sh` from a cloned repository is someone else's code, so the loop runs it only while its content is the one you approved. Until then it is skipped and you are told once per session. Read the script, then approve it in a terminal:

```bash
bash <plugin dir>/scripts/trust-verify.sh [project dir]
```

It shows the whole file (control characters made visible; valid UTF-8 text such as Japanese comments is shown as is) and its SHA-256, and approves only when you type `yes`. The approval is kept per project directory under `~/.claude/code-guard/verify-trust/`; changing the file takes it away, and a symlinked `verify.sh` is never approved. Claude running `trust-verify.sh` (or the approval code) is asked by the Bash guard, and writing the approval files from Bash is blocked, so a Claude that answers `yes` itself still needs your confirmation. The ask is an aid: a script name built at run time passes. The approval covers `verify.sh` itself, not the files it calls (`make`, `npm test`, `bash scripts/ci.sh`).

Create the script with `/code-guard:setup-verify`. It looks at your build files and proposes a fast lint + test script, and writes it only after you agree.

### Calling the same check from pre-push or CI

The Stop hook runs only `.claude/verify.sh`. To run the same check from somewhere else (a `.githooks/pre-push`, CI), keep `.claude/verify.sh` as a thin entry and put the checks in a script of your project:

```bash
#!/bin/bash
exec "${CLAUDE_PROJECT_DIR:-.}/scripts/verify.sh"
```

`.githooks/pre-push` and CI call `scripts/verify.sh` directly. The approval covers only the content of `.claude/verify.sh`, not the files it calls. After you approve the entry, a change to `scripts/verify.sh` (a `git pull` of someone else's commits, for example) runs without asking again. Use this layout only in a repository whose scripts you trust; in a cloned repository, keep the checks in `.claude/verify.sh` itself.

## Token cost

The plugin is built to stay out of the context window:

- The guards and the hook that marks the start of a turn print nothing when they pass. Only a block or an ask adds a few lines.
- The only text always in the session is the one-line description of the skill `/code-guard:setup-verify`. Its instructions load only when it runs, and it reads build files sparingly.
- A failing `verify.sh` returns at most 80 lines and 6000 bytes. Keep `verify.sh` quiet on success and fast (`--quiet` flags help).

## Settings

Change them in the `/plugin` settings screen. They are read from user and managed settings only; project settings cannot supply them.

| Key | Default | Meaning |
|---|---|---|
| `protected_branches` | `main`, `master` | branches push is blocked for (`*` matches any run of branch-name characters: `release/*`) |
| `confirm_push` | `false` | ask before pushing a work branch |
| `pack_github` / `pack_terraform` / `pack_gcp` / `pack_cloudflare` | `true` | enable the pack |
| `verify_missing_notice` | `true` | tell once per session when files changed and `.claude/verify.sh` is missing |
| `verify_max_retry` | `3` | verify loop retries per turn (1-10) |

Per-project overrides are not supported.

## When a repository switches the plugin off

`enabledPlugins` in a project's `.claude/settings.json` or `.claude/settings.local.json` overrides your settings, and a plugin that is switched off runs no hooks, so code-guard cannot warn about it from the inside. To be told, register `scripts/check-enabled.sh` as a SessionStart hook in your own settings (outside the plugin). It prints a warning only when a project settings file sets a `code-guard@...` entry to `false`, and never blocks.

Copy `scripts/check-enabled.sh` to `~/.claude/hooks/code-guard-check-enabled.sh`, then add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bash \"$HOME/.claude/hooks/code-guard-check-enabled.sh\"" } ] }
    ]
  }
}
```

Claude's own edits to `~/.claude` are stopped, so do this yourself. It needs `jq` and does not see a plugin switched off in a place other than those two project files (managed settings, for example). To make the setting impossible to override, put `enabledPlugins` in managed settings.

## Using it with the sandbox

The sandbox limits writes and network at the OS level; code-guard stops operations by meaning (push to main, `terraform destroy`). They complement each other. Plugins cannot configure the sandbox, so add it to your own settings, for example:

```json
{
  "sandbox": {
    "enabled": true,
    "allowUnsandboxedCommands": false,
    "excludedCommands": ["gh pr *", "gh issue *", "gh api *", "gh run *", "gh auth status"],
    "network": { "allowedDomains": ["github.com"] }
  }
}
```

The guard decides whether a first push to an empty remote is allowed with `git ls-remote`, which makes an outbound request. If the remote's host is not in `allowedDomains`, the request fails and the guard falls back to block. Adjust `excludedCommands` to the `gh` subcommands you use.

`excludedCommands` matches only the start of a command. A compound command such as `cd x && gh pr view` is not excluded and runs inside the sandbox, so run excluded commands on their own.

Checked with Claude Code 2.1.293 and the settings above: both test scripts pass, `git ls-remote` against github.com succeeds, writes outside the project fail with "Operation not permitted", and other hosts get 403.

## Tested versions

Developed against Claude Code 2.1.293. The hooks set `onFailure: "block"`, which Claude Code 2.1.295 and later support. It was checked on 2.1.306 with `tests/manual-check-onfailure.sh`: a PreToolUse hook that exits 1, times out or cannot run stops the tool call, and an exit 1 without the key does not. 2.1.295 to 2.1.305 were not tried. Older versions ignore the key and fall back to the exit-code behaviour.

## Development

```bash
bash tests/test-guard.sh    # guards, packs, settings (checks run in parallel; GUARD_TEST_JOBS sets how many, at most 8)
bash tests/test-verify.sh   # verify loop
bash tests/test-check-deps.sh  # dependency check at session start
bash tests/test-check-enabled.sh  # warning for a project that switches the plugin off
bash tests/test-chain.sh  # command chained to a sandbox-excluded command
bash tests/test-defaults.sh  # plugin.json defaults match the hooks' defaults
bash tests/manual-check-onfailure.sh  # needs a logged-in claude: checks that onFailure "block" stops a tool call (not run by CI)
bash tests/manual-check-multiple.sh  # needs a logged-in claude: shows the shape a multiple option reaches a hook in (not run by CI)
```

When you change a guard decision, add cases to `tests/test-guard.sh` first.

## License

MIT
