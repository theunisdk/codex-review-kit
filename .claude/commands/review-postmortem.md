---
description: Record what CodeRabbit caught that our local Codex pass missed
argument-hint: "[PR number or URL — default: this branch's PR] [--record-only] [--replay <dir>]"
allowed-tools: Bash, Read, Grep, Glob, Edit, Write
---

Close the loop between the local review and the CodeRabbit gate. Run this after
CodeRabbit has reviewed the PR: $ARGUMENTS

The PR is `$ARGUMENTS` without `--record-only` and `--replay <dir>`; with no
PR given, use this branch's PR. `--record-only` is for unattended callers: stop
after step 5 and list the proposed edits in the report, without waiting for
approval or filing anything. `--replay <dir>` is only for
`scripts/review-replay.sh`, and implies `--record-only`: follow **Replay mode**
at the end, which posts nothing.

Begin your report with one status line, so a caller can tell the outcomes apart:

- `review-postmortem: scored — PR #<n>: caught N / missed M / rejected-wrongly R / noise X / unscored U (compare_failed F)`.
  `F` counts the unscored findings whose compare in step 2 failed or was
  denied, so a run that could not compare does not read as one that found
  the code changed. Print it even when it is 0.
- `review-postmortem: no-local-verdict — PR #<n>: <why>`. Recorded, never scored:
  this is not `missed 0`.
- `review-postmortem: skipped — <reason>` when there is nothing to record yet:
  no `.review/` here, no PR for this branch, CodeRabbit has not reviewed it,
  or CodeRabbit skipped it.
- `review-postmortem: failed — <step>: <error>` when a command failed. A failed
  read is never reported as an empty result. Nothing is recorded.

A command that was denied permission did not run. Its result is unknown, not
empty, and is handled as a failure of that command.

After `scored` or `no-local-verdict`, the second line says whether the record
was saved:
`review-postmortem: record — comment <posted|updated|NOT posted: <error>>; local copy <written|NOT written: <error>>`.
Both lines are final at the end of step 5. Step 6 never changes them; it
reports its own update of the record on a third line,
`review-postmortem: lessons — comment <updated|NOT updated: <error>>; local copy <written|NOT written: <error>>`.

1. **Pull CodeRabbit's review.** If `.review/` is missing, report
   `skipped — no review kit in this repo`. Resolve the PR with
   `gh pr view <PR> --json number,url,author,baseRefName,headRefOid,commits`.
   If `gh` says the branch has no pull request, report
   `skipped — no PR for this branch`. Then fetch, each with `--paginate`:
   `gh api repos/{owner}/{repo}/pulls/<n>/reviews`, `…/pulls/<n>/comments`
   (inline threads, with `in_reply_to_id` and `original_commit_id`),
   `…/issues/<n>/comments`, and `gh api repos/{owner}/{repo}/commits/<sha>/statuses`
   for every commit of the PR. If any of these calls fails, stop with
   `failed`. Do not guess, and do not score from pasted comments: they carry
   no commit.

   CodeRabbit posts as `coderabbitai[bot]`. A review object with an empty body is
   its reply to a thread, not a review. A finding is an inline comment, or a
   nitpick or "Outside diff range" item inside a review body. Each finding
   belongs to the commit CodeRabbit reviewed when it raised it: the comment's
   `original_commit_id`, or the review's `commit_id`. A finding raised again on
   a later head counts once, at its first commit.

   A CodeRabbit status reading `Review completed` means it reviewed that
   commit; a clean pass may leave only that status. `Review rate limited` and
   `pending` are not reviews. With no non-empty review and no completed
   status, report `skipped — CodeRabbit has not reviewed PR #<n>`. If its
   status reads `Review skipped`, or its summary comment says the review was
   skipped or paused, report `skipped — CodeRabbit skipped PR #<n>`.

