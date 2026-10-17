---
description: Record what CodeRabbit caught that our local Codex pass missed
argument-hint: "[PR number or URL — default: this branch's PR]"
allowed-tools: Bash, Read, Grep, Glob, Edit, Write
---

Close the loop between the local review and the CodeRabbit gate. Run this after
CodeRabbit has reviewed the PR: $ARGUMENTS

Begin your report with one status line, so a caller can tell the outcomes apart:

- `review-postmortem: scored — PR #<n>: caught N / missed M / rejected-wrongly R / noise X / unscored U`
- `review-postmortem: no-local-verdict — PR #<n>: <why>`. Recorded, never scored:
  this is not `missed 0`.
- `review-postmortem: skipped — <reason>` when there is nothing to record yet:
  no `.review/` here, no PR for this branch, CodeRabbit has not reviewed it,
  or CodeRabbit skipped it.
- `review-postmortem: failed — <step>: <error>` when a command failed. A failed
  read is never reported as an empty result.

1. **Pull CodeRabbit's review.** If `.review/` is missing, report
   `skipped — no review kit in this repo`. Resolve the PR with
   `gh pr view $ARGUMENTS --json number,url,author,headRefOid,commits`. With no
   argument this uses the current branch's PR; if `gh` says the branch has no
   pull request, report `skipped — no PR for this branch`. Then fetch, each
   with `--paginate`:
   `gh api repos/{owner}/{repo}/pulls/<n>/reviews`, `…/pulls/<n>/comments` (inline
   threads, with `in_reply_to_id` and `original_commit_id`) and
   `…/issues/<n>/comments`. If any call fails, stop with `failed`. Do not guess,
   and do not score from pasted comments: they carry no commit.

   CodeRabbit posts as `coderabbitai[bot]`. A review object with an empty body is
   its reply to a thread, not a review. A finding is an inline comment, or a
   nitpick or "Outside diff range" item inside a review body. Each finding
   belongs to the commit CodeRabbit reviewed when it raised it: the comment's
   `original_commit_id`, or the review's `commit_id`. A finding raised again on
   a later head counts once, at its first commit.

   If CodeRabbit has no non-empty review and no findings, check the PR's commits
   for a CodeRabbit commit status: `gh api repos/{owner}/{repo}/commits/<sha>/statuses`.
   `Review completed` means it reviewed that commit and found nothing.
   `Review rate limited` and `pending` are not reviews. With no review anywhere,
   report `skipped — CodeRabbit has not reviewed PR #<n>`. If its summary comment
   says the review was skipped or paused, report `skipped — CodeRabbit skipped PR #<n>`.

