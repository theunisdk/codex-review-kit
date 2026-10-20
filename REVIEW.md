# Codex pre-PR review kit

Six narrow, parallel Codex review passes over your branch diff, merged into
structured findings, adjudicated by Claude Code, gated by CodeRabbit on the PR.
Once it's wired up, read **OPERATING.md** — how to prove the pipeline works
(scorecard, fire drills) and the quiet failure modes to watch.

The design premise: a single "review this diff" pass gets you roughly what Claude
Code already gives you. The quality comes from **decomposition** — several
reviewers each with a tight brief and enough budget to trace outward from the
diff into callers, tests, and config.

## Pipeline

```
  branch with changes
        │
        ├─ scripts/review.sh ──┬─ correctness ─┐
        │                      ├─ security     │
        │  (+ linters/semgrep  ├─ contracts    ├─→ .review/findings.json
        │     first, as priors)├─ resources    │   .review/findings.md
        │                      ├─ tests        │
        │                      └─ scope      ──┘
        │
        ├─ /review in Claude Code
        │     verifies each finding against real code
        │     → FIX / LOG(issue) / REJECT(reason) / ESCALATE
        │     → .review/verdict.md
        │
        ├─ push → PR → CodeRabbit (final gate)
        │
        └─ /review-postmortem <PR>
              what CodeRabbit caught that we missed → .review/learnings.md
              → next run is better
```

## Install

