---
description: Fold recurring review rejections into .review/learnings.md to cut noise
allowed-tools: Bash, Read, Grep, Glob, Edit, Write
---

Reduce false-positive noise in the Codex review by learning from what we rejected.

1. Gather rejection history. You need the verdict BODIES — commit subjects say
   nothing about what was rejected. Read every verdict in the stores below.
   Report what each held: a file count, empty, missing, or unread with the
   error. An unread store means the history is unknown, not empty.
   - The clone's review history, shared by every worktree. Run
     `git rev-parse --path-format=absolute --git-common-dir` on its own first;
     if it fails, stop and say so. Then list `<that dir>/review-history`.
     `scripts/review.sh` and the pre-push hook archive into it. Code verdicts
     are `code-<date>-<sha>-<cksum>.md`, spec verdicts
     `spec-<date>-<sha>-<cksum>.md`, headerless ones
     `<mode>-unparsed-<cksum>.md`. The name's mode comes from the header, so
     it can be wrong for an old spec verdict (see below).
   - The legacy archive, `.review/archive/`, which kits before v1.2.2 read
     instead. It holds a repo's pre-upgrade history and follows no naming
     scheme: `find <worktree>/.review/archive -type f`.
   - The legacy archive's committed history, reported on its own. The kit
     does not gitignore the archive, so a repo may have committed it, then
     deleted or overwritten files.
     `git log --all --name-status --format=%H -- ':/.review/archive/'` lists
     each version: read it with `git show <sha>:<path>`, or
     `git show <sha>^:<path>` when the status is `D`. If
     `git rev-parse --is-shallow-repository` prints `true`, report this
     history as partly unread.
   - The live verdicts, `<worktree>/.review/verdict.md` and
     `<worktree>/.review/spec-verdict.md` (identical to an archived copy
     unless written since the last run or push).

   The legacy archive and the live verdicts are per worktree. Check them in
   every `worktree` entry of `git worktree list --porcelain`, skipping a
   `bare` one. Report a worktree whose directory is gone or that is marked
   `prunable` as unread.

   A verdict starts at a `# Review verdict — <branch> — <sha> — <date>` or
   `# Spec verdict — …` line; a file may hold several. Before v1.2.0, spec
   verdicts also used `# Review verdict`. So a `# Spec verdict` header, or
   any `spec-*` lens on its `Lenses:` line, makes it a spec verdict. A file
   with no header takes its mode from its `Lenses:` line, else from its
   `<mode>-unparsed` name or the live file it came from. Name each such file
   and the mode you assumed.

   Count each verdict once, wherever it was found. Files with the same
   `cksum` are one verdict; a review-history name ends in its `cksum`. Two
   verdicts of one mode and commit (SHAs match when one is a prefix of the
   other) that judge the same findings are one review adjudicated twice, and
   so are two with the same findings table when either is headerless: count
   a rejection repeated across them once. Different reviews of one commit,
   such as two specs, count separately. If every store was read and is
   missing or empty, say so: that is no history in this clone, not a clean
   one. Another clone's review history is not visible from here. Read each
   verdict's Rejected section. Keep spec rejections in their own classes:
   `learnings.md` reaches the code lenses too, so a suppression drawn from
   spec rejections must say it applies to spec review only.

2. Group the REJECT reasons into classes. You are looking for the same rejection
   made two or more times — one rejection is a one-off, two is a pattern.

3. For each recurring class, propose one line for the `## SUPPRESS` section of
   `.review/learnings.md`. Rules for a good suppression:
   - Narrow. Scope it to a path, a pattern, or a category — never "ignore security
     findings".
   - Stated as a repository fact, not a preference: "auth is enforced by middleware
     in `server/mw/auth.go`, so handler-level authz findings in `handlers/` are
     false positives" beats "don't report missing authz".
   - If the real fix is a standards change rather than a suppression, propose an
     edit to `.review/rubric.md` instead.

4. Route each lesson before proposing it. Ask: would this suppression hold in
   a DIFFERENT repository?
   - **Repo-specific** (names this repo's files, architecture, or data) →
     `.review/learnings.md`, as below.
   - **Generic or stack-level** (would hold in any repo, or any repo on this
     stack) → it belongs in the kit hub's `learnings-shared.md` instead.
     The hub checkout is `$REVIEW_KIT_DIR`, or
     `~/dev/private/codex-review-kit`; `.review/kit-version` names the
     commit this repo last synced, not a path. The hub is PUBLIC: strip
     anything that identifies a repo, client, schema, or incident. Propose
     the hub edit alongside the local ones; after approval, commit it in the
     hub so other repos pick it up on their next `scripts/review-update.sh`.
   - Never edit `.review/learnings-shared.md` in this repo directly — the
     next sync overwrites it.

5. Show me the proposed diffs and wait for my approval before writing. Never
   suppress a class that produced a genuine FIX at any point.

6. If `learnings.md` is over ~60 lines after the edit, consolidate overlapping
   entries — a bloated learnings file dilutes every lens prompt.