2. **Find the local verdict for the commit CodeRabbit first reviewed.** The
   comparison commit is the **first head CodeRabbit reviewed**: of its
   non-empty reviews and its `Review completed` statuses, the one with the
   earliest `submitted_at` or `created_at`. Later heads hold fixes made in
   answer to CodeRabbit, and a verdict written after its first review may have
   read it. `.review/verdict.md` holds whatever was reviewed last, so never use
   it without matching its header.

   A verdict's header names the commit it judged:
   `# Review verdict — <branch> — <short-sha> — <date>`. SHAs match when one
   is a prefix of the other. An `--uncommitted` run writes
   `<short-sha>+uncommitted` there instead: it judged working-tree changes on
   top of that commit, not the commit. First run `git fetch origin "pull/<n>/head"`, so
   the PR's commits are in this clone. If the compared commit is still
   missing, because it was force-pushed away, run `git fetch origin <first>`.
   If `git rev-parse --is-shallow-repository` prints `true`, run
   `git fetch --unshallow`: a missing ancestor would read as `other`. If a
   fetch fails, stop with `failed — fetch`. Write the PR's full commit
   SHAs to a file: `gh pr view <n> --json commits -q '.commits[].oid' > <file>`.
   Then list every candidate with its relation to the comparison commit, from
   the live `.review/verdict.md` of each worktree and the clone's review
   history. The live file may not be archived yet, so read both:

   ```bash
   first=<full SHA of the first head CodeRabbit reviewed>
   pr_commits=<file listing the PR's commit SHAs, one per line>
   first="$(git rev-parse --verify -q "$first^{commit}")" || { echo "failed: the compared commit is not in this clone"; exit 1; }
   [ -r "$pr_commits" ] && [ -s "$pr_commits" ] || { echo "failed: no PR commit list at $pr_commits"; exit 1; }
   common="$(git rev-parse --git-common-dir)" && common="$(cd "$common" && pwd -P)" || { echo "failed: git common dir"; exit 1; }
   hist="$common/review-history" archived=""
   if [ -e "$hist" ]; then
     [ -r "$hist" ] && [ -x "$hist" ] || { echo "failed: $hist is not readable"; exit 1; }
     archived="$(find "$hist" -maxdepth 1 -name 'code-*.md')" || { echo "failed: cannot list $hist"; exit 1; }
   fi
   wts="$(git worktree list --porcelain)" || { echo "failed: git worktree list"; exit 1; }
   { printf '%s\n' "$wts" | sed -n 's|^worktree \(.*\)|\1/.review/verdict.md|p'
     [ -z "$archived" ] || printf '%s\n' "$archived"
   } | while IFS= read -r f; do
     if [ ! -e "$f" ]; then
       if [ -d "${f%/verdict.md}" ] && [ ! -x "${f%/verdict.md}" ]; then echo "failed: ${f%/verdict.md} is not readable"; exit 1; fi
       case "$f" in */.review/verdict.md) [ -d "${f%/.review/verdict.md}" ] || echo "unread ${f%/.review/verdict.md}: worktree directory is missing" ;; esac
       continue
     fi
     heads="$(awk -F ' — ' -v title=1 -v rev=3 '
       function flush() { if (sha != "" && !spec) print sha, line, unc; sha = ""; spec = 0 }
       /^# (Review|Spec) verdict — / { flush() }
       $title == "# Review verdict" && NF == 4 && $rev ~ /^[0-9a-f]+([+]uncommitted)?$/ {
         s = $rev; u = sub(/[+]uncommitted$/, "", s)
         if (length(s) >= 4 && length(s) <= 64) { sha = s; line = FNR; unc = u }
       }
       /^Lenses:/ && /spec-/ { spec = 1 }
       END { flush() }' "$f")" || { echo "failed: cannot read $f"; exit 1; }
     [ -n "$heads" ] || continue
     printf '%s\n' "$heads" | while read -r sha line unc; do
       case "$first" in
         "$sha"*) rel=same ;;
         *) full="$(git rev-parse --verify -q "$sha^{commit}")"
            if [ -z "$full" ] || ! grep -qFx "$full" "$pr_commits"; then rel=other
            else
              git merge-base --is-ancestor "$full" "$first"; rc=$?
              case "$rc" in 0) rel=ancestor ;; 1) rel=other ;; *) echo "failed: git merge-base --is-ancestor $sha $first"; exit 1 ;; esac
            fi ;;
       esac
       [ "$unc" = 1 ] && [ "$rel" != other ] && rel=uncommitted
       printf '%s %s %s %s\n' "$rel" "$sha" "$line" "$f"
     done || exit 1
   done
   ```

   Each line is `<relation> <sha> <line> <file>`: the verdict starts at that
   line of that file, which may hold several. A verdict whose `Lenses:` line
   names a `spec-*` lens is a spec review under an old header, so it is not
   listed. A line starting `failed:`, or a non-zero exit, means a store could
   not be read: report `failed`, not `no-local-verdict`. A line starting
   `unread` names a worktree whose verdict could not be checked: name it in
   the report and in the record's `reason`. The legacy `.review/archive/` of
   kits before v1.2.2 is not searched; if a worktree has one, say so in
   `reason`.

   Pick the verdict by this rule, and name the files you used:
   - **`same`** — the verdict judged the comparison commit. Use every `same`
     verdict, since one commit may have been adjudicated twice. A finding is
     caught if any of them has it.
   - **No `same`, but an `ancestor`** — the verdict judged an earlier commit
     on this PR's branch, and the commits after it reached CodeRabbit
     unreviewed. Use the nearest one: the one with the fewest PR commits
     after it, `git rev-list <sha>..<first> | grep -cFx -f <PR commit file>`.
     That count is `uncovered_commits`; grep exits 1 when it is 0. If
     `<first>` is not in the PR commit file because a force-push dropped it,
     set `uncovered_commits` to `null` and say why.
   - **`uncommitted`** — an `--uncommitted` run's verdict on the comparison
     commit or an ancestor. It may hold fixes written after reading
     CodeRabbit, so it is never a pre-PR catch: never use it, but never drop
     it silently either. Name each one in the report and in the record's
     `reason`, as `skipped uncommitted-run verdict <file>`. With no `same` or
     `ancestor` beside it, the PR is `no-local-verdict` for that reason.
   - **Neither** — record `no-local-verdict` and do not score. `other` means a
     commit that is not one of this PR's commits before the compared commit:
     a review run after CodeRabbit's, another branch's, one that reached the
     PR through its base, or one a rebase dropped from the PR. A missing review-history directory is no
     history in this clone, not a failure.

   Score a finding only if the code it cites was already there at the
   verdict's commit. Decide that per finding, never per file: on a PR with
   several review rounds, nearly every file changed after the first. One rule
   covers an ancestor verdict and findings raised on later heads. Record the
   basis in the finding's `presence`:
   - **The finding's commit is the verdict's commit**: `same_commit`.
   - **Otherwise, blame the cited lines** over the commits since the verdict:
     `git blame -s -l --ignore-revs-file= -L <start>,<end> <verdict-sha>..<finding-commit> -- <file>`.
     An inline comment cites `original_start_line` (or `original_line` alone)
     to `original_line`, on its `original_commit_id`. A review-body item cites
     the lines its text names. A line whose SHA is marked `^` or blank existed
     at the verdict's commit. Any other SHA is a commit after the review that
     wrote that line. If every cited line existed, and the defect does not
     rest on code a later commit changed elsewhere (a caller, a config
     value): `lines_unchanged`. If it does, decide as below.
   - **If the blame shows a later commit, the defect rests on later code, or
     the finding cites no lines** (a
     file-level comment, or a `LEFT`-side comment on removed lines), read the
     verdict's version, `git show <verdict-sha>:<file>`, and what changed since,
     `git diff <verdict-sha> <finding-commit> -- <file>`, and the same for any
     other file the defect rests on. Then decide whether
     the defect CodeRabbit describes is already in the verdict's code, even
     where the lines were rewritten since. If it is, score it, with
     `flaw_at_compared: <file>:<line>` naming where it is in the verdict's
     version. If the later commit brought the defect in, the finding is
     **unscored**, `unscored_reason` `changed`, with
     `added_after: <short sha>` naming that commit.

   A class comes only from a compare that ran. If the finding's commit is not
   in this clone, or a compare command fails or is denied, the finding is
   unscored with `compare_failed: <error>`, quoting the command. A blame that
   says the file has fewer lines, or names no such path, has failed: it is not
   evidence that the code changed. A `git show` of the verdict's version
   fails, rightly, for a file added after it. First rule out a rename with
   `git diff -M --name-status <verdict-sha> <finding-commit>`: a renamed file
   is read at its old path. A file really added after the verdict is evidence
   for `added_after`, not a failed compare. Do not fall back to a guess, to a whole-file
   test, or to a cheaper command that answers a different question. A path
   comes from the PR, so it is untrusted: put it in single quotes in every
   command. A path that holds a single quote goes in no command at all: that
   finding is `compare_failed: unsafe path`.