**Requires:** `git`, `jq`, `codex` (authenticated). Optional but recommended:
`semgrep`, `gitleaks`, plus your language's linter, and `python3` with PyYAML,
which reads the CodeRabbit config's `path_instructions` for the lenses (see
[Path rules](#path-rules)).

**Hub and spokes.** The kit's source of truth is one public hub
(`github.com/theunisdk/codex-review-kit`). Each repo is a spoke: it
vendors the shared machinery via `scripts/review-update.sh` and commits it,
alongside the files that are its own and never synced:

| | lives | moves |
|---|---|---|
| runner, lens prompts, schema, adjudication, commands, skill, hooks | hub → synced into every spoke | `scripts/review-update.sh` |
| `learnings-shared.md` (generic + stack lessons) | hub → synced read-only | same |
| `rubric.md`, `config.sh`, `learnings.md`, `prompts.local/`, `analyzers.local.sh` | spoke only | never |
| `.coderabbit.yaml` (the PR gate) | spoke only, seeded once by `--init` | never |
| `.github/workflows/review-kit-sync.yml` (the weekly release check) | spoke only, seeded once by `--init` | never |

**New repo:** say `/review-onboard` in Claude Code — it bootstraps the files
and, more importantly, does the adaptation properly: a rubric grounded in code
it actually read, analyzer commands verified before wiring, concrete lens
hazards, and a fire drill to prove the result. By hand, with a local hub
clone supplying the updater:

```bash
git -C ~/dev/private/codex-review-kit pull --ff-only \
  && bash ~/dev/private/codex-review-kit/scripts/review-update.sh --init
./scripts/review-install.sh          # per-machine setup
```

The clone only supplies the script, so pull it first: an updater from before
v1.3.0 installs the clone's working tree whatever you pass. The updater fetches the hub's latest
release tag (highest `vN.N.N`) and installs that, or the tag or full SHA in
`$REVIEW_KIT_REF`. If it cannot list or fetch the release, it fails rather
than install something else. To sync unreleased hub changes onto a spoke
(testing hub work before a release), pass `--local`: it installs the clone's
working tree (`$REVIEW_KIT_DIR`, else `~/dev/private/codex-review-kit`) and
records it as unreleased.

Without a clone, this fetches the updater at the hub's latest release tag —
or the tag or full SHA in `$REVIEW_KIT_REF` — and refuses anything else,
`main` included. Both `less` pauses are the point: read each file before
the next line executes it.

```bash
(
  KIT=https://github.com/theunisdk/codex-review-kit
  TAGS=$(git ls-remote --tags "$KIT") || { echo "stopped: cannot reach $KIT" >&2; exit 1; }
  LATEST=$(printf '%s\n' "$TAGS" | sed -n 's|.*refs/tags/v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$|\1|p' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  REF="${REVIEW_KIT_REF:-${LATEST:+v$LATEST}}"
  [ -n "$REF" ] || { echo "stopped: no release tag on $KIT — set REVIEW_KIT_REF" >&2; exit 1; }
  if printf '%s\n' "$REF" | grep -Eqx '[0-9a-f]{40}'; then SHA=$REF
  else SHA=$(printf '%s\n' "$TAGS" | awk -v t="refs/tags/$REF" -v sha=1 -v ref=2 \
      '$ref == t {s=$sha} $ref == (t "^{}") {p=$sha} END {print (p != "" ? p : s)}') \
      || { echo "stopped: cannot read the tag listing" >&2; exit 1; }
  fi
  [ -n "$SHA" ] || { echo "stopped: '$REF' is neither a tag on $KIT nor a full commit SHA" >&2; exit 1; }
  RU=$(mktemp) \
    && curl -fsSL "https://raw.githubusercontent.com/theunisdk/codex-review-kit/$SHA/scripts/review-update.sh" -o "$RU" \
    && less "$RU" \
    && REVIEW_KIT_REF="$SHA" bash "$RU" --init \
    && less scripts/review-install.sh \
    && ./scripts/review-install.sh \
    || { echo "stopped: a step above failed" >&2; exit 1; }
)
```

Then, either way:

```bash
# adapt the repo-owned files — .review/, plus the gate at the root:
#   .review/rubric.md  .review/learnings.md  .review/config.sh
#   .review/analyzers.local.sh  .review/prompts.local/
# --init seeds .coderabbit.yaml only when the repo had no CodeRabbit config,
# so stage whichever one it actually has rather than assuming that name.
# The sync workflow is absent when KIT_SYNC_ACTION=0 kept --init from seeding it.
git add .review scripts .claude .codex .githooks .claude-plugin REVIEW.md OPERATING.md AGENTS.md CLAUDE.md
for f in .coderabbit.yaml .coderabbit.yml .coderabbit.config.ts \
         .github/workflows/review-kit-sync.yml; do
  if [ -f "$f" ]; then git add "$f"; fi
done
git commit -m "chore: add codex pre-PR review pipeline"
```

**Every other machine:** clone the repo, run `./scripts/review-install.sh`.
Everything repo-specific is committed; the only per-machine artifact is
`~/.codex/deep-review.config.toml`, which the installer creates if absent and
never overwrites. `--check` verifies without changing anything.

**Picking up kit improvements:** `./scripts/review-update.sh` in any spoke
installs the hub's latest release. It overwrites the synced half, prints the
source and revision it installs, writes ref, commit and release to the
generated `.review/kit-version`, and leaves the repo-owned half alone. Fix a
machinery bug or add a generic lesson once, in the hub; every repo inherits it
on its first sync after that fix ships in a release tag. `--local` installs a
hub clone's working tree instead, recorded as `unreleased`.
`--latest-release` prints the latest tag and installs nothing.

`--init` also seeds `.github/workflows/review-kit-sync.yml`, which runs
`scripts/review-sync.sh` weekly (minute, hour and weekday derived from the repo
name) and on demand. When the spoke is behind, it runs the updater pinned to the
latest release on the branch `review-kit-sync` and opens one PR, "sync review
kit to vX.Y.Z". A newer release retitles and force-pushes that PR; if the PR
carries commits the sync did not make, the job refuses and fails. A sync PR
closed unmerged declines that release until the next one. Nothing merges,
approves or enables auto-merge: a human reviews every sync. The PR body names
synced files whose local edits the sync overwrote, lifts each skipped release's
`## Upgrading` section to the top, and carries the full release notes.

The sync PR body opens with `@coderabbitai ignore`, so CodeRabbit skips it and
spends none of the account's hourly review quota. A sync changes only synced
files, which CodeRabbit already reviewed in the hub PRs that shipped them;
repo-owned files (rubric, learnings, `.coderabbit.yaml`, `config.sh`,
`analyzers.local.sh`, the sync workflow) never change in a sync. The hub review
graded the kit against the hub's `path_instructions`, not the spoke's, so the
human who merges the sync PR is the remaining check, and commits pushed to the
branch are skipped too. To have CodeRabbit review a sync PR, delete the line
from its description, then comment `@coderabbitai review`: deleting it alone
resumes reviews only from the next push. A newer release's update of that PR
adds the line back after its push, so CodeRabbit reviews that one push. The
spoke builds the body with its installed `review-sync.sh` (the script is read
whole before the sync copies files), so the line first appears in the sync run
after the sync PR that delivers it has merged.

Every failure fails the job: hub unreachable, no release tag, a failed or empty
sync, a release-notes lookup that errors, a refused push, a `gh` error, a run
from a branch other than the default. Actions must be allowed to open PRs:
Settings > Actions > General > Workflow permissions > "Allow GitHub Actions to
create and approve pull requests" (in an organization, the org-level setting
first). A PR opened with the default token starts no workflows, so CI waits for
someone to push to the branch; a `REVIEW_KIT_SYNC_TOKEN` secret (a fine-grained
token with contents and pull-requests write) avoids that. GitHub disables
scheduled workflows in a public repo after 60 days without activity. The
workflow is repo-owned once seeded: syncs never touch it and `--init` keeps an
edited copy. To opt out, set `KIT_SYNC_ACTION=0` in `.review/config.sh` and
delete the file if it was already seeded.

