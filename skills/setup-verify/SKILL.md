---
name: setup-verify
description: Create a project's .claude/verify.sh, the script that code-guard's verify loop runs before Claude finishes a turn. Use when the user asks to set up, add, or fix the verify loop, or when .claude/verify.sh is missing and they want automatic lint/test checks.
---

# setup-verify

Propose a `.claude/verify.sh` that fits this project, show it to the user, and write it only after they agree.

## What verify.sh is for

code-guard's Stop hook runs `.claude/verify.sh` when the working tree changed during the turn. A non-zero exit sends the output back to Claude to fix (up to the configured retry count, 3 by default). The script must therefore be **fast** (seconds to a minute; the hook is cut off after 600 seconds) and **deterministic**. Heavy suites (full end-to-end, device tests) do not belong here.

## Steps

1. Look at the project root for build and tooling files: `package.json` (and its `scripts`), `pyproject.toml`, `setup.cfg`, `go.mod`, `Cargo.toml`, `Gemfile`, `Package.swift` / `*.xcodeproj` / `project.yml`, `Makefile`, `composer.json`, `pom.xml` / `build.gradle*`, shell scripts, and existing CI config (`.github/workflows`) for the commands the team already trusts.
2. If `.claude/verify.sh` already exists, read it and propose changes instead of overwriting.
3. Pick the checks that finish quickly: linters, type checks, unit tests. Prefer commands the project already defines (`npm run lint`, `make test`, `ruff check`, `go vet ./...`, `cargo check`, `shellcheck`). If a test command is slow, use its fast subset or leave it out and say so.
4. Draft the script:

   ```bash
   #!/bin/bash
   # Verify loop: run by code-guard's Stop hook when files changed during the turn.
   # Keep it fast. A non-zero exit sends the output back to Claude.
   set -euo pipefail
   cd "$(dirname "$0")/.."

   # <the project's checks here>
   ```

   Use `set -euo pipefail` so the first failing check stops the script, and run from the project root.
5. Show the user the full script, say which checks it runs and which you left out and why, and ask for confirmation. Do not write the file before they agree.
6. After writing, run it once (`bash .claude/verify.sh`) and report the result and the time it took. If it fails for a reason unrelated to the user's change, tell them instead of weakening the check.

## Notes

- Editing `.claude/verify.sh` asks for confirmation through code-guard's file guard; that is expected.
- Do not add checks that need secrets, network access to production, or a running device.
- If nothing sensible can be verified quickly, say so and do not create an empty script that always passes.