2. **Find the local verdict for the commit CodeRabbit first reviewed.** The
   comparison commit is the **first head CodeRabbit reviewed**: the earliest
   of its non-empty reviews' `commit_id` and its `Review completed` statuses.
   Later heads hold fixes made in answer to CodeRabbit, and a verdict written
   after its first review may have read it. `.review/verdict.md` holds
   whatever was reviewed last, so never use it without checking its header.

   A verdict's header names the commit it judged:
   `# Review verdict — <branch> — <short-sha> — <date>`. SHAs match when one
   is a prefix of the other. First run `git fetch origin "pull/<n>/head"` so
   the PR's commits are in this clone. If the fetch fails, say so: commits it
   would have brought show up as `unknown` below. Then list every candidate with its
   relation to the comparison commit, from the live `.review/verdict.md` of
   each worktree and the clone's review history. The live file may not be
   archived yet, so read both:

   ```bash
   first=<full SHA of the first head CodeRabbit reviewed>
   common="$(git rev-parse --path-format=absolute --git-common-dir)" || { echo "failed: git common dir"; exit 1; }
   hist="$common/review-history"
   [ ! -e "$hist" ] || [ -r "$hist" ] || { echo "failed: $hist is not readable"; exit 1; }
   wts="$(git worktree list --porcelain)" || { echo "failed: git worktree list"; exit 1; }
   { printf '%s\n' "$wts" | sed -n 's|^worktree \(.*\)|\1/.review/verdict.md|p'
     [ -d "$hist" ] && find "$hist" -maxdepth 1 -name 'code-*.md'
   } | while IFS= read -r f; do
     [ -f "$f" ] || continue
     awk -F ' — ' '$1 == "# Review verdict" && NF == 4 && $3 ~ /^[0-9a-f]+$/ && length($3) >= 4 && length($3) <= 64 { print $3 }' "$f" |
     while IFS= read -r sha; do
       case "$first" in
         "$sha"*) rel=same ;;
         *) git merge-base --is-ancestor "$sha" "$first" 2>/dev/null; rc=$?
            case "$rc" in 0) rel=ancestor ;; 1) rel=other ;; *) rel=unknown ;; esac ;;
       esac
       printf '%s %s %s\n' "$rel" "$sha" "$f"
     done
   done
   ```

   Pick the verdict by this rule, and name the files you used:
   - **`same`** — the verdict judged the comparison commit. Use every `same`
     verdict, since one commit may have been adjudicated twice. A finding is
     caught if any of them has it.
   - **No `same`, but an `ancestor`** — the verdict judged an earlier commit,
     and the commits after it reached CodeRabbit unreviewed. Use the nearest
     one: the smallest `git rev-list --count <sha>..<first>`. Say how many
     commits it does not cover.
   - **Neither** — record `no-local-verdict` and do not score. `other` means a
     later or unrelated commit, such as a review run after CodeRabbit's.
     `unknown` means a commit this clone cannot place; name each one. A
     missing review-history directory is no history in this clone, not a
     failure.

   Score a finding only if its file is unchanged between the verdict's commit
   and the finding's commit: `git diff --quiet <verdict-sha> <finding-commit> -- <file>`.
   Exit 1 means the code changed after the local review, so mark the finding
   **unscored**. Other exits mean git could not compare, so mark it unscored
   and say why. One rule covers an ancestor verdict and findings raised on
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
   - **Wrong lens** → propose a specific "hunt specifically for" addition.
     A hazard specific to this repo goes in `.review/prompts.local/<lens>.md`
     (repo-owned overlay). One that would hold in any repo, or any repo on this
     stack, is a hub lesson for `.review/prompts/<lens>.md` (step 6). Never edit
     `.review/prompts/` in this repo: the next sync overwrites it.
   - **Insufficient tracing** (right lens) → propose a `## WATCH` line, dated,
     naming the defect class concretely. It goes in `.review/learnings.md` if
     repo-specific, or is a hub lesson for `learnings-shared.md` if it generalises.
   - **Threshold** → check whether it was below `CONFIDENCE_MIN` in
     `.review/raw/out-*.json`; if so, tell me the threshold is too aggressive.
   - **Structural limit** (needs a repo-wide index, cross-PR history, or a tool
     we do not run) → say so plainly. That is CodeRabbit earning its cost, and
     the right answer is to keep paying for it, not to bolt on more prompt.

