# Security policy

## Reporting a vulnerability

Report vulnerabilities through GitHub's private reporting, not a public issue: open the Security tab of this repository and choose "Report a vulnerability".

Useful details: the command or tool input, the settings in use, what happened, and what should have happened.

## Scope

- A guard in `scripts/guard-*.sh` lets an operation through that it is documented to stop
- A secret file that the file-tool guard is documented to protect can still be read through the Read or Grep tool
- `scripts/verify-loop.sh` runs something other than the project's `.claude/verify.sh`

The guards inspect command strings and file paths. They are not a sandbox, and operations routed through another interpreter (python and similar) are known not to be stopped. Reports about that limit are not vulnerabilities.

## Supported versions

The latest release on `main`.
