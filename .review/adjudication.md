# Adjudication procedure

The canonical procedure for acting on Codex review findings. The `/review`
command and the `pre-pr-review` skill both delegate here so the behaviour is
identical however the review was triggered. Edit this file, not its callers.

## 1 — Run

```
./scripts/review.sh [base-ref | --uncommitted | --spec <path>]
```

(`--spec` reviews a design document instead of code — see the `/review-spec`
command for the mode's adjudication deltas; the rest of this procedure
applies unchanged, except step 4's re-review — spec mode is one pass — and
step 5's file and header.)

Several minutes; lenses run in parallel. If it exits non-zero for a setup reason,
fix that and stop — do not substitute a hand-rolled review.

Then read `.review/findings.json`, and **check `complete` before anything else.**
A lens that died usually contributes an empty findings array, which is
indistinguishable from a lens that ran and found nothing — so a partial run
reads as a clean pass unless you look. If `complete` is false, `lenses_failed`
names the lenses whose areas went unreviewed. A failed lens may still have
contributed findings (partial output salvaged before it died): treat those as
real, but never as evidence its area was covered. Fix the cause and re-run,
or, if you genuinely must proceed, say plainly in the verdict and to the user
which lenses did not finish.
`unreadable_paths` names changed paths the run could not read — a permission
problem, a nested repository, a symlinked directory — so no lens saw them at
all. That is not a partial pass: make the paths readable (or take them out of
the change set) and re-run.
`secrets_scan` is what the gitleaks secret scan found: `clean`; `leaks`, carried
by a critical `gitleaks` finding (the lenses never report it themselves);
`failed`, which makes `complete` false and may still carry a `gitleaks`
finding; or `not_scanned` — gitleaks is not installed, `--no-analyzers`, or
nothing to scan. `not_scanned` leaves `complete` true when the lenses reviewed
the diff, but a secret added and later removed on the branch went unchecked:
say so in the verdict and to the user.
`path_rules` says whether the CodeRabbit config's `path_instructions` reached
the lenses. `applied`, `no_match`, `no_rules` and `no_config` need nothing.
Any other status carries a `warning`: the lenses graded without some or all of
the path rules the gate grades against. It leaves `complete` true, but copy
the warning into the verdict and tell the user.
When `changed_files` is 0, nothing was reviewed — usually a wrong base ref, or
fixes not yet committed. **Do not write `.review/verdict.md` from that run**:
a verdict names HEAD, and the pre-push hook would accept it for code no lens
saw. Find the right base and re-run, or tell the user the change set is empty;
a `gitleaks` finding in it still needs acting on.
Never report a run with `complete: false` as a clean review.

## 2 — Verify before you trust

**Codex hallucinates line numbers and occasionally invents behaviour.** For every
finding, before deciding anything:

- Open the cited file and read the cited region yourself.
- Confirm the construct in `evidence` actually exists there.
- Confirm the failure in `why_it_matters` is reachable — trace callers if the
  finding depends on how the code is called.

Evidence that does not survive this is `REJECT (unverifiable)` regardless of the
confidence Codex claimed.

Findings carry an `agreement` count — how many independent lenses reported the
same defect. Agreement above 1 is the strongest signal in the report; verify those
first. It is not a substitute for verifying.

The merge collapses duplicates only when titles match, so lenses often report
one defect under several wordings — especially in spec mode. Before verifying,
group findings that cite the same or adjacent lines, check whether they are one
issue, and dispose of the group together; treat the group's size as its real
agreement count. (Same-line findings are not automatically one issue — read
them.)

## 3 — Classify

Exactly one disposition per finding:

- **FIX** — verified, worth changing now.
- **LOG** — verified real, but pre-existing or unrelated to this change. File
  it in the repo's tracker (`gh issue create`, quoting the finding and
  location) and record the issue link in the verdict. **Do not fix it here**
  — an unrelated fix inside this diff is unreviewable scope creep; the issue
  link is the responsible disposition, not an ignored finding.
- **REJECT** — verified wrong, out of scope per `.review/rubric.md`, or a
  deliberate choice. **A one-line reason is mandatory.** "Not an issue" is not a
  reason; "callers already hold the lock, see `pool.rs:88`" is. A design
  document that accepts a risk, or behaviour that is documented, tested or
  deliberate, is no reason to REJECT a verified finding, or to fix only part of
  it, when a cheap guard closes the rest (a conditional write, compare-and-swap,
  If-Match, an allowlist): ESCALATE any half you keep, naming the guard.
