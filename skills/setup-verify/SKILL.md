---
name: setup-verify
description: Create .claude/verify.sh for code-guard's verify loop. Use when asked to set up or fix the verify loop.
---

# setup-verify

Propose a fast `.claude/verify.sh`, show it, and write it only after the user agrees. Keep reads small: this skill should cost few tokens.

## Steps

1. List the project root once (names only). Read at most the build files that exist: `package.json` (the `scripts` block only), `pyproject.toml`, `go.mod`, `Cargo.toml`, `Makefile`. Do not read source files or CI logs.
2. If `.claude/verify.sh` exists, read it and propose a diff instead of a rewrite.
3. Pick only checks that finish in seconds: lint, type check, unit tests, using commands the project already defines. Leave slow suites out and say so.
4. Draft the script (`set -euo pipefail`, `cd "$(dirname "$0")/.."`, one line per check, no echo noise: a failure's output goes back to Claude, so quiet commands are cheaper).
5. Show the script and which checks were left out, then ask. Write it only after a yes.
6. Run it once and report the result and the time. If nothing can be verified quickly, say so; do not write a script that always passes.

7. Tell the user that the verify loop skips a `verify.sh` until they approve it, and give the command to run themselves in a terminal: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/trust-verify.sh"` (it shows the script and asks for `yes`). Do not run it yourself, and do not answer its prompt for the user.

Editing `.claude/verify.sh` asks for confirmation through code-guard; that is expected. Any change to the script takes its approval away, so the user approves again after each edit.
