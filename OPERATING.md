# Operating the review kit: proving it, and what to watch

REVIEW.md explains what the pipeline is. This file is the operator's guide:
how to know it is actually working, and the failure modes that experience has
already demonstrated. Synced into every spoke alongside REVIEW.md.

## Proving it as you go

Two mechanisms, one you already own and one you run deliberately.

### The postmortem scorecard (the designed proof)

After CodeRabbit reviews each PR, run `/review-postmortem <PR>`. It yields
`caught N / missed M / rejected-wrongly R / noise X / unscored U`, with
`missed` split by cause. That is the metric:

- **`missed` trending toward zero** over a run of PRs → the local pass is
  doing CodeRabbit's job and CodeRabbit is insurance.
- **`missed` plateauing** → a hypothesis, not a finding, until the
  postmortem has classified the misses by cause. Wrong lens, insufficient
  tracing and threshold misses are fixable here, so a plateau of those means
  the fixes are not landing. Only structural misses point at value this
  pipeline cannot reproduce. Candidates are repo-wide indexing, cross-PR
  memory and CodeRabbit's analyzer fleet. Knowing precisely what you're paying
  for is the point.

The score is only as good as the comparison. The postmortem scores against
the local verdict whose header names the first commit CodeRabbit reviewed, or
an ancestor of it on the PR's branch. `.review/verdict.md` counts only when
its header names that commit. A `<sha>+uncommitted` verdict, from
`/review --uncommitted`, is skipped and named in the record: it may hold fixes
written after reading CodeRabbit. A finding on code a later commit brought
in is `unscored`; code that was there at the local review is scored, even in
a file changed since. A compare that failed or was denied is counted apart,
as `compare_failed`. With no matching verdict the PR is `no-local-verdict`: recorded, with `null` counts,
and never read as `missed 0`.

Each run leaves a record: a PR comment marked `<!-- review-postmortem:v1 -->`,
updated in place on a re-run, and a copy in
`$(git rev-parse --git-common-dir)/review-history/postmortem-pr<n>.md`. The
chat output alone is not a record. If the comment or the copy could not be
written, the run says so.

Run the postmortem on **every** PR at first, including clean ones — "nothing
missed" is a data point, and skipping it silently stops the learning loop.

### Replays: today's kit on PRs already merged

`scripts/review-replay.sh <spoke> <PR>…` (or `--recent N`, with `--limit`
to bound the spend) runs from the hub. It scores PRs that never had a local
verdict, so the scorecard does not have to wait for new PRs. Each PR is
replayed on the commit CodeRabbit first reviewed: today's kit (`--kit-ref`,
default the hub's `main`) over that commit's repo-owned files. A `--kit-ref`
branch behind its remote is refused, so a stale hub clone cannot replay an
old kit as today's. Missing files come from the spoke's default branch. The
record names the source of each.

Read a replay differently from a live postmortem:

- **It measures the current kit, not the past.** A miss means today's lenses
  and learnings would still miss it. A catch says nothing about what the
  review that ran then found.
- **The adjudication applies nothing.** No fixes and no re-review: the
  verdict is what `/review` would have decided before its step 4.
- **The lenses cannot see later history.** The lenses and the adjudicator
  run in a temporary clone, outside the spoke, that holds the reviewed
  commit's history and nothing else: no ref but its detached `HEAD`, no
  remote, and no object of a later head or of the default branch, so
  `git log --all` or `git diff HEAD origin/main` finds no fix commit. Only
  then is the postmortem given the spoke's objects (as git alternates), so
  it can compare later heads by SHA. It still sees none of the spoke's refs.
  This isolates git history, not the filesystem: an agent that names a path
  outside the clone, such as the spoke itself, can still read it. The
  transcripts show whether one did.
- **It runs the PR commit's own code,** as `/review` would on that branch:
  its `.review/config.sh` and `analyzers.local.sh`. So it replays merged PRs
  only, and skips one whose reviewed commit has a version of either file that
  never merged. The headless `claude` loads no settings file, because a
  user's allow rules would let it write to the spoke.