- **ESCALATE** — real, but the fix is a judgement call, a scope increase, or
  touches something you should not decide alone. Leave the code untouched.

`critical` and `high` are FIX or ESCALATE — never REJECT without an explicit
verified reason, and LOG only if the defect genuinely predates this change (a
critical the diff made newly reachable is this PR's problem). `medium` is FIX
unless there is a reason. `low` is judgement.

## 4 — Apply

Before the first fix, run `git rev-parse HEAD` and note the SHA it prints —
call it PRE_FIX. Note the literal value: a shell variable does not survive to
the re-review, and an empty base silently widens it to the whole branch. Apply
all FIXes with the minimal change that removes the defect; do not
opportunistically refactor. Group related fixes into coherent commits.

Run the project's tests and type checker, plus the lint/analyzer gate wired in
`.review/analyzers.local.sh` — that pass ran before the lenses, so nothing has
ever linted the code you just wrote. If a fix breaks a test, decide whether the
test encoded the bug — and say which, explicitly.

If the fixes amount to substantial new code — new logic or a changed
transaction, authz, or rollout boundary, not mechanical corrections — commit
them, then run ONE scoped re-review over the fix commits before writing the
verdict: `./scripts/review.sh <PRE_FIX> --lenses <relevant lenses>`. Not
`--uncommitted`: once the fixes are committed it reviews nothing
(`changed_files: 0`). Check the range too: "no changes to review" means
the fixes are not committed yet, and a failing
`git merge-base --is-ancestor <PRE_FIX> HEAD` means an amend or rebase
rewrote PRE_FIX, so the review covers the wrong range. Keep fixes in their
own commits on top of PRE_FIX. Fixes applied during
adjudication are otherwise the only unreviewed code in the change, and it is
exactly where downstream reviews land their hits. Adjudicate that re-review's
findings without a further re-pass — one bounded loop, not a cycle.

## 5 — Write the verdict

Write `.review/verdict.md`. Include the HEAD short SHA — after the fix
commits — in the header so the pre-push hook can tell whether the verdict is
current. In `--spec` mode, write `.review/spec-verdict.md` instead, with the
header `# Spec verdict — <branch> — <short-sha> — <date>`: a spec review is not
a code review, and the hook must not read it as one. In `--uncommitted` mode
(`mode` is `uncommitted` in `findings.json`), the third field is
`<head>+uncommitted`, with `<head>` copied from `findings.json`: the run
reviewed changes on top of that commit, not the commit. The pre-push hook does
not accept it for any push, and `/review-postmortem` never scores it as a
pre-PR catch.

```markdown
# Review verdict — <branch> — <short-sha> — <date>

<n> findings · <f> fixed · <l> logged · <r> rejected · <e> escalated
Lenses: <list> · Effort: <effort> · Secrets: <secrets_scan> · Path rules: <path_rules.status>
<path_rules.warning, when there is one>

| ID | Sev | Agree | File:line | Finding | Disposition | Reason |
|----|-----|-------|-----------|---------|-------------|--------|

## Escalated — needs a human decision
<one short paragraph each, trade-off stated>

## Rejected
<ID — reason, one line each>

## Verification
<test / typecheck / lint + analyzer results after fixes>
```

## 6 — Report back

In chat: the counts, every ESCALATE in full, and any REJECT you are less than
certain about. Do not re-narrate the fixes — the verdict file has them.

CodeRabbit still runs as the final gate on the PR. The goal is for it to find
nothing, not to substitute for it.

## Replay mode

`scripts/review-replay.sh` replays today's kit on an old PR and adjudicates
the run headlessly. It produces the verdict `/review` would have written on
the commit CodeRabbit first reviewed. The procedure is the same, minus
everything that changes something:

- **Step 1** has run. The run is complete, and you do not run it again.
- **Steps 2 and 3** are unchanged. Judge the code at the replayed commit. Do
  not read later history, such as other branches, `git log --all` or the PR on
  GitHub: the replay measures what this review would have found then. Record
  a LOG as `LOG (not filed: replay)`, and file nothing.
- **Step 4** is skipped. Apply no fix, commit nothing, and run no re-review. A
  finding you would fix stays FIX.
- **Step 5:** the header names the replayed commit. Print the verdict as your
  final message instead of writing the file. Its Verification section says
  `replay: no fixes applied, tests not run`.
- **Step 6** is skipped.