A spoke synced by an updater from before v1.3.0 gets neither
`scripts/review-sync.sh` nor the workflow from that sync, because the old
updater does not know them. Run `./scripts/review-update.sh --init` once more
after it.

With or without the workflow, `review.sh` checks the installed release at
startup. It warns when the installed release is
behind the latest one, or when it cannot tell (hub unreachable, no release
tags, a `kit-version` that names no release). It never blocks a review. The
lookup is cached under the git common dir: a day after a successful check, an
hour after a failed one.

**Releasing the hub:** a release is a `vN.N.N` tag plus GitHub release notes,
and the notes must carry a `## Upgrading` section (any heading that starts
`## Upgrading`, e.g. `## Upgrading from v1.1.2 or earlier`). It says "No special
steps." or names every contract change that repo-owned files or consumers must
follow: a new or changed key in `findings.json`, a renamed `config.sh`
variable, a change to the rubric or learnings format. The sync PR lifts that
section to the top for every release it skips over, and flags a release
without one as unreadable for contract changes.

**Folding lessons:** before tagging, triage the hub's open `lesson` issues and
the misses in each spoke's `review-history/` and `review-replay/` records
(under its git common dir) since the last tag. Fold what recurred in two or
more PRs into `learnings-shared.md` or a base prompt, close what is stale, and
list what was folded in the release notes under its own heading, not
`## Upgrading`. The notes are public: describe each lesson generically, never
with spoke code, and name a spoke whose records could not be read by alias,
never by repo name or path.

`make-plugin.sh` still exists for a Claude Code plugin build, but the runner
reads prompts from the repo, not `${CLAUDE_PLUGIN_ROOT}` — the vendored spoke
layout is the supported path; the plugin is untested sugar.

## Use

```bash
./scripts/review.sh                    # vs auto-detected base branch
./scripts/review.sh origin/develop     # explicit base
./scripts/review.sh --uncommitted      # working tree, before you commit
./scripts/review.sh --spec docs/specs/foo.md   # review a DESIGN DOC pre-build
./scripts/review.sh --lenses security,contracts --effort xhigh
./scripts/review.sh --fail-on high     # exit 2 if anything high+ (for CI)
```

In Claude Code:

| Trigger | Does |
|---|---|
| **skill** `pre-pr-review` | Fires on its own when you're wrapping up — "ready to push", "does this look right", "anything I missed" |
| `/review` | Same thing, explicitly, with arguments |
| `/review-onboard` | Wires the kit into a new repo: grounded rubric, verified analyzers, fire drill |
| `/review-spec <path>` | Reviews a design doc pre-build: assumptions verified against the repo, holes, conflicts, ambiguity |
| `/review-tune` | Folds recurring rejections into `learnings.md` to cut noise |
| `/review-postmortem <PR>` | Records what CodeRabbit caught that we missed |

`.review/findings.json` holds the merged `findings` and says how far to trust them:

| Key | Meaning |
|---|---|
| `complete` | `false` when a lens failed, a path was unreadable, the secret scan failed, or there was nothing to review. A skipped secret scan leaves it `true`: check `secrets_scan` too |
| `lenses_failed` | lenses that did not finish; their areas are unreviewed |
| `unreadable_paths` | changed paths no lens could read |
| `changed_files` | how many paths were reviewed; `0` means nothing was, and no verdict may be written from it |
| `secrets_scan` | `clean`, `leaks` (a critical `gitleaks` finding carries it), `failed` (forces `complete: false`), or `not_scanned` (gitleaks not installed, `--no-analyzers`, or nothing to scan) |
| `analyzers` | `{status, reason, tools}`. `status` is `ran`, `not_run` (`--no-analyzers`, spec mode) or `failed` (the pass broke). Each of `tools` is `{name, status, reason}`, with `status` `ran`, `skipped`, `failed` or `unknown`; only `ran` holds results. A tool that did not run leaves `complete` alone, but what it checks went unchecked |
| `history_scan` | zero-change runs on a branch with commits only: `{commits, result}` for the history scan |
| `mode` | `branch`, `uncommitted` or `spec`. An `uncommitted` verdict names its commit as `<head>+uncommitted`, which clears no push |
| `head` | HEAD's short SHA when the run started; `null` on a branch with no commits |

