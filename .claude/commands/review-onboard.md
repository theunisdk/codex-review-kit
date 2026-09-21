---
description: Wire the review kit into this repository — grounded rubric, verified analyzers, real hazards
argument-hint: "[nothing, or notes about the repo]"
allowed-tools: Bash, Read, Grep, Glob, Edit, Write, Agent
---

Onboard this repository as a spoke of the shared review kit. The machinery is
generic; the value is the adaptation — and the adaptation has one law:
**everything you write must be grounded in code you actually read. An invented
rule is worse than none.**

## 0 — Bootstrap the files

If the kit isn't present yet:
```bash
curl -fsSL https://raw.githubusercontent.com/theunisdk/codex-review-kit/main/scripts/review-update.sh -o /tmp/ru.sh
bash /tmp/ru.sh --init          # syncs machinery, seeds repo-owned templates
./scripts/review-install.sh     # per-machine setup (profile, hooks, pointers)
```
Prefer a local hub clone when one exists — `$REVIEW_KIT_DIR` or
`~/dev/private/codex-review-kit` — and run its `review-update.sh --init`
directly. That path involves no download at all and is the one to use by default.

The curl above fetches `main`, a mutable branch, and the next line executes it.
Anything that changes what `main` points at — a force-push, a compromised
account — runs as you, on your machine. If you must use it, pin the fetch to a
commit you have looked at and check what you got before running it:

```bash
REV=<commit-sha>                     # not `main`
curl -fsSL "https://raw.githubusercontent.com/theunisdk/codex-review-kit/$REV/scripts/review-update.sh" -o /tmp/ru.sh
shasum -a 256 /tmp/ru.sh             # compare against the sha you expect
less /tmp/ru.sh                      # read it
bash /tmp/ru.sh --init
```

If `core.hooksPath` was already set, check whether it points somewhere real
before leaving it alone — stale absolute paths from repo moves are common.

## 1 — Survey the stack

Read the package manifests, lockfile, CI config, and existing agent files
(CLAUDE.md / AGENTS.md — often the best source of documented invariants).
Note: language(s), package manager, build/lint/typecheck/test commands,
default branch. In `.review/config.sh`, set `BASE` explicitly.

## 2 — `.review/analyzers.local.sh`

Wire the repo's real lint/typecheck/gate commands. **Run every command before
wiring it in** — flags rot (eslint 9 removed formatters; monorepos need
`--build`; pnpm ≠ npx). Include repo-specific gates (custom CI checks) — their
output tells the lenses what's already covered. Then test the whole pass:
write one changed file's path into a scratch `changed-files.txt` and invoke
`collect_analyzer_output` — an empty report for a file you know it should
process means broken wiring, and broken looks identical to clean.

## 3 — `.review/rubric.md` house rules

Explore the codebase for its REAL invariants. Places they live:
- the authorization seam (how requests are gated; what every handler must do)
- the data-access seam (what wraps the DB; what must never be called directly)
- money and rates (representation, precision, fraction-vs-percent)
- vocabularies (statuses/roles: enums? rows? who maps keys to labels?)
- schema conventions (id generation, relation actions, soft-delete policy)
- guard tests and custom lint rules (grep the CI config and test names)
- comments citing incident/issue numbers — hard-won rules, already written