5. **Record the scorecard**, before proposing edits, so the record exists even
   if no edit is approved. Write one body and use it twice:

   ````markdown
   <!-- review-postmortem:v1 -->
   ## Review postmortem — PR #<n>

   **<status>** · compared commit `<first, short>` · local verdict `<sha>` (<same|ancestor, K commits uncovered>)
   caught N / missed M (wrong lens a / tracing b / threshold c / structural d) / rejected-wrongly R / noise X / unscored U

   | CodeRabbit finding | File | Class | Cause | Local ID | Author |
   |--------------------|------|-------|-------|----------|--------|

   <details><summary>Machine-readable record</summary>

   ```json
   {"schema": "review-postmortem/v1", "pr": 0, "date": "YYYY-MM-DD",
    "status": "scored | no-local-verdict", "reason": null,
    "compared_commit": "<full sha>", "verdict": {"sha": "<short>", "relation": "same | ancestor", "files": []},
    "counts": {"caught": 0, "missed": 0, "rejected_wrongly": 0, "noise": 0, "unscored": 0},
    "missed_by_cause": {"wrong_lens": 0, "tracing": 0, "threshold": 0, "structural": 0},
    "findings": [{"url": "", "commit": "", "file": "", "summary": "",
                  "class": "caught | missed | rejected-wrongly | noise | unscored",
                  "cause": null, "local_id": null,
                  "author": "fixed | logged | rejected | open", "author_reason": null}],
    "lessons": []}
   ```
   </details>
   ````

   For `no-local-verdict`, set `reason`, and set `verdict`, `counts` and
   `missed_by_cause` to `null`, never zeros. Every finding is `unscored`, and
   its author disposition is still recorded.

   - **PR comment.** Find this repo's existing record. List the marker comments
     authored by `gh api user -q .login` with
     `gh api --paginate repos/{owner}/{repo}/issues/<n>/comments --jq '.[] | select(.body | contains("<!-- review-postmortem:v1 -->")) | "\(.id) \(.user.login)"'`.
     If there is one, update it: `gh api -X PATCH repos/{owner}/{repo}/issues/comments/<id> -F body=@<file>`.
     If there are several, update the newest. With none, create one:
     `gh pr comment <n> --body-file <file>`. If listing fails, do not create a
     comment, because it could duplicate one. Report `scorecard NOT posted`
     with the error.
   - **Local copy** for `/review-tune`: write the same body to
     `<git common dir>/review-history/postmortem-pr<n>.md` through a temporary
     file and `mv`, so a re-run replaces it. Create the directory if needed. If
     it cannot be written, report `local copy NOT written` with the error.

   Report both outcomes. One failing never cancels the other.

6. **Propose the edits and wait for my approval.** Every proposal is routed: a
   repo-specific lesson is an edit to this repo, as above. A generic or
   stack-level lesson is a **hub lesson**: an issue on the kit hub, never a
   commit in a local hub clone. The hub is PUBLIC, so strip anything that
   identifies a repo, client, schema or incident. After approval:
   - Check the hub's current file so you do not propose a line it already has:
     `gh api -H 'Accept: application/vnd.github.raw' repos/theunisdk/codex-review-kit/contents/<path>`.
     Search for an existing issue with
     `gh issue list -R theunisdk/codex-review-kit --label lesson --state open --search "<words>"`;
     if one proposes the same line, comment on it instead.
   - Check the label with
     `gh label list -R theunisdk/codex-review-kit --search lesson --json name -q '.[].name'`.
     If the list has no `lesson`, run
     `gh label create lesson -R theunisdk/codex-review-kit --description "Review lesson routed from a spoke"`.
     If that fails, file the issue without a label and say so. If the list
     call fails, say so too: it is a failed check, not a missing label.
   - File it: `gh issue create -R theunisdk/codex-review-kit --label lesson --title "lesson(<lens or learnings-shared>): <defect class>" --body-file <file>`.
     The body names the hub file and the proposed lines, the defect class, and
     the cause. If filing fails, save the body to a file, print its path and
     the command, and report `hub lesson NOT filed`.

   Add the filed issue URLs to `lessons` and update the PR comment and local
   copy the same way. The hub's maintainer folds lessons into a release, and
   spokes get them on their next `scripts/review-update.sh`.

Track the scorecard over time. If `missed` trends toward zero on ordinary PRs,
the local pass is doing its job and CodeRabbit is insurance. A plateau in
`missed` is a hypothesis until the misses are classified by cause. Misses
caused by the wrong lens, insufficient tracing or the threshold mean the fixes
are not landing, and they can be fixed here. Only misses classed as
**structural** support the conclusion that part of CodeRabbit's value cannot be
reproduced this way.