Both the skill and the command delegate to `.review/adjudication.md`, so the
behaviour is identical however the review started. Edit that file to change what
adjudication means; don't edit the callers.

The verification step is the point. Codex hallucinates line numbers and
occasionally invents behaviour; findings applied unverified are worse than no
review at all.

## Path rules

A house rule that holds only for some paths lives in the CodeRabbit config's
`reviews.path_instructions`, not in `rubric.md`. On every run, `review.sh` reads
that config (`.coderabbit.yaml`, else `.coderabbit.yml`) and puts each rule whose
glob matches a changed file into every lens prompt, under the rubric, so the
lenses grade those files against the same text the gate does. The config is read
at review time rather than copied into the rubric, so there is no second copy to
drift. Globs follow minimatch: `**` spans directories, braces and ranges
expand, and a pattern without a slash matches top-level paths only. Extglobs,
POSIX classes, `!` negation and braces expanding to more than 256 alternatives
are not supported, and an entry that uses them is reported as `invalid` rather
than matching nothing. Rules the org-level config adds through
`inheritance: true` are not in the file and do not reach the lenses;
`findings.md` says so whenever the file sets it.

`findings.json` records the outcome in `path_rules.status`. Three statuses are
a real "nothing": `no_config`, `no_rules` (no `path_instructions`) and
`no_match` (no glob matches the change set). `applied` means at least one rule
reached the lenses. Every other status carries a `warning`, shown in
`findings.md` and on stderr, because the lenses graded without some or all of
the rules: `unparseable` (CodeRabbit discards such a file too), `invalid`
(`reviews` or `path_instructions` of the wrong type, explicit null included, or
an entry without a string `path` and `instructions` or with an unsupported
glob; the valid entries still apply), `no_parser` (no `python3` or PyYAML),
`not_inspected` (`.coderabbit.config.ts`, or an undotted `coderabbit.yaml` or
`coderabbit.yml`, neither of which is read) and `failed` (an unreadable file or
a crashed reader). None of them makes `complete` false: the lenses still
reviewed the diff.

## Skills: which tool needs one, and why

**Claude Code: yes — for discovery.** Slash commands only fire when typed. Without
the skill, saying "ok, that's done, let's push" gets you an ad-hoc read of the
diff — the weaker review this pipeline exists to replace. The skill's description
is tuned to trigger on that class of phrasing, and its body tells Claude Code not
to improvise a review instead.

**Codex: no, not in the hot path.** Skills exist for progressive disclosure — the
agent sees descriptions, then loads the full `SKILL.md` when it judges a match.
But `scripts/review.sh` calls `codex exec "<the entire prompt>"`. We already know
what we want and pass it in full, so a skill would be pure indirection: same
tokens, plus a new failure mode where it fails to trigger. The layer Codex
actually reads automatically is `AGENTS.md`, which the installer writes — and
CodeRabbit detects a root `AGENTS.md` with no configuration at all, so it is
the one file that reaches every grader for free.

`.codex/skills/repo-review-standards/` ships anyway, for when you drive Codex
interactively (`/review` in the TUI, ad-hoc critique) and want the same rubric
applied. It is genuinely optional — delete it and the pipeline is unaffected.

## Tuning

You said start hard and tone down. Defaults reflect that: all six lenses, `high`
effort, `0.5` confidence floor. Dial back in `.review/config.sh` (committed, so
every machine agrees) in roughly this order:

1. **Confidence floor → 0.7.** Cheapest noise reduction, costs nothing in time.
2. **Drop lenses.** `scope` and `tests` are the usual first cuts on small diffs.
3. **Effort → medium.** Do this last, and A/B it — more thinking is not reliably
   better here. One published benchmark found a Codex model scoring *worse* at
   high effort than medium, because the extra tokens forced context compaction.
   Your mileage will vary by model; measure on a PR where you know the answer.

