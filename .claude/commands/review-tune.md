---
description: Fold recurring review rejections into .review/learnings.md to cut noise
allowed-tools: Bash, Read, Grep, Glob, Edit, Write
---

Reduce false-positive noise in the Codex review by learning from what we rejected.

1. Gather rejection history. You need the verdict BODIES — commit subjects say
   nothing about what was rejected. Verdicts are gitignored, so git history has
   none. `scripts/review.sh` and the pre-push hook archive them into the
   clone's review history, shared by every worktree:
   `ls "$(git rev-parse --git-common-dir)/review-history"`. Code verdicts are
   `code-<date>-<sha>.md`, spec verdicts `spec-<date>-<sha>.md`; one file per
   judged commit. Read every one, plus `.review/verdict.md` and
   `.review/spec-verdict.md` if present and not yet archived (the archive file
   with the same mode, date and SHA is the same verdict — count it once). If
   the directory is missing or empty, say so: that is no history, not a clean
   one. Read each one's Rejected section. Keep spec rejections in their own
   classes: `learnings.md` reaches the code lenses too, so a suppression drawn
   from spec rejections must say it applies to spec review only.

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
