---
name: review-loop
description: Review and fix the current branch's diff before a push or pull request - verify, review, fix, repeat until a lap finds nothing. Use when asked to review-loop, or before opening a pull request.
---

# review-loop

Run the develop loop over the current branch: verify, review the diff, fix, and repeat until a lap finds nothing. The scope is the diff only, not the whole codebase. This skill does not push or open a pull request; those stay with the user and go through code-guard's confirmations.

## Steps

1. Run `.claude/verify.sh`. If it fails, fix that first. If the file does not exist, tell the user and point to `/code-guard:setup-verify`, then go on without verification and say so in the report.
2. Decide the diff: the branch against its base (`git diff origin/HEAD...HEAD`, plus `git diff HEAD` for uncommitted changes). If `origin/HEAD` is not set, try `origin/main` or `origin/master`; if neither exists, ask the user for the base. If an earlier lap in this conversation already reviewed up to some commit, look only at what came after it.
3. Review the diff.
   - If it changes code, use the `code-review` skill at medium effort. If that skill is not available, read the diff yourself for bugs: wrong results, missing error paths, and callers the change breaks.
   - If it changes only documentation (`.md` and similar), use `/code-guard:doc-code-consistency` on the diff instead.
4. Fix the findings. After each fix, go back to step 1. Repeat until a lap finds nothing. A finding you decide not to fix gets a one-line reason. If three laps in a row still turn up findings (a `verify.sh` failure counts), stop and report what remains instead of going on.
5. If the diff changed code that the documentation describes, run `/code-guard:doc-code-consistency` on the diff once at the end and fix what it finds. With `doc_check_before_pr` on, the plugin wants the check to be on the branch head, so if fixing commits anything, run the check again before opening the pull request.
6. Report in a few lines: "Result: no findings", or "Result: findings kept" with each finding and its reason. Add whether `verify.sh` passed and how many laps it took.

Keep each lap quiet: read the diff, not the repository, and do not repeat the findings of an earlier lap.
