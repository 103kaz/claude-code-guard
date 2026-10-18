# code-guard

[日本語](README.ja.md)

A Claude Code plugin that stops dangerous operations with hooks, and runs your project's own checks before Claude finishes a turn.

## What it does not guarantee

- The guards read command strings and file paths. They are not a sandbox. The same operation routed through python or another interpreter is not stopped.
- The guards do not parse the shell. Shapes they cannot read (a quoted or split command name or subcommand, a `git push` argument built from quotes or expansions, a line continuation inside a guarded command, an odd heredoc marker) are sent to a confirmation (ask) instead of being judged. See [Known limits](CHANGELOG.md#known-limits).
- Grep is stopped only when its `path` is a secret file. A directory search whose results include secret files cannot be stopped.
- The verify loop makes Claude fix failures. It is not enforcement: a turn can still end without running `verify.sh`.
- The hook input format and the plugin mechanism can change between Claude Code versions. See [Tested versions](#tested-versions).
- A repository can switch the plugin off: `enabledPlugins` in the project's `.claude/settings.json` overrides the user's settings. Claude's own edits to those files are stopped (asked or blocked), but a setting that arrived with a cloned repository is not.

## Install

```bash
/plugin marketplace add 103kaz/claude-code-guard
/plugin install code-guard@claude-code-guard
```

Requires bash 3.2+, `jq` and `perl`, on macOS or Linux. Windows is not supported. If `jq` or `perl` is missing, the guards block everything they cover and say how to install the tool.

## What is guarded

Each decision is one of: **block** (exit 2, cannot be approved), **ask** (a confirmation to the user), or pass.

### Core rules (cannot be turned off)

| Area | Block | Ask |
|---|---|---|
| Protected branches | push to a protected branch (a bare `git push` on one, `heads/main`, and a repository reached through `cd` or `GIT_DIR=` included), a lone `:` or a wildcard refspec | first push to an empty remote |
| Push shape | `--no-verify`, `--mirror`, `--delete` / `-d` / `:ref`, `--prune`, `--all` | force push (`+ref` included), every work-branch push when `confirm_push` is on |
| Hook bypass | `core.hooksPath`, `git -c`, `--config-env`, `GIT_CONFIG_*`, alias / include settings, removing the core / alias / include section, git with `HOME=` / `XDG_CONFIG_HOME=`, writes to `~/.gitconfig` / `~/.config/git/config`, `--no-verify` on commit / merge (`commit -n`) | |
| Secrets | `.env` / `.env.*` (samples excluded), `*.tfvars`, `*.tfstate`, `*token*.txt`, `*.pem`, `*.key`, `~/.ssh`, signing assets, service account keys, CLI credentials, git credentials (`~/.git-credentials`, `git credential fill`), keychain values. Names after `<`, `rev:` and `--opt=` (except terraform's `-var-file=`), and globs or braces that expand to one (`.en?`, `.e{n,x}v`) are included | |
| Harness | Bash writes to `~/.claude` settings / hooks / plugins, `.claude/settings*`, `.githooks`, `.git/config`, `.git/hooks` (submodules under `.git/modules/` included). Writes are redirects, `sed` / `perl` / `ruby -i`, `awk -i inplace`, file commands, `dd`, `rsync`, `curl -o`, `wget -O`, and `git checkout` / `restore` / `apply` / `am`; relative paths after `cd` count | Bash writes to `.claude/hooks`, `.claude/verify.sh`, `.github/workflows` |
| Fetched code | `curl` / `wget` piped to a shell (`/bin/sh`, `env bash` ..., at any later stage) or an interpreter (`python3`, `perl`, `node` ...; right after `curl`, or later when it reads its program from stdin) | process substitution, `bash -c "$(curl ...)"`, `eval` |
| Deleting | `rm -r` on `/` or `~` (after `--` and long options too) | `rm -r` outside build directories, `git clean`, `reset --hard`, `restore`, `checkout [<rev>] --`, `stash drop`, `branch -D`, `xargs rm`, `find -delete` / `-exec rm` |
| Machine settings | | `sudo`, `launchctl` registration, `crontab`, `defaults write` |

Text that only appears in a commit message or PR body (`-m`, `--body`, heredoc) is not judged, unless the command also contains `bash -c`, `eval`, python and similar. A `$(...)` or backtick inside a double-quoted value or an unquoted heredoc runs, so it is judged.

### File tools (`guard-file.sh`)

Plugins cannot ship permission rules, so these live in a hook.

| Tool | Block | Ask |
|---|---|---|
| Read, Grep | secret files (same patterns as the core secret rules) | |
| Edit, Write, MultiEdit, NotebookEdit | `*.tfvars`, `.git/config`, `.git/hooks`, `~/.gitconfig`, `~/.config/git/config` | `~/.claude`, `.claude/settings*`, `.claude/hooks`, `.claude/verify.sh`, `.githooks`, `.github/workflows` |

### MCP tools (`guard-mcp.sh`)

A tool whose name contains `delete`, `destroy`, `drop`, `purge`, `remove`, `truncate`, `wipe`, `erase`, `deploy`, `publish`, `unpublish`, `rollback` or `secret` asks, and so do `merge_pull_request`, `merge_branch`, `push_files`, `push_branch`, `force_push`, `create_or_update_file`, `update_file`, `create_commit` and `update_ref`. Tools named `query`, `sql`, `execute` or `exec` ask when the input is a data-changing statement (`DROP`, `DELETE`, `UPDATE`, `INSERT`, `MERGE`, `GRANT`, `REVOKE`, `COPY` and similar; comments are removed first). Without `jq` or `perl` the MCP guard blocks every MCP call.

### Packs

On by default. Turn one off when its policy does not fit how you work. Secret reads stay in the core even when a pack is off.

| Pack | Decisions |
|---|---|
| `github` | block: `gh secret set/delete`, `gh variable delete`, `gh repo delete`, `gh release delete`, `gh pr merge --admin/--auto`, `gh repo edit --visibility`, mutating `gh api` (a lone call to a repository-settings path asks). ask: `gh pr merge`, `gh workflow run`, `gh release create`, `gh gist create` |
| `terraform` | block: `destroy`, `import`, `taint`, `untaint`, `force-unlock`, state changes, plan + apply in one command, `-auto-approve` and similar. ask: `apply` of a saved plan file. `terraform fmt` runs after Edit / Write of `.tf` files |
| `gcp` | block: deleting disks, instances, projects, storage, SQL instances, `gsutil rm/rb`, Secret Manager values and access tokens |
| `cloudflare` | block: `wrangler` deploy / delete / rollback / secret changes |

## Verify loop

When files changed during a turn and the project has `.claude/verify.sh`, the Stop hook runs it. On failure the last 80 lines of output go back to Claude (exit 2). After `verify_max_retry` failures in one turn (default 3) the user is told and the stop passes. With no `.claude/verify.sh` nothing happens.

"Changed" compares a fingerprint of HEAD, the tracked diff and the untracked files against the one taken when the prompt was submitted, so changes that were already there do not trigger it. Outside git, a file modified, renamed or deleted after the prompt was submitted counts.

Create the script with `/code-guard:setup-verify`. It looks at your build files and proposes a fast lint + test script, and writes it only after you agree.

## Docs check

`/code-guard:doc-code-consistency` checks that the documentation (README, `docs/`, `CLAUDE.md`, `CHANGELOG`, comments) matches the code, and reports contradictions, stale text and missing items with file:line evidence. It only reads, and changes files only when you ask it to fix a finding. Run it before a pull request on the branch diff, or name a document or feature to check.

With `doc_check_before_pr` on, the plugin records the commit when the skill starts (only this bundled skill counts, not a personal skill of the same name) and blocks creating a pull request whose head is not that commit (no check yet, or commits added after it). The record is written when the check starts, whatever it finds, so it reminds rather than enforces.

## Token cost

The plugin is built to stay out of the context window:

- The guards and the hook that marks the start of a turn print nothing when they pass. Only a block or an ask adds a few lines.
- The only text always in the session is the one-line descriptions of the two skills, `/code-guard:setup-verify` and `/code-guard:doc-code-consistency`. Their instructions load only when they run. setup-verify tells Claude to read build files sparingly; doc-code-consistency reads as much as the scope you give it, so name a branch diff or a document rather than the whole repository.
- A failing `verify.sh` returns at most 80 lines and 6000 bytes. Keep `verify.sh` quiet on success and fast (`--quiet` flags help).

## Settings

Change them in the `/plugin` settings screen. They are read from user and managed settings only; project settings cannot supply them.

| Key | Default | Meaning |
|---|---|---|
| `protected_branches` | `main`, `master` | branches push is blocked for |
| `confirm_push` | `true` | ask before pushing a work branch |
| `pack_github` / `pack_terraform` / `pack_gcp` / `pack_cloudflare` | `true` | enable the pack |
| `doc_check_before_pr` | `false` | block `gh pr create` (and an MCP `create_pull_request`) until `/code-guard:doc-code-consistency` has checked the branch head |
| `verify_max_retry` | `3` | verify loop retries per turn (1-10) |

Per-project overrides are not supported.

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

Checked with Claude Code 2.1.293 and the settings above: both test scripts pass, `git ls-remote` against github.com succeeds, writes outside the project fail with "Operation not permitted", and other hosts get 403.

## Tested versions

Developed against Claude Code 2.1.293. The hooks set `onFailure: "block"`, which Claude Code 2.1.295 and later support; it has not been verified on a real session yet. Older versions ignore the key and fall back to the exit-code behaviour.

## Development

```bash
bash tests/test-guard.sh    # guards, packs, settings (about a minute)
bash tests/test-verify.sh   # verify loop
bash tests/test-doc-check.sh  # docs check before a PR
```

When you change a guard decision, add cases to `tests/test-guard.sh` first.

## License

MIT