Going the other way: `--effort xhigh` (model-dependent), lower the confidence
floor to `0.3`, or add a seventh lens — copy any `prompts/*.md`, write a "hunt
specifically for" list, add the name to `LENSES`.

## The two feedback loops

These are what make it improve rather than plateau:

**Noise down** (`/review-tune`): recurring REJECT reasons become SUPPRESS entries
in `learnings.md`, injected into every future prompt. Requires two occurrences —
one rejection is a one-off.
Verdicts are gitignored, so `review.sh` and the pre-push hook archive each one
to `$(git rev-parse --git-common-dir)/review-history/`: shared by every
worktree of the clone, kept after a worktree is removed, never committed.
`/review-postmortem` reads it to find the verdict for the commit CodeRabbit
reviewed, and writes its own records there. `/review-tune` reads the verdicts
and those records.
`/review-tune` also reads `.review/archive/`, the store it read before v1.2.2,
and counts a verdict found in more than one store once.

**Coverage up** (`/review-postmortem <PR>`): CodeRabbit's findings are scored
against the local verdict for the **first commit CodeRabbit reviewed**. It is
matched by the SHA in the verdict header; `.review/verdict.md` is used only
when its header names that commit. A `<sha>+uncommitted` verdict from
`--uncommitted` is never used: it may have been written after reading
CodeRabbit, and the postmortem names each one it skips. A verdict for an earlier commit on the
PR's branch, or findings CodeRabbit raised on later heads, still score
whatever code was already there at the reviewed commit. With no
verdict for that commit or such an ancestor, the PR is recorded as `no-local-verdict` and not scored, which is
not the same as `missed 0`. Every missed finding is diagnosed by cause —
wrong lens, insufficient tracing, filtered by threshold, or structurally out of
reach — from the lens logs in `.review/raw/`, and turned into a prompt edit
or a WATCH entry. Without those logs the cause is `unverified`.

The scorecard is kept twice. It is a PR comment marked
`<!-- review-postmortem:v1 -->` with a JSON record, which a re-run updates
in place. A copy goes to `review-history/postmortem-pr<n>.md`. Both list the
author's disposition of every CodeRabbit finding, including the ones
rejected in a thread reply, so `/review-tune` learns from those too.

**Replays** (`scripts/review-replay.sh <spoke> <PR>… | --recent N`, in the
hub only) run the coverage loop on PRs that merged without a local verdict.
For each PR it clones the first commit CodeRabbit reviewed into a
throwaway checkout outside the spoke. The clone holds that commit's history
and no ref or object past it, so the lenses and the adjudicator cannot read
a later fix. It overlays the hub kit at `--kit-ref` on the repo-owned files
of that commit. Then it runs `review.sh`, adjudicates headlessly, and scores
the verdict with `/review-postmortem --replay`, which alone is given the
spoke's objects to compare later heads. A replay measures **today's kit** on old
code, not the review that ran then. A live postmortem says what this PR's
review missed; a replay says what the current kit would still miss. It
posts nothing, files nothing and pushes nothing. Its record goes to
`<git common dir>/review-replay/pr<n>-<kit>/`, with each lens's raw output,
each `claude` call's full transcript and its denied commands, and each run's
scorecard to `review-replay/runs/<time>-<kit>/`. Neither goes
to `review-history/`, so `/review-tune` and later postmortems do not read it
as history. `scripts/review-replay-sum.sh` sums the scorecards of runs from
several spokes. See OPERATING.md for what it costs and how to read it.

Both commands **route** each lesson before writing it: repo-specific lessons
land in the repo's `learnings.md` or `prompts.local/`. Anything that would
hold in another repo goes to the hub as an issue labelled `lesson` on
`theunisdk/codex-review-kit`, never as a commit in a local hub clone, and
scrubbed of repo and client specifics since the hub is public. The hub folds
lessons into `learnings-shared.md` or a base prompt in a release. That routing
is what makes a bug found in one repo teach every other repo on its first
`review-update.sh` after that release.

Track the postmortem scorecard. If `missed` trends toward zero, the local pass
is working and CodeRabbit is insurance. A plateau is a hypothesis until the
misses are classified by cause. Misses from the wrong lens, insufficient
tracing or the threshold can be fixed here; a plateau of those means the fixes
are not landing. Only misses classed structural point at value this pipeline
cannot reproduce, such as repo-wide indexing, cross-PR memory or CodeRabbit's
analyzer fleet. That is fine, since CodeRabbit is still your final gate.