3. **Classify each scored finding** against the verdict's findings table and
   its Rejected section:
   - **Caught locally** — we found it too. Good, no action.
   - **Missed** — CodeRabbit found a real defect our lenses did not surface.
   - **Rejected wrongly** — we saw it and rejected it, and the rejection reason
     does not hold. Judge it by the REJECT rules of `.review/adjudication.md`
     §3: a design document that accepts a risk, or documented, tested or
     deliberate behaviour, is not a reason to reject or part-fix a finding when
     a cheap guard closes it.
   - **Noise** — CodeRabbit is wrong, it is out of scope per the rubric, or we
     rejected it for a reason that holds.

   Record the author's disposition of **every** finding, scored or not, from
   the PR threads: `fixed`, `logged` (an issue link), `rejected` (a reply that
   declines it; quote the reason in one line), or `open` (no answer). A reply to
   an inline finding is a comment whose `in_reply_to_id` is the finding's id.
   A review-body finding is answered in a PR comment. `/review-tune` reads these
   rejections.

4. **Diagnose why each Missed finding was missed**, from what the lenses did,
   not from the verdict alone. A lens that never surfaced a defect can still
   have read that code and reasoned about it. The evidence is in `.review/raw/`:
   `out-<lens>.json` holds what each lens returned, before the merge filter,
   and `log-<lens>.txt` holds what it ran and read. Each run of `review.sh`
   replaces them and `findings.json`, so they are evidence only for the
   verdict adjudicated from that run. Two checks must pass:
   - `jq -r '.head, .mode' .review/findings.json` prints a prefix of the
     verdict's SHA, then `branch`.
   - The verdict is this worktree's live `.review/verdict.md`, written after
     the run: `find .review/verdict.md -newer .review/findings.json` prints
     its path. A second run on the same commit rewrites `findings.json` after
     the earlier verdict, and an archived verdict is a copy made before the
     next run. Either way, the logs belong to another run.

   For each miss, search every lens's output and log for the finding's file
   with the Grep tool, not a shell command, then read the matching parts of
   the log.

   Set `cause_evidence` to one line naming the file and what it shows, such as
   ``log-correctness.txt: read src/a.ts:40-90 and checked the retry order; out-correctness.json: nothing on it``.
   If the files are missing, or `findings.json` is not the verdict's run (an
   older kit leaves `head` out), the cause
   is `unverified`, and `cause_evidence` says which file was missing or
   stale. Never pick a cause without the evidence. Give each miss one cause:
   - **Wrong lens** (`wrong_lens`): no lens whose scope covers this defect
     class read the code. The lenses that did read it were hunting other
     classes. → Propose a specific "hunt specifically
     for" addition. A hazard specific to this repo goes in
     `.review/prompts.local/<lens>.md` (repo-owned overlay). One that would
     hold in any repo, or any repo on this stack, is a hub lesson for
     `.review/prompts/<lens>.md` (step 6). Never edit `.review/prompts/` in
     this repo: the next sync overwrites it.
   - **Insufficient tracing** (`tracing`): the right lens read the cited code,
     or worked on the question the finding raises, and reported nothing on
     it. → Propose a `## WATCH`
     line, dated, naming the defect class concretely. It goes in
     `.review/learnings.md` if repo-specific, or is a hub lesson for
     `learnings-shared.md` if it generalises.
   - **Threshold** (`threshold`): a lens returned it in `out-<lens>.json`
     with a confidence below the run's minimum (`min confidence` in
     `.review/findings.md`), so the merge dropped it. → Tell me the
     threshold is too aggressive.
   - **Structural limit** (`structural`: needs a repo-wide index, cross-PR
     history, or a tool we do not run) → say so plainly. That is CodeRabbit
     earning its cost, and the right answer is to keep paying for it, not to
     bolt on more prompt.
   - **Unverified** (`unverified`): there is no lens evidence for this
     verdict. Propose nothing for it. `missed_by_cause` counts only the four
     causes above, so its total falls short of `missed` by the unverified
     misses.

