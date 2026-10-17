---
description: Record what CodeRabbit caught that our local Codex pass missed
argument-hint: "[PR number or URL — default: this branch's PR] [--record-only]"
allowed-tools: Bash, Read, Grep, Glob, Edit, Write
---

Close the loop between the local review and the CodeRabbit gate. Run this after
CodeRabbit has reviewed the PR: $ARGUMENTS

The PR is `$ARGUMENTS` without `--record-only`; with no PR given, use this
branch's PR. `--record-only` is for unattended callers: stop after step 5 and
list the proposed edits in the report, without waiting for approval or filing
anything.

Begin your report with one status line, so a caller can tell the outcomes apart:

- `review-postmortem: scored — PR #<n>: caught N / missed M / rejected-wrongly R / noise X / unscored U`
- `review-postmortem: no-local-verdict — PR #<n>: <why>`. Recorded, never scored:
  this is not `missed 0`.
- `review-postmortem: skipped — <reason>` when there is nothing to record yet:
  no `.review/` here, no PR for this branch, CodeRabbit has not reviewed it,
  or CodeRabbit skipped it.
- `review-postmortem: failed — <step>: <error>` when a command failed. A failed
  read is never reported as an empty result. Nothing is recorded.

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
   summary comment says the review was skipped or paused, report
   `skipped — CodeRabbit skipped PR #<n>`.

2. **Find the local verdict for the commit CodeRabbit first reviewed.** The
   comparison commit is the **first head CodeRabbit reviewed**: of its
   non-empty reviews and its `Review completed` statuses, the one with the
   earliest `submitted_at` or `created_at`. Later heads hold fixes made in
   answer to CodeRabbit, and a verdict written after its first review may have
   read it. `.review/verdict.md` holds whatever was reviewed last, so never use
   it without matching its header.

   A verdict's header names the commit it judged:
   `# Review verdict — <branch> — <short-sha> — <date>`. SHAs match when one
   is a prefix of the other. First run `git fetch origin "pull/<n>/head"`, so
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
     heads="$(awk -F ' — ' '
       function flush() { if (sha != "" && !spec) print sha, line; sha = ""; spec = 0 }
       /^# (Review|Spec) verdict — / { flush() }
       $1 == "# Review verdict" && NF == 4 && $3 ~ /^[0-9a-f]+$/ && length($3) >= 4 && length($3) <= 64 { sha = $3; line = FNR }
       /^Lenses:/ && /spec-/ { spec = 1 }
       END { flush() }' "$f")" || { echo "failed: cannot read $f"; exit 1; }
     [ -n "$heads" ] || continue
     printf '%s\n' "$heads" | while read -r sha line; do
       case "$first" in
         "$sha"*) rel=same ;;
         *) full="$(git rev-parse --verify -q "$sha^{commit}")"
            if [ -z "$full" ] || ! grep -qFx "$full" "$pr_commits"; then rel=other
            else
              git merge-base --is-ancestor "$full" "$first"; rc=$?
              case "$rc" in 0) rel=ancestor ;; 1) rel=other ;; *) echo "failed: git merge-base --is-ancestor $sha $first"; exit 1 ;; esac
            fi ;;
       esac
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
   - **Neither** — record `no-local-verdict` and do not score. `other` means a
     commit that is not one of this PR's commits before the compared commit:
     a review run after CodeRabbit's, another branch's, one that reached the
     PR through its base, or one a rebase dropped from the PR. A missing review-history directory is no
     history in this clone, not a failure.

   Score a finding only if its file is unchanged between the verdict's commit
   and the finding's commit: `git diff --quiet <verdict-sha> <finding-commit> -- <file>`.
   Exit 1 means the code changed after the local review, so mark the finding
   **unscored** with `unscored_reason` `changed`. Other exits mean git could
   not compare: mark it unscored with `compare_failed: <error>`. One rule covers an ancestor verdict and findings raised on
   later heads.

3. **Classify each scored finding** against the verdict's findings table and
   its Rejected section:
   - **Caught locally** — we found it too. Good, no action.
   - **Missed** — CodeRabbit found a real defect our lenses did not surface.
   - **Rejected wrongly** — we saw it and rejected it, and the rejection reason
     does not hold.
   - **Noise** — CodeRabbit is wrong, it is out of scope per the rubric, or we
     rejected it for a reason that holds.

   Record the author's disposition of **every** finding, scored or not, from
   the PR threads: `fixed`, `logged` (an issue link), `rejected` (a reply that
   declines it; quote the reason in one line), or `open` (no answer). A reply to
   an inline finding is a comment whose `in_reply_to_id` is the finding's id.
   A review-body finding is answered in a PR comment. `/review-tune` reads these
   rejections.

4. **Diagnose why each Missed finding was missed.** Give each one a cause:
   - **Wrong lens** (`wrong_lens`) → propose a specific "hunt specifically
     for" addition. A hazard specific to this repo goes in
     `.review/prompts.local/<lens>.md` (repo-owned overlay). One that would
     hold in any repo, or any repo on this stack, is a hub lesson for
     `.review/prompts/<lens>.md` (step 6). Never edit `.review/prompts/` in
     this repo: the next sync overwrites it.
   - **Insufficient tracing** (`tracing`, right lens) → propose a `## WATCH`
     line, dated, naming the defect class concretely. It goes in
     `.review/learnings.md` if repo-specific, or is a hub lesson for
     `learnings-shared.md` if it generalises.
   - **Threshold** (`threshold`) → check whether it was below
     `CONFIDENCE_MIN` in `.review/raw/out-*.json`; if so, tell me the
     threshold is too aggressive.
   - **Structural limit** (`structural`: needs a repo-wide index, cross-PR
     history, or a tool we do not run) → say so plainly. That is CodeRabbit
     earning its cost, and the right answer is to keep paying for it, not to
     bolt on more prompt.

5. **Record the scorecard**, before proposing edits, so the record exists even
   if no edit is approved. Write one body and use it twice:

   ````markdown
   <!-- review-postmortem:v1 -->
   ## Review postmortem — PR #<n>

   **scored** · compared commit `<first, short>` · local verdict `<sha>` (same | ancestor, K commits uncovered)
   caught N / missed M (wrong lens a / tracing b / threshold c / structural d) / rejected-wrongly R / noise X / unscored U

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
                  "cause": "wrong_lens | tracing | threshold | structural | null", "local_id": null,
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
     The body names the hub file and the proposed lines, the defect class, and
     the cause. If filing fails, save the body to a file, print its path and
     the command, and report `hub lesson NOT filed`.

   Add the filed issue URLs to `lessons` and update the PR comment and local
   copy the same way, then print the `lessons` line. The hub's maintainer folds lessons into a release, and
   spokes get them on their next `scripts/review-update.sh`.

Track the scorecard over time. If `missed` trends toward zero on ordinary PRs,
the local pass is doing its job and CodeRabbit is insurance. A plateau in
`missed` is a hypothesis until the misses are classified by cause. Misses
caused by the wrong lens, insufficient tracing or the threshold mean the fixes
are not landing, and they can be fixed here. Only misses classed as
**structural** support the conclusion that part of CodeRabbit's value cannot be
reproduced this way.