## Layout

```
.review/
  rubric.md            REPO-OWNED  standards — single source of truth
  learnings.md         REPO-OWNED  this repo's memory, never leaves it
  config.sh            REPO-OWNED  posture (all values commented out = defaults)
  analyzers.local.sh   REPO-OWNED  stack wiring, replaces the generic stanzas
  prompts.local/       REPO-OWNED  per-lens hazard overlays, appended at run time
  adjudication.md      synced      verify → FIX/LOG/REJECT/ESCALATE → verdict
  learnings-shared.md  synced      kit-wide memory, edited only in the hub
  kit-version          generated   what the last sync installed: ref, commit, release (or unreleased)
  schema.json          synced      enforced output shape via codex --output-schema
  prompts/             synced      the shared lens prompts — never edit in a repo
    _common.md         role, method, hard exclusions, calibration
    correctness.md     logic, nulls, async ordering, contract drift
    security.md        authz, injection, SSRF, secrets, crypto, limits
    contracts.md       API breaks, migrations, rolling-deploy safety
    resources.md       races, locks, leaks, N+1, timeouts, transactions
    tests.md           would these tests have caught it? the revert test
    scope.md           intent fidelity, debug residue, operability
    _common-spec.md    spec-mode role and method (claims verified in-repo)
    spec-*.md          spec lenses: assumptions, holes, conflicts, ambiguity
scripts/               all synced
  review.sh            the runner
  review-update.sh     pull the shared half from the hub
  review-sync.sh       open a sync PR when a newer release exists (run by the workflow)
  review-install.sh    idempotent per-machine setup
  lib/common.sh        portable helpers (macOS bash 3.2 safe)
  lib/analyzers.sh     generic analyzer collection; defers to analyzers.local.sh
  lib/path-rules.sh    the CodeRabbit path_instructions that match the diff, for the lenses
.claude/               synced: /review, /review-tune, /review-postmortem + skill
.codex/                synced: optional interactive-Codex skill
.claude-plugin/        synced: plugin manifests
.githooks/pre-push     synced: warns on a stale verdict by default; blocks when REVIEW_STRICT=1
.coderabbit.yaml       REPO-OWNED  the PR gate; points CodeRabbit at rubric.md, and its
                                   path_instructions reach the lenses too
.github/workflows/review-kit-sync.yml
                       REPO-OWNED  weekly release check, seeded by --init
templates/             hub only: seeds for the repo-owned files (--init)
```

## Notes and gotchas

- **Codex profiles moved.** Since 0.134.0, `--profile` no longer reads
  `[profiles.name]` tables from `config.toml`. Each profile is its own file with
  top-level keys: `~/.codex/deep-review.config.toml`. If you copy a profile from
  an older blog post it will silently do nothing.
- **Model names churn.** The profile pins `gpt-6.1-sol` — the current standard
  for code reviews. An existing profile is never rewritten; `review-install.sh
  --check` warns when it pins another model. When the pin stops resolving,
  check `/model` in the Codex TUI for what your plan exposes and re-pin; note
  the effort vocabulary is model-specific (gpt-6.1-sol:
  `low|medium|high|xhigh|max|ultra`, no `none` or `minimal`; `ultra` adds
  automatic task delegation and is not for the headless, read-only lenses).
- **Reviewers are read-only.** Every lens runs `--sandbox read-only`; the
  deep-review profile supplies `approval_policy = "never"`, since codex 0.149
  removed `--ask-for-approval`. They can grep your repo for context but cannot
  touch your working tree — only Claude Code writes, and only after verification.
- **A lens failing is non-fatal.** Others still run; check `.review/raw/log-*.txt`.
  Only a total failure aborts.
- **Adjudication has a bias problem.** Claude Code reviewing findings about code
  Claude Code just wrote will tend to reject. The mandatory written reason helps.
  Spot-check a sample manually for the first couple of weeks anyway.
- **Add your stack's linters** to `.review/analyzers.local.sh` (never to
  `scripts/lib/analyzers.sh`, which the next sync overwrites). Their output is
  fed to Codex as "already covered, don't re-report" — which is what pushes the
  lenses toward semantic bugs instead of lint-level noise. Run each one through
  `_run_analyzer` (see `templates/analyzers.local.sh`), so a tool that could
  not run is labelled `failed` or `unknown` rather than passed on as results.