5. **Record the scorecard**, before proposing edits, so the record exists even
   if no edit is approved. Write one body and use it twice:

   ````markdown
   <!-- review-postmortem:v1 -->
   ## Review postmortem — PR #<n>

   **scored** · compared commit `<first, short>` · local verdict `<sha>` (same | ancestor, K commits uncovered)
   caught N / missed M (wrong lens a / tracing b / threshold c / structural d / unverified e) / rejected-wrongly R / noise X / unscored U (compare_failed F)

   | CodeRabbit finding | File | Class | Cause | Local ID | Author |
   |--------------------|------|-------|-------|----------|--------|

   <details><summary>Machine-readable record</summary>

   ```json
   {"schema": "review-postmortem/v1", "pr": 0, "date": "<UTC ISO 8601 timestamp>",
    "status": "scored | no-local-verdict", "reason": null,
    "compared_commit": "<full sha>",
    "verdict": {"shas": [], "relation": "same | ancestor", "uncovered_commits": 0, "files": []},
    "counts": {"caught": 0, "missed": 0, "rejected_wrongly": 0, "noise": 0, "unscored": 0},
    "missed_by_cause": {"wrong_lens": 0, "tracing": 0, "threshold": 0, "structural": 0},
    "findings": [{"url": "", "commit": "", "file": "", "summary": "",
                  "class": "caught | missed | rejected-wrongly | noise | unscored",
                  "presence": "same_commit | lines_unchanged | flaw_at_compared: <file>:<line> | added_after: <sha> | null",
                  "cause": "wrong_lens | tracing | threshold | structural | unverified | null",
                  "cause_evidence": null, "local_id": null,
                  "unscored_reason": "changed | compare_failed: <error> | no_local_verdict | null",
                  "author": "fixed | logged | rejected | open", "author_reason": null}],
    "proposals": [{"route": "repo | hub", "file": "", "lines": "", "cause": ""}],
    "lessons": []}
   ```
   </details>
   ````

   For `no-local-verdict`, the second line is
   ``**no-local-verdict** · compared commit `<first, short>` · <reason>``, with no
   counts line. Set `reason`, and set `verdict`, `counts` and
   `missed_by_cause` to `null`, never zeros. Every finding is `unscored`, with
   `unscored_reason` `no_local_verdict`, and its author disposition is still
   recorded.

   - **PR comment.** Find this repo's existing record: get your login with
     `gh api user -q .login`, then list the marker comments with
     `gh api --paginate repos/{owner}/{repo}/issues/<n>/comments --jq '.[] | select(.body | contains("<!-- review-postmortem:v1 -->")) | "\(.created_at) \(.id) \(.user.login)"'`.
     If one of yours is listed, update it:
     `gh api -X PATCH repos/{owner}/{repo}/issues/comments/<id> -F body=@<file>`.
     If several are, update the one with the latest `created_at`. With none,
     create one: `gh pr comment <n> --body-file <file>`. If either lookup
     fails, do not create a comment, because it could duplicate one: the
     comment is `NOT posted`, with the error.
   - **Local copy** for `/review-tune`: write the same body to
     `<git common dir>/review-history/postmortem-pr<n>.md` through a temporary
     file and `mv`, so a re-run replaces it. Create the directory if needed. If
     it cannot be written, the local copy is `NOT written`, with the error.

   Report both outcomes on the record line. One failing never cancels the
   other. Every proposed edit from step 4 is in `proposals`, so a
   `--record-only` run keeps them too. With `--record-only`, list them and
   stop.

