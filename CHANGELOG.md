# Changelog

## 0.1.0 (unreleased)

- First version: Bash / file-tool / MCP guards, the github / terraform / gcp / cloudflare packs, the verify loop, and `/code-guard:setup-verify`.

### Known limits

- The guards do not parse the shell. Ambiguous shapes (split command words, line continuations inside command words, odd heredoc markers) ask instead of being judged. The same operation through python and similar interpreters is not stopped.
- When a grep or rg is in the command, quoted strings without a slash are not inspected for `*.pem` / `*.key` (`grep -rn foo . ; cat "server.key"` passes).
- `cat -- -m "<file>"`: a value after `--` that follows a message flag is treated as message text.
- `gh api -X Delete` written in mixed case is not recognized as a mutating method.
- A repository can switch the plugin off through `enabledPlugins` in its own settings.
- Per-project configuration, a protected-branch glob (`release/*`), and the confirmation-free run of a cloned repository's `.claude/verify.sh` are not handled.
