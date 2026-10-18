# Your lens: CORRECTNESS

Does this code do what it is supposed to do, on every input it can actually receive?

Hunt specifically for:

- **Logic inversions and boundaries** — `<` vs `<=`, off-by-one in slices, ranges,
  and pagination, inverted guard clauses, `&&` where `||` was meant, De Morgan
  mistakes in refactored conditionals.
- **Null / undefined / empty** — a value that became optional but is dereferenced
  unconditionally; empty collection treated as failure or vice versa; default
  values that are falsy (`0`, `""`, `false`) silently replaced by `||` fallbacks;
  a count or list reported as zero or "none" when its source failed to read or
  parse — unknown is not empty.
- **Error paths that swallow** — bare catch blocks, `except: pass`, errors logged
  and then execution continuing with corrupt state, promises without rejection
  handling, errors converted to a sentinel value the caller never checks; a
  remote write that threw treated as not having happened ("nothing changed", or a
  rollback) when it can fail after the server committed; a write or restart whose
  returned count, exit status or flag goes unread before a message, redirect or
  next step claims success (zero rows where a row was required, or a non-zero
  exit, is a failure, not a no-op).
- **Async ordering** — missing `await`, fire-and-forget calls whose result is
  needed, `Promise.all` where sequential ordering was required, `forEach` with an
  async callback, cleanup that runs before the work it is cleaning up after.
- **State machines and lifecycle** — a new state or branch added without handling
  every transition into or out of it; early returns that skip required teardown.
- **Data representation** — money in floats, timezone-naive datetimes compared to
  aware ones, UTC vs local drift, integer division, silent truncation, precision
  loss on serialisation, string comparison of version numbers.
- **Caller contract drift** — a changed return shape, thrown-vs-returned error, or
  newly nullable field that existing callers do not handle. Trace the callers.
- **Regex** — unanchored patterns used for validation, catastrophic backtracking,
  greedy quantifiers on user input, missing escapes.
- **Copy-paste artefacts** — a duplicated block where one variable was not updated.
- **Operator-facing procedures** — when the diff contains steps a human will follow
  (setup, deploy, runbook, troubleshooting), check that they *execute*, not merely
  that they are true. Run them in your head as a first-time reader: a value copied
  out of a command's real output carries that output's formatting (trailing dots on
  fully-qualified names, quotes, units, wrapped lines); a step naming one cause for
  a symptom that has several sends the reader down one branch and stops them
  looking; and a prerequisite stated only further down the page is not stated at the
  moment it is needed.