6. **Propose the edits and wait for my approval.** Every proposal is routed: a
   repo-specific lesson is an edit to this repo, as above. A generic or
   stack-level lesson is a **hub lesson**: an issue on the kit hub, never a
   commit in a local hub clone. The hub is PUBLIC, so strip anything that
   identifies a repo, client, schema or incident. After approval, for each
   hub lesson:
   - Check the hub's current file so you do not propose a line it already has:
     `gh api -H 'Accept: application/vnd.github.raw' repos/theunisdk/codex-review-kit/contents/<path>`.
     Search for an existing issue with
     `gh issue list -R theunisdk/codex-review-kit --label lesson --state open --search "<words>"`;
     if one proposes the same line, comment on it instead. If either check
     fails, do not file: a duplicate is worse than a delay. Save the body and
     report `hub lesson NOT filed` with the error.
   - Check the label with
     `gh label list -R theunisdk/codex-review-kit --search lesson --json name -q '.[].name'`.
     If the list has no `lesson`, run
     `gh label create lesson -R theunisdk/codex-review-kit --description "Review lesson routed from a spoke"`.
     If that fails, file the issue without a label and say so. If the list
     call fails, that is a failed label lookup, not a missing label: say so,
     and file without a label.
   - File it: `gh issue create -R theunisdk/codex-review-kit --label lesson --title "lesson(<lens or learnings-shared>): <defect class>" --body-file <file>`.
     Without the label, run the same command with no `--label lesson`. The body names the hub file and the proposed lines, the defect class, and
     the cause. If filing fails, save the body to a file, print its path and
     the command, and report `hub lesson NOT filed`.

   Add the filed issue URLs to `lessons` and update the PR comment and local
   copy the same way, then print the `lessons` line. The hub's maintainer
   folds lessons into a release, and a spoke gets them on its first
   `scripts/review-update.sh` after that release.

