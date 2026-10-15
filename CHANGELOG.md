# Changelog

## 0.1.0 (unreleased)

- First version: Bash / file-tool / MCP guards, the github / terraform / gcp / cloudflare packs, the verify loop, and `/code-guard:setup-verify`.

### Known limits

- The guards do not parse the shell. Ambiguous shapes (quoted or split command names and subcommands, `git push` arguments built from quotes or expansions, line continuations in a command with a guarded command word, odd heredoc markers or terminators, a failing check) ask instead of being judged. The same operation through python and similar interpreters is not stopped.
- Heredoc bodies are treated as data unless the command contains a known interpreter (`bash`, `sh`, `eval`, `python` and similar). A body run by another program (`ssh host <<EOF`, `ksh`, `./x.sh` after writing it) is not asked.
- Brace expansion and `$@` in a `git push` argument (`ma{in,}`, `{main,x}`) are not read: a push to a protected branch written that way is asked, not blocked.
- A command longer than 100000 characters is asked without being read.
- When a grep or rg is in the command, quoted strings without a slash are not inspected for `*.pem` / `*.key` (`grep -rn foo . ; cat "server.key"` passes).
- `cat -- -m "<file>"`: a value after `--` that follows a message flag is treated as message text.
- `gh api -X Delete` written in mixed case is not recognized as a mutating method.
- A repository can switch the plugin off through `enabledPlugins` in its own settings.
- Per-project configuration, a protected-branch glob (`release/*`), and the confirmation-free run of a cloned repository's `.claude/verify.sh` are not handled.
