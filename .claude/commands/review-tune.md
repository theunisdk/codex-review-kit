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
     it can be wrong for an old spec verdict (see below). The same directory
     holds `/review-postmortem` records, `postmortem-pr<n>.md`. They are not
     verdicts: read them in the next store.
   - The postmortem records. Each `postmortem-pr<n>.md` ends in a JSON block
     (`"schema": "review-postmortem/v1"`) listing every CodeRabbit finding on
     that PR, how it compared with the local verdict, and the author's
     disposition. Records written in another clone exist only as the PR
     comment marked `<!-- review-postmortem:v1 -->`. If `gh` works, also read
     that comment on the last 30 PRs (`gh pr list --state all --limit 30 --json number`).
     One PR's record counts once, and the later `date` wins. If `gh` fails,
     report the PR comments as unread.
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

   A postmortem with `"status": "no-local-verdict"` was not scored: its
   `counts` are `null`, not zero. Its author dispositions still count.

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
   A CodeRabbit finding whose `author` is `rejected` is a rejection too, with
   its `author_reason`. When a lens raised the same finding (`local_id` set)
   and we rejected it too, it confirms that local rejection but is not a
   second occurrence. Otherwise it is CodeRabbit noise: a recurring class of
   it is a candidate for an instruction in this repo's `.coderabbit.yaml`
   `reviews.path_instructions`, not for `learnings.md`.

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
     Propose it alongside the local edits. After approval, file it as an
     issue on the hub, never as a commit in a local hub clone. Follow step 6
     of `.claude/commands/review-postmortem.md`: check the hub's current file, reuse an open
     `lesson` issue, create the `lesson` label or say you filed without it,
     and report `hub lesson NOT filed` with the saved body if `gh` fails. The
     hub is PUBLIC: strip anything that identifies a repo, client, schema, or
     incident.
   - Never edit `.review/learnings-shared.md` in this repo directly — the
     next sync overwrites it.

5. Show me the proposed diffs and wait for my approval before writing. Never
   suppress a class that produced a genuine FIX at any point. That includes a
   postmortem finding classed `missed` or `rejected-wrongly`, or one the
   author `fixed` after CodeRabbit raised it.

6. If `learnings.md` is over ~60 lines after the edit, consolidate overlapping
   entries — a bloated learnings file dilutes every lens prompt.