Track the scorecard over time. If `missed` trends toward zero on ordinary PRs,
the local pass is doing its job and CodeRabbit is insurance. A plateau in
`missed` is a hypothesis until the misses are classified by cause. Misses
caused by the wrong lens, insufficient tracing or the threshold mean the fixes
are not landing, and they can be fixed here. Only misses classed as
**structural** support the conclusion that part of CodeRabbit's value cannot be
reproduced this way.

## Replay mode

`scripts/review-replay.sh`, in the hub, re-runs today's kit on the commit
CodeRabbit first reviewed on an old PR, in a temporary clone, and calls
this command with `<n> --replay <dir>`. A replay scores today's kit, not the
review that ran on the PR. It must not reach the PR, because a comment
notifies everyone on it. The steps above apply, with these changes:

- **One plain command per Bash call.** The replay allows only read-only
  commands, matched by their first words, such as `git show`, `git diff`,
  `git blame`, `git log`, `git cat-file`, `jq`, `grep` and `wc`, run from the
  clone's root. It denies everything else: `git -C`, `cd`, `&&`, `;`,
  pipes, loops, redirection, `$(…)`, and interpreters such as `python3`.
  Read a file with the Read tool, and JSON with `jq <filter> <file>`, one file
  per call. A denied command follows the rule above: a denied step-2 compare
  is `compare_failed: denied: <command>`, and a value you could not read is
  `null` in the record, never an estimate.
- **Call no `gh`.** `<dir>` holds what step 1 fetches: `pr.json` (the
  `gh pr view` fields, plus `headRefName` and `state`), `pull.json`
  (`…/pulls/<n>`), `reviews.json`, `comments.json` and
  `issue-comments.json` (every page, as one array), `statuses.json`
  (`[{"sha": …, "statuses": […]}]` for every PR commit) and
  `pr-commits.txt`. Check each JSON file with `jq -e type <file>`. If a file
  is missing or does not parse, report `failed — read: <file>`.
- **Fetch nothing.** The caller fetched the PR's commits. A finding whose
  commit is still missing is unscored with `compare_failed`.
- **The verdict is this clone's `.review/verdict.md`**, relation `same`.
  Do not list worktrees or the review history. They hold verdicts from
  the kit that ran then, which a replay does not measure. If its header does
  not name the comparison commit, report `failed — verdict: <why>`.
- **The lens evidence for step 4 is this clone's `.review/raw/`**, from
  the run that the verdict adjudicated. The clone held only that run, so
  the `head` and `mode` check alone ties them; skip the `find`, which the
  replay does not allow. A replay that keeps them copies them
  into the record, at `<record>/raw/log-<lens>.txt` and
  `<record>/raw/out-<lens>.json`; re-scoring a record later reads them there.
- **Save nothing.** In step 5, print the record instead: the status line,
  then `review-postmortem: record — replay: comment not posted; local copy written by the caller`,
  then the body from its `<!-- review-postmortem:v1 -->` line to the end. The
  caller adds the replay's facts to the JSON as `replay` (kit ref, base,
  where each repo-owned file came from, cost), and writes the record to
  `<git common dir>/review-replay/pr<n>-<kit>/postmortem.md`. Nothing else is
  written: no PR comment, and no `review-history/postmortem-pr<n>.md`, which
  `/review-tune` would read as a live postmortem.
- **No step 6.** The proposals stay in `proposals`. Nothing is filed.
