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
  parse — unknown is not empty; a read of config, a credential or remote state
  whose outcomes (absent, present but invalid, unreachable, explicitly empty)
  collapse into one result, message or exit code: list them at each read and
  check each gets its own, so an invalid value never reads as a missing one.
- **Error paths that swallow** — bare catch blocks, `except: pass`, errors logged
  and then execution continuing with corrupt state, promises without rejection
  handling, errors converted to a sentinel value the caller never checks; a
  remote write that threw treated as not having happened ("nothing changed", or a
  rollback) when it can fail after the server committed; a write or restart whose
  returned count, exit status or flag goes unread before a message, redirect or
  next step that presumes it changed a row or ran (zero rows or a non-zero exit
  is then a failure, not a no-op). To find them, list each call in the changed
  code whose return value is discarded (a bare statement, an `await` alone, a
  release or cleanup inside a catch or finally) and check what it returns.
- **Async ordering** — missing `await`, fire-and-forget calls whose result is
  needed, `Promise.all` where sequential ordering was required, `forEach` with an
  async callback, cleanup that runs before the work it is cleaning up after.
- **State machines and lifecycle** — a new state or branch added without handling
  every transition into or out of it; early returns that skip required teardown.
- **Data representation** — money in floats, timezone-naive datetimes compared to
  aware ones, UTC vs local drift, integer division, silent truncation, precision
  loss on serialisation, string comparison of version numbers; a key, lock, file
  or variable name built by joining or normalising parts (a separator the parts
  may themselves contain, case-folding) so two distinct inputs share one name;
  a create path and its read or remove path that derive the same resource's
  location from different sources, so they can name different resources.
- **Gates that pass on the wrong input** — for each check whose pass the code
  treats as proof (a freshness or approval gate, a validator, an allow or deny
  match, an error class the caller accepts as "expected"), name one input where
  the property is false and the check still passes: an identifier matched
  anywhere in a document instead of in its field, an empty list that runs no
  check, a catch-all error class standing in for the specific one.
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
