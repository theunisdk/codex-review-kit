<!--
Kit-wide review memory, shared by EVERY repo that syncs this kit. Injected into
every lens prompt ahead of the repo's own learnings.md.

What belongs here: lessons that hold in any repo (generic review blind spots)
or in any repo on a given stack (mark with a "stack:" prefix). What does NOT:
anything naming a repo, a client, a schema, or an incident — that goes in the
repo's own .review/learnings.md and never leaves it. This file lives in a
PUBLIC repository; write accordingly.

Same hygiene as learnings.md: short entries, prune stale ones, consolidate
before this file dilutes the prompts it feeds.
-->

## SUPPRESS

## WATCH
- stack:eslint9 — eslint 9 removed all non-core output formatters (`unix`,
  `compact`, …); tooling that passes `--format unix` fails silently under
  `2>/dev/null`. Check the analyzer report actually has an eslint section
  before assuming lint ran.
- 2026-08-24: a guarded conditional write rechecked the target row's own
  columns but not the other inputs (counts from related tables) the written
  value was computed from — when verifying concurrency guards, enumerate every
  input of the computed value, not just the guarded row.
- 2026-08-24: a change that widens what a selector can return left downstream
  copy asserting the old narrower set — when a diff widens a selectable or
  returnable set, re-read every consumer of the selection for baked-in
  assumptions about the old shape.
- 2026-09-01: a documentation diff was verified as *true* and passed; three real
  defects were findable only by asking whether *following* it works — a value the
  reader was told to copy from a command's output differed from the example, and
  a troubleshooting step attributed a multi-cause symptom to a single cause.
  Prose that instructs is code: trace it, don't just fact-check it.
- 2026-09-01: a change that adds guidance premised on a broader configuration can
  falsify unchanged text elsewhere in the same file — the contradiction sat two
  paragraphs from the hunk and survived because the lens read the diff and its
  immediate context. When a diff relaxes or widens an assumption, re-read the
  whole file for sentences written under the narrower one.
- 2026-10-18: an error path reported "nothing written" after a remote write
  threw, but a rejected or timed-out call can still have committed. Flag any
  message or rollback that assumes a thrown remote call had no effect, unless
  the code first settles the outcome (a read-back, or a confirmed retry).
- 2026-10-18: a "changed since shown?" guard compared a parsed summary, so two
  different unparseable values compared equal and a reset could overwrite the
  wrong one. A guard deciding whether data changed must compare the raw bytes
  or a version/ETag, not a lossy parse.
- 2026-10-18: an update's affected-row count was discarded, so a write that
  matched zero rows still redirected as saved; a recovery restart's exit status
  went unread under "started again". At every write, restart or rollback call,
  find the line that reads what it returned (count, exit status, flag); none
  before a success message, redirect or next step that needs it to have
  happened is a finding.
- 2026-10-18: a confirmation gating a destructive action showed "none pending"
  for a count whose source failed to parse. At every count, list or "none" a
  user sees, trace its source through each state (absent, unreadable,
  unparseable), not only the parsed one.
- 2026-10-18: prose and messages stated a different condition than the code
  has: docs promising "only new" items from overlapping fetch windows, a warning
  naming one of several triggers as the cause, a documented failure condition
  that also admits a harmless no-op, a `file:line` citation the same diff moved.
  For every guarantee, cause or condition a doc or user-facing message states,
  list the code paths that produce it and check the claim holds on each.
