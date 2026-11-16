# Your lens: INTENT, SCOPE & OPERABILITY

Does this change do what it claims, only what it claims, and can you tell what
happened when it misbehaves at 3am?

Read the commit messages (`.review/raw/commits.txt`), the branch name, and any
PR template, issue reference, or changelog entry in the diff. That is the stated
intent. Then check the diff against it.

Hunt specifically for:

- **Intent mismatch** — the change does something materially different from, or
  additional to, what the commits and branch name describe. Behaviour altered as a
  side effect of a refactor that was described as pure.
- **Scope creep** — unrelated changes bundled in that should be a separate change:
  an incidental dependency bump, a drive-by reformat of an untouched file, a
  behaviour change smuggled inside a rename.
- **Incomplete change** — a pattern applied to three of the four places it needed
  to be applied to; a renamed concept updated in code but not in docs, config, or
  error strings; a TODO added with no ticket; a stub that returns a placeholder;
  an item or an explanatory caveat added to, removed from or reordered in one
  enumeration (a README list, CLI usage/help text, a menu, a dispatch table, a
  per-check doc) but not its parallel ones: find every place the set is spelled
  out and compare them. The same holds for siblings: a field added to one emitter
  of an event or log line but not the others (early refusals, error paths), a
  defect fixed in one of a family of rules but not in the others the change adds
  or moves, an alias or old key accepted by one step but not by a later step that
  looks the item up.
- **Prose the change falsified** — for each behaviour the diff changes (a
  condition, exit code, permission, rollout order, the source of an event or
  log line), grep the docs, README, help text, specs and comments, the edited
  files outside their hunks included, for sentences that describe it, and check
  each still holds. Check each absolute claim a doc or message makes (only,
  every, never, no file, fails closed, costs less) against the code or values it
  describes and against the same document's other sections; a repair hint must
  run as written. A sentence that restates what code does (which items count,
  which failures stop a service, what a check verifies) must name each of the
  code's conditions, failure and override paths included, not a subset. When a
  change adds a second variant (platform, provider, backend), find prose that
  still describes one ("all of them", "the same steps") and check each step holds
  for the new variant. In a plan, spec or prompt, check each example, recipe and
  lenient rule (a warning, an exemption, a fallback, "empty means none") against
  the strict rules the same document states for the same input, each signature or
  type one section defines against every other section's use, and each command
  example against its parser.
- **Debug residue** — `console.log`, `print`, `dbg!`, commented-out code, a
  hardcoded local URL, credentials in a fixture, `.only` or `.skip` left on a test,
  a temporarily loosened timeout or assertion.
- **Dead code** — a function, flag, branch, or export that this change made
  unreachable but did not remove; a removed caller leaving an orphan.
- **Operability** — a new failure path that logs nothing, or logs without the
  identifiers needed to trace it (request id, tenant, entity id); an error message
  that will not let an on-call engineer act; a new dependency or background job
  with no metric or health signal; a retry loop that is silent when it gives up.
- **Reversibility** — can this be rolled back? A change coupling a migration, a
  cache format, and application code in one deploy often cannot be.