- **It skips what it cannot replay faithfully,** with a stated reason: a
  pre-hub kit, a PR CodeRabbit never reviewed, an unmerged PR, a symlink in
  the kit's paths, and `--limit` reached. A failed step reads
  `failed — <step>: <error>`, never a skip or `missed 0`. A commit
  CodeRabbit commented on that cannot be fetched fails the PR, rather than
  leaving its findings unscored. A re-run that fails keeps the scored record
  and writes its logs to `<record>.last-unscored`.
- **A finding the postmortem could not compare makes the PR `incomplete`**,
  not `replayed`: its line reads
  `incomplete — … · <k> finding(s) unscored because a compare failed (<reason>)`.
  It is one whose `unscored_reason` starts with `compare_failed`. The record
  is kept, its counts go into the scorecard, and the run exits 1.
- **Denied commands are shown, never dropped.** The headless `claude` may
  run only single read-only commands, so a compound one (`cd … && …`) is
  denied. A PR's line ends with `commands denied: <call> <n>` for each call
  that had one, and with `<call> unknown` for a call that gave no list.
  `denials —` totals them for the run. A denial alone does not fail the PR:
  read what was denied in the record before trusting a classification.
- **Each PR keeps its record** in `review-replay/pr<n>-<kit>/`:
  `postmortem.md` and its `record.json`, `outcome.txt` (the PR's line),
  `verdict.md`, `findings.json` and `findings.md`, `review.log`, each lens's
  `raw/out-<lens>.json` and `raw/log-<lens>.txt`, and the GitHub data in
  `github/`. Both `claude` calls keep their whole stream, every tool call and
  its result, as `transcript-adjudicate.jsonl` and
  `transcript-postmortem.jsonl`, and their result as `adjudicate.json` and
  `postmortem.json`. `record.json` copies each call's `permission_denials`
  into `replay.permission_denials`, with `null` for a call that gave no list.
  A call whose transcript has no result fails the PR.
- **Each run keeps its own record** in `review-replay/runs/<time>-<kit>/`.
  `summary.txt` opens with the kit and how its freshness was checked, then
  holds each PR's line, any note such as a short `--recent` scan, and the
  scorecard. `aggregate.json` (`review-replay-run/v2`) holds the same
  scorecard with each PR's record: replayed, incomplete, skipped and failed
  PRs, the findings left unscored by a failed compare, the cost and the
  denied commands. A run that stopped early says so in `summary.txt` and has
  no `aggregate.json`.
- **Runs sum across spokes** with
  `scripts/review-replay-sum.sh <run dir>…` (`--json` for the combined
  JSON). It prints the same scorecard over all of them, each lesson named by
  `owner/repo#PR`. It refuses, rather than sums, a run with no
  `aggregate.json`, one an older replay wrote, the same run twice, a PR
  scored in two runs, and runs of different kits.

Each PR costs one full `review.sh` run (six Codex lenses at the configured
effort) plus two headless `claude -p` calls, capped by `--claude-budget`.
On an 11-file PR at `high` effort, the first replay took 6 minutes, about
840k Codex tokens and $1.10 of Claude. The per-PR line and the closing
`cost` line print both totals. A count the replay cannot read prints as
unknown, never as 0.

### Fire drills (the stronger, faster proof)

Don't wait for real bugs — plant them. On a scratch branch, commit a
deliberate violation of one of your repo's house rules and run
`./scripts/review.sh` against it. Choose violations that are invisible to
lint and tests, i.e. exactly what the rubric exists for. If a lens misses a
planted violation of a rule written in its own prompt overlay, you've found a
prompt problem for the cost of one throwaway branch.

This is mutation testing for the review system itself. Do two or three drills
per repo when you first wire it up, and again after any significant prompt or
model change.

### Plumbing spot-checks

For the first few runs, look under the hood:

- `.review/raw/log-<lens>.txt` — did all lenses actually produce output?
- `.review/raw/analyzers.txt` — does it contain real sections for your stack?
- `.review/raw/prompt-<lens>.md` — is your `prompts.local/` overlay and both
  learnings files present in the assembled prompt?
- `@coderabbitai configuration` on the first PR — is the `.coderabbit.yaml`
  you committed the config that actually graded the diff?

## What to be aware of

### This system fails quiet, not loud

The record so far, all found before the first paid review ran:

- The stock `_files_matching` helper never matched a multi-extension pattern
  (`case` treats an expanded `|` literally), so every per-language analyzer
  stanza was silently dead. The runs "succeeded" with an empty report.
- eslint 9 removed the `--format unix` flag the kit passed; with stderr
  discarded, lint "ran" and reported nothing.
- Codex 0.149 removed `--ask-for-approval`; every lens would have failed
  with a usage error, each one non-fatally.
- An edit to `tests/review-test.sh` deleted two test functions but left their
  names in the runner list. Bash printed `command not found`, returned 127, and
  recorded nothing — so the suite reported "all tests passed" with 17
  assertions missing, and CI agreed. The runner now fails on a listed test it
  cannot find.

The pattern: broken looks identical to clean. Treat an empty findings list on
a substantial diff as suspicious, not reassuring, and check the raw logs. A
single lens dying is a warning line, not an abort.

### The gate may not be running the config you committed

`.coderabbit.yaml` is one of eight configuration sources CodeRabbit resolves,
and it resolves exactly one of them — they do not merge. Two consequences
before you trust the gate:

- A repo file **replaces** the org's central config and UI settings instead of
  adding to them, and any key it omits falls back to the schema default rather
  than the org's value. The seeded template sets `inheritance: true` to opt
  into merging; drop that line and the repo quietly stops honouring org policy.
- One invalid key makes CodeRabbit discard the **entire file** and review with
  defaults — taking the rubric pointer down with it. That is reported at the
  top of its PR summary, but nested keys are not schema-validated: a
  nonexistent tool under `reviews.tools`, or a misspelt key under
  `auto_review`, validates clean and does nothing.

`@coderabbitai configuration` on any PR prints the fully-resolved config and
names which source won each value. It is the only way to confirm the file you
committed is the one grading your diff.

One default deserves its own mention: `auto_pause_after_reviewed_commits` is 5,
so automatic review pauses after five reviewed commits on a branch. Review →
fix → push reaches that routinely, and a paused gate is indistinguishable from
a clean one — the same trap as reading a green status check instead of the
verdict. The template sets it to 0.

### Adjudication bias

Claude Code verifying findings about code Claude Code just wrote leans toward
REJECT. The mandatory written rejection reason helps; the scorecard's
`rejected-wrongly` column exists to catch it. For the first weeks, read a
sample of rejections yourself.

### Never apply an unverified finding

Codex hallucinates line numbers and occasionally invents behaviour. The
adjudication step — open the cited file, confirm the evidence — is the whole
point of the design. Findings applied unverified are worse than no review.

### Suppression discipline

- `/review-tune` requires the same rejection **twice** before suppressing —
  one occurrence is a one-off.
- Never suppress a class that ever produced a genuine FIX.
- Keep `learnings.md` under ~60 lines; past that it dilutes every prompt.
- Watch the "LOG, but pulled into scope" pattern: occasionally a logged
  pre-existing bug genuinely blocks the change and must ride along — but it
  needs the user's explicit sign-off and a written reason, or log-don't-fix
  quietly becomes fix-everything-here.

### Hub/spoke discipline

- **Repo-owned, in full — this list is the short one, so learn it instead:**
  `.review/rubric.md`, `.review/learnings.md`, `.review/config.sh`,
  `.review/analyzers.local.sh`, `.review/prompts.local/`, and the CodeRabbit
  config at the repo root (`.coderabbit.yaml`), plus
  `.github/workflows/review-kit-sync.yml` unless `.review/config.sh` sets
  `KIT_SYNC_ACTION=0`. These seven are seeded once on `--init` and never
  touched again — and the gate config is not seeded at all when the repo
  already has one, so hub improvements to it never arrive automatically. The
  same holds for the workflow: an existing copy is kept, edited or not.
- **Everything else the kit installs is synced and will be overwritten** by the next
  `review-update.sh`, silently: the five kit scripts (`scripts/review.sh`,
  `scripts/review-install.sh`, `scripts/review-update.sh`, `scripts/review-sync.sh`,
  `scripts/make-plugin.sh`) and
  `scripts/lib/*.sh`; `.review/prompts/`, `.review/adjudication.md`,
  `.review/learnings-shared.md`, `.review/schema.json`, `.review/.gitignore`;
  `.claude/commands/`, `.claude/skills/pre-pr-review/`, `.codex/skills/`,
  `.githooks/pre-push`, `.claude-plugin/`; and `REVIEW.md` and `OPERATING.md` themselves —
  this file included.

  Note this is a list of *paths*, not directories: the kit owns those files inside
  `scripts/`, not the directory. A repo's own scripts live alongside them untouched.
  The `cp` block in `scripts/review-update.sh` is the authoritative list; if the two ever
  disagree, believe the script.
- A finding against any synced file is fixed in the hub and re-synced, not patched in the
  spoke — a spoke-side patch survives until exactly the moment someone runs the updater,
  which is the worst possible time to lose it.
- When a lesson generalises, confirm it actually landed as a **hub commit**,
  not just a note in the repo — routing only works if the hub receives it.
- The hub is public: nothing routed there may carry client, repo, schema, or
  incident specifics.
- Updates are pull-based: the hub pushes nothing to spokes. A lesson reaches
  spokes once it ships in a release tag; `review-update.sh` installs the latest
  release (`--local` for unreleased hub work). The seeded
  `review-kit-sync.yml` workflow polls weekly and opens a sync PR when the
  spoke is behind; a human still has to merge it. A spoke without the workflow
  (opted out, or never re-run with `--init`) relies on `review.sh`, which warns
  when the kit is behind the latest release, or when it cannot tell.

### Cost and depth dials

Six lenses at `high` effort is the deliberate "start hard" posture. If it
feels slow before it feels shallow, dial back in this order: confidence floor
to 0.7 → drop `scope`/`tests` on small diffs → effort to `medium`, and A/B
that last one — more thinking is not reliably better.

### Model pinning

The profile pins `gpt-5.6-sol` — the current standard for code reviews. Two
things follow:

- Effort vocabulary is model-specific: sol accepts
  `none | low | medium | high | xhigh | max` (no `minimal`). An unsupported
  value fails the lens with a 400 — nothing surfaces on the console, but the
  response is in `.review/raw/log-<lens>.txt`.
- When the pin stops resolving or reviews suddenly feel shallow, check
  `/model` in the Codex TUI and re-pin in
  `~/.codex/deep-review.config.toml` before blaming the prompts.

## Reviewing specs before building

The same pipeline points at design documents: `/review-spec <path>` (or
`./scripts/review.sh --spec <path>`) runs four spec lenses — assumptions,
holes, conflicts, ambiguity — that read the spec AND the repository,
verifying every claim the spec makes about existing code and checking it
against the rubric's house rules.

Why it earns its cost: a hole found in a spec costs a paragraph; the same
hole found in code review costs a fix round. And the ambiguity lens directly
counters the implementer-assumption problem — every two-readings statement is
a decision the builder would otherwise make silently; the lens turns them
into an explicit question list you answer before the build starts.

Discipline mirrors the code side: one pass per spec, adjudicate (FIXes edit
the spec; ambiguities usually ESCALATE — that question list is the main
deliverable), resolve, build. No loops. The verdict goes to
`.review/spec-verdict.md`, which the pre-push hook never gates on — a spec review
does not clear the code-review gate.

## The one habit

When CodeRabbit or production catches something this pipeline missed, the
postmortem is not paperwork — it is the only path by which the system gets
smarter, and the routing step is the only path by which one repo's lesson
reaches the others. Skip it and you own a static tool; run it and you own the
loop this was built for.
