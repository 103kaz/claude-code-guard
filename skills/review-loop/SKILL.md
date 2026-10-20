---
name: review-loop
description: Run one lap of review and fix on the current branch's diff before a push or pull request - verify, review, fix, repeat until clean. Use when asked to review-loop, or before opening a pull request.
---

# review-loop

Run the develop loop once over the current branch: verify, review the diff, fix, and repeat until nothing is left. The scope is the diff only, not the whole codebase. This skill does not push or open a pull request; those stay with the user and go through code-guard's confirmations.

## Steps

1. Run `.claude/verify.sh`. If it fails, fix that first. If the file does not exist, tell the user and point to `/code-guard:setup-verify`, then go on.
2. Decide the diff: the branch against its base (`git diff origin/HEAD...HEAD`, plus uncommitted changes). If an earlier lap in this conversation already reviewed up to some commit, look only at what came after it.
3. Review the diff.
   - If it changes code, use the `code-review` skill at medium effort. If that skill is not available, read the diff yourself for bugs: wrong results, missing error paths, and callers the change breaks.
   - If it changes only documentation (`.md` and similar), use `/code-guard:doc-code-consistency` on the diff instead.
4. Fix the findings. After each fix, go back to step 1. Repeat until a lap finds nothing. A finding you decide not to fix gets a one-line reason. If three laps in a row still turn up findings, stop and report what remains instead of going on.
5. If the diff changed code that the documentation describes, run `/code-guard:doc-code-consistency` on the diff once at the end and fix what it finds. With `doc_check_before_pr` on, this is also the check the plugin asks for before a pull request.
6. Report in a few lines: "Result: no findings", or "Result: findings kept" with each finding and its reason. Add whether `verify.sh` passed and how many laps it took.

Keep each lap quiet: read the diff, not the repository, and do not repeat the findings of an earlier lap.