For each rule: one bold statement, the file that proves it, and whether
anything enforces it mechanically (a rule nothing enforces is where review
carries the whole weight — say so in the rubric's preface). 5–8 rules beats
20. If you cannot ground a rule in code you read, leave it out and tell the
user the section is thin — do not pad with generic best practice.

Useful pattern: fan out an Explore agent to hunt candidate invariants with
file:line evidence and a confidence per candidate, then verify the keepers
yourself.

## 4 — `.review/prompts.local/<lens>.md` overlays

For each lens where you can name CONCRETE repo hazards, write a fragment
starting `In this repository, additionally hunt for:` — 2–5 bullets naming
files, functions, and the failure mode. A hazard that would apply to any repo
on this stack belongs in the hub, not here. No fragment is better than a
padded one.

## 5 — `.review/learnings.md` repository facts

Misfire guards a reviewer can't infer: directories that are generated,
vendored, or duplicate checkouts (double-counted greps); clients that must be
generated before typecheck; known-weak areas that are pre-existing (report
only when a diff touches them).

## 6 — `.coderabbit.yaml` the PR gate

**First check which case you are in.** `--init` seeds `.coderabbit.yaml` only
when the repo has no CodeRabbit config at all; it deliberately leaves an
existing `.coderabbit.yaml`, `.coderabbit.yml`, or `.coderabbit.config.ts`
alone. So:

- **Seeded** — the rubric is already wired: `knowledge_base.code_guidelines`
  points at `.review/rubric.md` with `applyTo: "**/*"`, and every house rule
  from step 3 reaches CodeRabbit without being copied.
- **Pre-existing config** — nothing was wired. Add the `code_guidelines`
  mappings for `.review/rubric.md` and `.review/learnings.md` (both with
  `applyTo: "**/*"`) to that file yourself, in its own format, and confirm
  `inheritance` is set. Until you do, the gate grades against different
  standards than the lenses — which is the exact split this step exists to
  close.

Either way, do not paste rules into this file. A second copy drifts, and naming
a guidelines file in `path_instructions` tells CodeRabbit to *review* that file
rather than obey it.

What is left to fill in is optional and grounded the same way as everything else
— if you cannot name the evidence, leave the block commented out:

- **`reviews.path_instructions`** — only a rule that applies to SOME paths and
  would misfire elsewhere. `path` is minimatch, `instructions` is inline text.
  Anything holding repo-wide is already covered by the rubric pointer.
- **`reviews.tools.<key>.enabled: false`** — rarely, and never to deduplicate
  against the local pass. CodeRabbit already skips a tool it can see running
  in your CI, so genuine duplication is mostly handled. And the local
  analyzer pass is not a gate: `analyzers.local.sh` tools are optional and
  skipped silently when absent, the lenses are told not to re-report anything
  the analyzers already flagged, and the pre-push hook warns without blocking.
  Disable a tool here only when an *enforced* CI check covers it — otherwise
  you remove its findings from the only gate that was still reporting them.
- **`reviews.path_filters`** — the vendored, generated, and duplicate-checkout
  directories from step 5. `!` entries ONLY: one bare pattern converts the list
  into an allowlist and silently drops every unmatched file from review.

Two properties of this file to respect while editing. A repo-level config
outranks the org's settings and does not merge with them, so `inheritance: true`
must survive whatever you change; and one invalid key discards the entire file
back to defaults, taking the rubric pointer with it. Confirm on the first PR
with `@coderabbitai configuration`, which prints the resolved config and names
the source of each value — the only way to see that this file actually won.

While you are here: if `AGENTS.md` holds nothing but the installer's pointer
block, add the stack facts from step 1 — package manager, build/lint/typecheck/
test commands, default branch. Codex reads it on every lens run and CodeRabbit
picks up a root `AGENTS.md` with no configuration at all, so it is the one file
that reaches both graders for free.

## 7 — Verify, then fire-drill

`./scripts/review-install.sh --check` must pass. Then prove the pipeline on a
scratch branch: plant 2–3 deliberate violations of the rubric you just wrote
(pick ones invisible to lint and tests) and run `./scripts/review.sh`. A
planted violation the lenses miss is a prompt problem — fix it now, cheaply.
See OPERATING.md.

## 8 — Commit

Commit `.review/`, `scripts/`, `.claude/`, `.codex/`, `.githooks/`,
`.claude-plugin/`, `REVIEW.md`, `OPERATING.md`, the AGENTS.md/CLAUDE.md
pointer blocks, and whichever CodeRabbit config step 6 found — do not `git add
.coderabbit.yaml` blind, it is fatal in a repo where `--init` correctly created
no such file. Run artifacts are already gitignored. Report to the user:
the house rules you wrote (with their evidence), what you could NOT ground,
and the fire-drill results.
