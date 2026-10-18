#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# review-replay.sh — replay today's review kit on PRs CodeRabbit already
# reviewed, and score it against CodeRabbit's findings.
#
# Hub only. For each PR it clones the history of the first head CodeRabbit
# reviewed, and nothing past it, into a temporary checkout outside the spoke.
# It overlays the hub kit at --kit-ref, runs review.sh over the PR's
# base..that commit, adjudicates the findings with a headless `claude -p`, and
# scores the verdict with `review-postmortem.md --replay`, which alone sees
# the spoke's later objects. The record stays in the spoke clone, under
# <git common dir>/review-replay/, each run's scorecard under runs/. Nothing is
# posted, filed or pushed. scripts/review-replay-sum.sh sums runs' scorecards.
#
#   scripts/review-replay.sh <spoke> <PR>...        # these PRs, in order
#   scripts/review-replay.sh <spoke> --recent 7     # the 7 most recent merged
#                                                   # PRs CodeRabbit reviewed
#     --limit N           take at most N PRs (default 5); the rest are skipped
#     --kit-ref REF       hub commit to overlay (default: the hub's main); a
#                         branch behind its remote is refused
#     --repo OWNER/NAME   GitHub repo (default: from the spoke's origin URL)
#     --model M           claude model for adjudication and the postmortem
#     --claude-budget USD per claude call (default 5)
#     --no-analyzers      passed to review.sh
#
# One line per PR — replayed / incomplete — <why> / skipped — <reason> /
# failed — <step>: <error> — then an aggregate scorecard. Exit: 0 no PR failed
# or is incomplete · 1 one did · 64 usage
# ---------------------------------------------------------------------------
set -uo pipefail

HUB="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=lib/common.sh
. "$HUB/scripts/lib/common.sh"

usage() { sed -n '2,29p' "$0" >&2; exit 64; }

SPOKE=""; PRS=""; RECENT=""; LIMIT=5; KIT_REF=main; REPO=""; MODEL=""; BUDGET=5; REVIEW_ARGS=""
SCAN=100; CLAUDE_TIMEOUT=1800; REVIEW_TIMEOUT=3600; NET_TIMEOUT=300
CR_LOGIN='coderabbitai[bot]'
while [ $# -gt 0 ]; do
  case "$1" in
    --recent)        RECENT="${2:-}"; shift ;;
    --limit)         LIMIT="${2:-}"; shift ;;
    --kit-ref)       KIT_REF="${2:-}"; shift ;;
    --repo)          REPO="${2:-}"; shift ;;
    --model)         MODEL="${2:-}"; shift ;;
    --claude-budget) BUDGET="${2:-}"; shift ;;
    --no-analyzers)  REVIEW_ARGS="--no-analyzers" ;;
    -h|--help)       sed -n '2,29p' "$0"; exit 0 ;;
    -*)              echo "error: unknown flag: $1" >&2; usage ;;
    *)               if [ -z "$SPOKE" ]; then SPOKE="$1"
                     else
                       case "$1" in ''|*[!0-9]*) echo "error: not a PR number: $1" >&2; exit 64 ;; esac
                       PRS="$PRS $1"
                     fi ;;
  esac
  shift
done
[ -n "$SPOKE" ] || usage
# count_arg <value> — the positive count it names, without leading zeros (07 is not a JSON
# number, and the aggregate embeds them); at most 9 digits, so shell arithmetic cannot wrap it
count_arg() {
  local v="${1#"${1%%[!0]*}"}"
  case "$v" in ''|*[!0-9]*|??????????*) return 1 ;; esac
  printf '%s' "$v"
}
LIMIT="$(count_arg "$LIMIT")" && { [ -z "$RECENT" ] || RECENT="$(count_arg "$RECENT")"; } \
  || { echo "error: --limit and --recent take a positive number of at most 9 digits" >&2; exit 64; }
case "$BUDGET" in ''|*[!0-9.]*) echo "error: --claude-budget takes a dollar amount" >&2; exit 64 ;; esac
if [ -n "$RECENT" ] && [ -n "$PRS" ]; then echo "error: name PRs or pass --recent, not both" >&2; exit 64; fi
if [ -z "$RECENT" ] && [ -z "$PRS" ]; then echo "error: name at least one PR, or pass --recent N" >&2; exit 64; fi

need_cmd git; need_cmd jq; need_cmd gh; need_cmd claude; need_cmd codex; need_cmd tar

# --- the spoke -------------------------------------------------------------
SPOKE="$(git -C "$SPOKE" rev-parse --show-toplevel 2>/dev/null)" || die "not a git repository: $SPOKE"
# the main worktree, even when given a linked one
SPOKE="$(git -C "$SPOKE" worktree list --porcelain | sed -n '1s/^worktree //p')"
[ -d "$SPOKE" ] || die "cannot find the main worktree of the spoke"
COMMON="$(git -C "$SPOKE" rev-parse --git-common-dir)" && COMMON="$(cd "$SPOKE" && cd "$COMMON" && pwd -P)" \
  || die "cannot resolve the spoke's git common dir"
[ "$(git -C "$SPOKE" rev-parse --is-shallow-repository)" = false ] \
  || die "$SPOKE is a shallow clone, so ancestry checks would be wrong — run 'git -C $SPOKE fetch --unshallow' first"
if [ -z "$REPO" ]; then
  url="$(git -C "$SPOKE" remote get-url origin 2>/dev/null)" || die "the spoke has no origin remote — pass --repo OWNER/NAME"
  REPO="$(printf '%s\n' "$url" | sed -nE 's#^(https://|ssh://)?(git@)?github\.com[:/]([^/]+/[^/]+)$#\3#p' | sed 's/\.git$//')"
  [ -n "$REPO" ] || die "origin ($url) is not a GitHub URL — pass --repo OWNER/NAME"
fi
STORE="$COMMON/review-replay"
mkdir -p "$STORE" 2>/dev/null && [ -w "$STORE" ] || die "cannot write the replay records to $STORE"

# --- the kit ---------------------------------------------------------------
KIT_SHA="$(git -C "$HUB" rev-parse --verify -q "$KIT_REF^{commit}")" || die "--kit-ref '$KIT_REF' is not a commit in $HUB"
KIT_SHORT="$(git -C "$HUB" rev-parse --short "$KIT_SHA")"
KIT_DESC="$(git -C "$HUB" describe --tags --always "$KIT_SHA" 2>/dev/null || echo "$KIT_SHORT")"

RUN_TMP="$(mktemp -d)" || die "no temp dir"
# apart from RUN_TMP, which holds CodeRabbit's findings the lenses must not read
CHECKOUTS="$(mktemp -d)" || { rm -rf "$RUN_TMP"; die "no temp dir"; }
# no spoke hook runs, here or in anything this starts
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
CUR_WT=""; CHILD=""
stop_child() {
  [ -n "$CHILD" ] || return 0
  local s=0
  kill -TERM -- "-$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null
  while [ "$s" -lt 10 ] && kill -0 "$CHILD" 2>/dev/null; do sleep 0.5; s=$((s + 1)); done
  kill -KILL -- "-$CHILD" 2>/dev/null
  wait "$CHILD" 2>/dev/null; CHILD=""
}
remove_checkout() { # prints why on failure
  [ -n "$CUR_WT" ] || return 0
  local wt="$CUR_WT"; CUR_WT=""
  rm -rf "$wt" > "$RUN_TMP/wt-remove.err" 2>&1 && [ ! -e "$wt" ] && return 0
  warn "could not remove the replay checkout $wt: $(head -n1 "$RUN_TMP/wt-remove.err") — run: rm -rf $wt"
  return 1
}
CUR_PR=""; SUMMARY=""; SUMMARY_LOST=""; RUN_DONE=""
say() { # say <line> — to stdout, and to the run's summary once it has one
  printf '%s\n' "$1"
  [ -z "$SUMMARY" ] || printf '%s\n' "$1" >> "$SUMMARY" || SUMMARY_LOST=1
}
# a trap can fire inside a call whose output is redirected; it reports on the script's own
exec 3>&1 4>&2
on_exit() {
  local rc=$?
  {
    stop_child; remove_checkout
    [ -z "$CUR_PR" ] || say "review-replay: failed — PR #$CUR_PR: interrupted: rc=$rc, nothing was recorded for it"
    [ -z "$SUMMARY" ] || [ -n "$RUN_DONE" ] \
      || printf 'review-replay: incomplete — the run exited %s before it finished, so it has no scorecard\n' "$rc" >> "$SUMMARY"
    rm -rf "$RUN_TMP"; rmdir "$CHECKOUTS" 2>/dev/null
  } >&3 2>&4
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

in_dir() { cd "$1" && shift && exec "$@"; }
err_of() { head -c 300 "$1" 2>/dev/null | tr '\n' ' '; }
codex_tokens() { # codex_tokens <raw dir> — the tokens every lens log reports, or "unknown" when one reports none
  local f n s=0
  for f in "$1"/log-*.txt; do
    [ -e "$f" ] || continue
    n="$(awk '/^tokens used$/ { if ((getline l) > 0 && l ~ /^[0-9,]+$/) { gsub(/,/, "", l); s += l; ok = 1 } } END { if (ok) print s }' "$f")"
    [ -n "$n" ] || { echo unknown; return; }
    s=$((s + n))
  done
  echo "$s"
}

# run_child <secs> <cmd...> — in its own process group with stdin closed, so an
# interrupt or a timeout stops everything it started (review.sh's lenses too).
# Returns 124 when it timed out.
run_child() {
  local secs="$1" rc w; shift
  rm -f "$RUN_TMP/timed-out"
  set -m; "$@" < /dev/null & CHILD=$!; set +m
  ( s=0; while [ "$s" -lt "$secs" ]; do sleep 2; s=$((s + 2)); kill -0 "$CHILD" 2>/dev/null || exit 0; done
    : > "$RUN_TMP/timed-out"; kill -TERM -- "-$CHILD" 2>/dev/null; sleep 5; kill -KILL -- "-$CHILD" 2>/dev/null ) &
  w=$!
  wait "$CHILD"; rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  CHILD=""
  [ ! -e "$RUN_TMP/timed-out" ] || case "$rc" in 137|143) rc=124 ;; esac
  return "$rc"
}
# exit_why <rc> <secs> — names a timeout
exit_why() {
  case "$1" in
    124) echo "timed out after ${2}s" ;;
    137|143) echo "was killed (rc $1; the timeout is ${2}s)" ;;
    *) echo "exited $1" ;;
  esac
}

# A clone behind its remote would replay an old kit and score it as today's. A branch or
# remote-tracking ref is checked against the remote itself; a tag or a SHA names one commit.
kit_is_current() {
  local full remote rref up r
  full="$(git -C "$HUB" rev-parse --symbolic-full-name "$KIT_REF" 2>/dev/null)"
  case "$full" in
    refs/heads/*)
      remote="$(git -C "$HUB" config "branch.${full#refs/heads/}.remote")"
      rref="$(git -C "$HUB" config "branch.${full#refs/heads/}.merge")"
      [ -n "$remote" ] && [ -n "$rref" ] \
        || { KIT_CHECK="unchecked: tracks no remote branch"; warn "--kit-ref $KIT_REF $KIT_CHECK, so the replay cannot check that it is current"; return 0; } ;;
    refs/remotes/*)
      # a remote name can hold a slash: the longest configured one that prefixes the ref owns it
      remote=""
      for r in $(git -C "$HUB" remote); do
        case "$full" in "refs/remotes/$r/"*) [ "${#r}" -le "${#remote}" ] || remote="$r" ;; esac
      done
      [ -n "$remote" ] \
        || die "--kit-ref $KIT_REF is a tracking ref of no remote the hub still has, so the replay cannot check that it is current — pass a tag or SHA"
      rref="refs/heads/${full#refs/remotes/"$remote"/}"
      [ "$rref" != refs/heads/HEAD ] || rref=HEAD ;;
    *) KIT_CHECK="names one commit"; return 0 ;;
  esac
  run_with_timeout "$NET_TIMEOUT" git -C "$HUB" ls-remote "$remote" "$rref" < /dev/null > "$RUN_TMP/kit-remote" 2> "$RUN_TMP/kit-remote.err" \
    || die "cannot read $rref from the hub's remote $remote, so the replay cannot check that --kit-ref $KIT_REF is current: $(err_of "$RUN_TMP/kit-remote.err") — pass a tag or SHA to replay without the check"
  up="$(awk -v r="$rref" '$2 == r { print $1; exit }' "$RUN_TMP/kit-remote")"
  [ -n "$up" ] || die "the hub's remote $remote has no $rref, which --kit-ref $KIT_REF tracks — pass a tag or SHA"
  git -C "$HUB" cat-file -e "$up^{commit}" 2>/dev/null \
    || run_with_timeout "$NET_TIMEOUT" git -C "$HUB" -c gc.auto=0 -c maintenance.auto=false fetch --quiet --no-write-fetch-head --no-tags --refmap= "$remote" "$rref" \
      < /dev/null > "$RUN_TMP/kit-fetch.err" 2>&1 \
    || die "cannot fetch $rref from the hub's remote $remote to check that --kit-ref $KIT_REF is current: $(err_of "$RUN_TMP/kit-fetch.err")"
  git -C "$HUB" merge-base --is-ancestor "$up" "$KIT_SHA" 2> "$RUN_TMP/kit-anc.err"
  case $? in
    0) KIT_CHECK="current with $rref on $remote"
       [ "$up" = "$KIT_SHA" ] || { KIT_CHECK="$(git -C "$HUB" rev-list --count "$up..$KIT_SHA") commit(s) ahead of $rref on $remote, unpushed"
         warn "--kit-ref $KIT_REF is $KIT_CHECK, so the replay scores an unpushed kit"; } ;;
    1) die "--kit-ref $KIT_REF ($KIT_SHORT) is behind $rref on $remote (${up:0:7}), so the replay would score an old kit — update the hub clone (git -C $HUB pull --ff-only), or pass a tag or SHA to replay an older kit on purpose" ;;
    *) die "cannot compare --kit-ref $KIT_REF with $rref on $remote: $(err_of "$RUN_TMP/kit-anc.err")" ;;
  esac
}
KIT_CHECK=""
kit_is_current

KIT_DIR="$RUN_TMP/kit"; mkdir -p "$KIT_DIR"
git -C "$HUB" archive "$KIT_SHA" | tar -x -C "$KIT_DIR" || die "cannot extract the kit at $KIT_SHORT"
grep -qF -- '--replay' "$KIT_DIR/.claude/commands/review-postmortem.md" 2>/dev/null \
  || die "the kit at $KIT_DESC has no review-postmortem --replay mode"
grep -qF -- '--local)' "$KIT_DIR/scripts/review-update.sh" 2>/dev/null \
  || die "the kit at $KIT_DESC has no review-update.sh --local"

if [ "${REVIEW_SKIP_AUTH_CHECK:-0}" != 1 ] && ! codex login status > /dev/null 2>&1; then
  die "not authenticated to Codex — run 'codex login'"
fi

is_ancestor() { # is_ancestor <a> <b> — sets ANC to yes or no; fails only on a git error
  git -C "$SPOKE" merge-base --is-ancestor "$1" "$2" 2> "$RUN_TMP/anc.err"
  case $? in 0) ANC=yes ;; 1) ANC=no ;; *) G_ERR="git merge-base --is-ancestor ${1:0:7} $2: $(err_of "$RUN_TMP/anc.err")"; return 1 ;; esac
}
have_commit() { git -C "$SPOKE" cat-file -e "$1^{commit}" 2>/dev/null; }
fetch_commits() { # fetch_commits <ref|sha>... — objects only: no ref and no FETCH_HEAD is written
  run_with_timeout "$NET_TIMEOUT" git -C "$SPOKE" -c gc.auto=0 -c maintenance.auto=false fetch --quiet --no-write-fetch-head --no-tags --refmap= origin "$@" \
    < /dev/null > "$RUN_TMP/fetch.err" 2>&1 || { G_ERR="git fetch origin $* $(exit_why $? "$NET_TIMEOUT"): $(err_of "$RUN_TMP/fetch.err")"; return 1; }
}

DEFAULT_SHA="$(git -C "$SPOKE" ls-remote origin HEAD 2>/dev/null | awk '$2 == "HEAD" { print $1; exit }')"
[ -n "$DEFAULT_SHA" ] || die "cannot read the default branch of the spoke's origin (git ls-remote origin HEAD)"
have_commit "$DEFAULT_SHA" || fetch_commits "$DEFAULT_SHA" || die "cannot fetch the default branch tip: $G_ERR"

info "spoke $SPOKE ($REPO) · kit $KIT_DESC ($KIT_SHORT) · records in $STORE"

# the run's own record: every line it prints, then its scorecard as aggregate.json
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$KIT_SHORT"
mkdir -p "$STORE/runs" && { mkdir "$STORE/runs/$RUN_ID" 2>/dev/null || { RUN_ID="$RUN_ID-$$"; mkdir "$STORE/runs/$RUN_ID"; }; } \
  || die "cannot create the run record under $STORE/runs"
RUN_DIR="$STORE/runs/$RUN_ID"
: > "$RUN_DIR/summary.txt" || die "cannot write $RUN_DIR/summary.txt"
SUMMARY="$RUN_DIR/summary.txt"
say_note() { warn "$1"; printf 'review-replay: note — %s\n' "$1" >> "$SUMMARY" || SUMMARY_LOST=1; }
printf 'review-replay: run — spoke %s (%s) · kit %s (%s, %s)\n' "$SPOKE" "$REPO" "$KIT_DESC" "$KIT_SHORT" "$KIT_CHECK" >> "$SUMMARY" \
  || die "cannot write $SUMMARY"
die_run() { printf 'review-replay: failed — run: %s\n' "$*" >> "$SUMMARY"; die "$*"; }

# --- per PR ----------------------------------------------------------------
# A step sets R_STEP/R_MSG and returns 1 (failed) or 2 (skipped).
R_STEP=""; R_MSG=""; R_LINE=""
fail_at() { R_STEP="$1"; R_MSG="$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-400 | sed 's/[[:space:]]*$//')"; return 1; }
skip_as() { R_MSG="$1"; return 2; }

gh_to() { # gh_to <file> <gh args...> — fails with gh's error
  local f="$1"; shift
  run_with_timeout "$NET_TIMEOUT" gh "$@" > "$f.raw" 2> "$f.err" || { G_ERR="gh $* $(exit_why $? "$NET_TIMEOUT"): $(err_of "$f.err")"; return 1; }
  mv "$f.raw" "$f"
}
gh_pages() { # gh_pages <file> <api path> — every page, as one array
  gh_to "$1.pages" api --paginate "$2" || return 1
  jq -s 'if length == 0 then error("no reply") elif all(type == "array") then add else error("not a list but \(map(type) | unique | join(", "))") end' \
    "$1.pages" > "$1" 2> "$1.err" \
    || { G_ERR="gh api $2: unparseable response: $(err_of "$1.err")"; return 1; }
}

# fetch the PR's GitHub data into $GH and find its first reviewed head (FIRST),
# or set FIRST empty when CodeRabbit never reviewed it
gather() {
  local n="$1" sha
  GH="$REC_TMP/github"; mkdir -p "$GH"; FIRST=""
  gh_to "$GH/pr.json" pr view "$n" -R "$REPO" --json number,url,author,state,baseRefName,headRefName,headRefOid,commits \
    || { fail_at github "$G_ERR"; return; }
  gh_to "$GH/pull.json" api "repos/$REPO/pulls/$n" || { fail_at github "$G_ERR"; return; }
  gh_pages "$GH/reviews.json" "repos/$REPO/pulls/$n/reviews" || { fail_at github "$G_ERR"; return; }
  gh_pages "$GH/comments.json" "repos/$REPO/pulls/$n/comments" || { fail_at github "$G_ERR"; return; }
  gh_pages "$GH/issue-comments.json" "repos/$REPO/issues/$n/comments" || { fail_at github "$G_ERR"; return; }
  jq -e 'type == "object"' "$GH/pull.json" > /dev/null 2>&1 || { fail_at github "unparseable reply from pulls/$n"; return; }
  jq -r '.commits[].oid' "$GH/pr.json" > "$GH/pr-commits.txt" && [ -s "$GH/pr-commits.txt" ] \
    || { fail_at github "gh pr view listed no commits for PR #$n"; return; }
  : > "$GH/statuses.pages"
  while read -r sha; do
    gh_pages "$GH/st-$sha.json" "repos/$REPO/commits/$sha/statuses" || { fail_at github "$G_ERR"; return; }
    jq --arg s "$sha" '{sha: $s, statuses: .}' "$GH/st-$sha.json" >> "$GH/statuses.pages" \
      || { fail_at github "cannot read the statuses of ${sha:0:7}"; return; }
    rm -f "$GH/st-$sha".*
  done < "$GH/pr-commits.txt"
  jq -s . "$GH/statuses.pages" > "$GH/statuses.json" || { fail_at github "cannot assemble statuses"; return; }
  rm -f "$GH"/*.pages "$GH"/*.err
  # the rule of review-postmortem.md step 2: the earliest non-empty review or "Review completed" status
  FIRST="$(jq -rn --arg cr "$CR_LOGIN" --slurpfile r "$GH/reviews.json" --slurpfile s "$GH/statuses.json" '
    ([$r[0][] | select(.user.login == $cr and (.body // "") != "" and .commit_id != null)
       | {at: .submitted_at, sha: .commit_id}]
     + [$s[0][] | .sha as $c | .statuses[]
       | select(.creator.login == $cr and ((.description // "") | startswith("Review completed")))
       | {at: .created_at, sha: $c}])
    | sort_by(.at) | .[0].sha // ""')" || { fail_at github "cannot read CodeRabbit's reviews"; return; }
}


# repo-owned files: the PR commit's, else the default branch's; records each in OWNED
REPO_OWNED=".review/rubric.md .review/learnings.md .review/config.sh .review/analyzers.local.sh .review/prompts.local"
is_hub_kit() { grep -qE '^kit: [^ ]*codex-review-kit' "$1" 2>/dev/null; }
overlay() {
  local wt="$1" p src from="" default_kit at_pr at_merge
  default_kit="$RUN_TMP/default-kit-version"
  p="$(git -C "$SPOKE" ls-tree "$DEFAULT_SHA" -- .review/kit-version)" \
    || { fail_at kit "cannot list .review/kit-version on the default branch (${DEFAULT_SHA:0:7})"; return; }
  : > "$default_kit"
  [ -z "$p" ] || git -C "$SPOKE" show "$DEFAULT_SHA:.review/kit-version" > "$default_kit" \
    || { fail_at kit "cannot read .review/kit-version on the default branch (${DEFAULT_SHA:0:7})"; return; }
  if is_hub_kit "$wt/.review/kit-version"; then
    from=pr
  elif [ -e "$wt/.review" ]; then
    p="$(sed -n 's/^kit: \([^ ]*\).*/\1/p' "$wt/.review/kit-version" 2>/dev/null | head -n1)"
    skip_as "pre-hub review kit at ${FIRST:0:7} (${p:-no .review/kit-version}): its repo-owned files predate the hub, so they may not fit today's kit"
    return
  elif is_hub_kit "$default_kit"; then
    from=default
  else
    skip_as "no hub review kit at ${FIRST:0:7} or on the default branch (${DEFAULT_SHA:0:7})"
    return
  fi
  # a PR can commit any of these as a symlink, and the overlay would write through it
  git -C "$wt" ls-files -s -- .review scripts .claude .codex .githooks .claude-plugin REVIEW.md OPERATING.md > "$REC_TMP/kit-paths.txt" \
    || { fail_at kit "cannot list the kit's paths at ${FIRST:0:7}"; return; }
  p="$(awk -F '\t' '{ split($1, m, " ") } m[1] == "120000" { print $2 }' "$REC_TMP/kit-paths.txt" | head -n3 | tr '\n' ' ')"
  [ -z "$p" ] || { skip_as "symlink in the kit's paths at ${FIRST:0:7} (${p% }): the kit overlay would write through it"; return; }
  # review.sh runs these two; a version that never merged would run unreviewed code
  [ "$from" != pr ] || [ -n "$MERGED" ] || { fail_at github "pulls/$CUR_PR has no merge_commit_sha to check its config against"; return; }
  [ "$from" != pr ] || for p in .review/config.sh .review/analyzers.local.sh; do
    at_pr="$(git -C "$SPOKE" ls-tree "$FIRST" -- "$p")" || { fail_at kit "cannot list $p at ${FIRST:0:7}"; return; }
    at_merge="$(git -C "$SPOKE" ls-tree "$MERGED" -- "$p")" || { fail_at kit "cannot list $p at ${MERGED:0:7}"; return; }
    [ "$at_pr" = "$at_merge" ] \
      || { skip_as "$p at ${FIRST:0:7} differs from the merged one (${MERGED:0:7}): the replay would run code that never merged"; return; }
  done
  OWNED="{}"
  for p in $REPO_OWNED; do
    if [ "$from" = pr ] && [ -e "$wt/$p" ]; then
      src=pr
    elif ! src="$(git -C "$SPOKE" ls-tree "$DEFAULT_SHA" -- "$p")"; then
      fail_at kit "cannot list $p on the default branch (${DEFAULT_SHA:0:7})"; return
    elif [ -n "$src" ]; then
      git -C "$SPOKE" archive "$DEFAULT_SHA" -- "$p" | tar -x -C "$wt" \
        || { fail_at kit "cannot copy $p from the default branch (${DEFAULT_SHA:0:7})"; return; }
      src="default@${DEFAULT_SHA:0:12}"
    else
      src=absent
    fi
    OWNED="$(jq -c --arg p "$p" --arg s "$src" '. + {($p): $s}' <<< "$OWNED")"
  done
  # a committed verdict would be archived into the spoke's review history by review.sh
  rm -f "$wt/.review/verdict.md" "$wt/.review/spec-verdict.md"
  # today's prompts only: a lens the kit has since retired must not run from its old prompt
  rm -rf "$wt/.review/prompts"
  ( cd "$wt" && REVIEW_KIT_DIR="$KIT_DIR" bash "$KIT_DIR/scripts/review-update.sh" --local ) \
    > "$REC_TMP/kit.log" 2>&1 || { fail_at kit "review-update.sh --local failed: $(tail -n1 "$REC_TMP/kit.log")"; return; }
  # --local cannot name a commit for an archive; the replay can
  printf 'kit: https://github.com/theunisdk/codex-review-kit %s\nref: %s\nrelease: unreleased\nsource: review-replay\nsynced: %s\n' \
    "$KIT_SHORT" "$KIT_DESC" "$(date +%Y-%m-%d)" > "$wt/.review/kit-version"
}

# Read-only by construction: no settings file is loaded (a user's allow rules would apply under
# dontAsk), there is no Edit or Write tool, every Bash command not allowed here is denied, and
# gh is denied outright, so a replay cannot comment, file or push. No git grep: its -O runs a
# command, and can hide in a cluster such as -nO.
READ_RULES=("Bash(git log:*)" "Bash(git show:*)" "Bash(git diff:*)" "Bash(git rev-parse:*)"
  "Bash(git rev-list:*)" "Bash(git merge-base:*)" "Bash(git cat-file:*)" "Bash(git blame:*)" "Bash(jq:*)"
  "Bash(grep:*)" "Bash(wc:*)")
# claude_call <kind> <prompt> — in the checkout. The whole stream is kept as
# transcript-<kind>.jsonl, its result event as <kind>.json, and the call's
# permission_denials in DENIALS.<kind>: null when the call gave no list.
claude_call() {
  local kind="$1" prompt="$2" rc c d out tr
  local model_args=()
  out="$REC_TMP/$kind.json"; tr="$REC_TMP/transcript-$kind.jsonl"
  [ -z "$MODEL" ] || model_args=(--model "$MODEL")
  run_child "$CLAUDE_TIMEOUT" in_dir "$CUR_WT" claude -p "$prompt" ${model_args[@]+"${model_args[@]}"} \
    --setting-sources "" --output-format stream-json --verbose --no-session-persistence --strict-mcp-config \
    --settings '{"disableAllHooks":true}' --max-budget-usd "$BUDGET" \
    --tools "Read,Grep,Glob,Bash" --permission-mode dontAsk \
    --disallowedTools "Bash(gh:*)" "Bash(git push:*)" "Bash(git commit:*)" "Bash(git fetch:*)" \
      "Bash(git * --output*)" "Bash(git * --ext-diff*)" "Bash(git * --textconv*)" \
    --allowedTools "${READ_RULES[@]}" > "$tr" 2> "$out.err"
  rc=$?
  # a stream cut off by a timeout can end in half a line
  jq -Rc 'fromjson? | select(type == "object" and .type == "result")' "$tr" 2>/dev/null | tail -n1 > "$out"
  d="$(jq -c '.permission_denials | arrays' "$out" 2>/dev/null)"
  DENIALS="$(jq -c --arg k "$kind" --argjson d "${d:-null}" '. + {($k): $d}' <<< "$DENIALS")"
  if c="$(jq -e '.total_cost_usd | numbers' "$out" 2>/dev/null)"; then
    COST="$(jq -n --argjson a "${COST:-0}" --argjson b "$c" '$a + $b')"
  else
    COST_UNKNOWN=$((COST_UNKNOWN + 1))
  fi
  if [ ! -s "$out" ]; then
    c="$(err_of "$out.err")"
    G_ERR="claude $(exit_why "$rc" "$CLAUDE_TIMEOUT"), with no result in its transcript${c:+: $c}"; return 1
  fi
  jq -e '.is_error != true and (.result | type) == "string"' "$out" > /dev/null 2>&1 \
    || { G_ERR="claude: $(jq -r '[.subtype, (.result // "" | .[0:200])] | map(select(. != null)) | join(": ")' "$out" 2>/dev/null)"; return 1; }
}

replay_pr() {
  local n="$1" base_tip base wt branch verdict body json rel first_line separates raw_err f gaps
  REC="$STORE/pr$n-$KIT_SHORT"; COST=0; COST_UNKNOWN=0; R_COUNTS=""; CODEX_TOKENS=0; DENIALS="{}"
  if [ -z "${GATHERED:-}" ]; then
    REC_TMP="$RUN_TMP/pr$n"; rm -rf "$REC_TMP"; mkdir -p "$REC_TMP"
    gather "$n" || return
  fi
  GATHERED=""
  [ -n "$FIRST" ] || { skip_as "CodeRabbit has not reviewed PR #$n"; return; }
  rel="$(jq -r '.state // ""' "$GH/pr.json")" && [ -n "$rel" ] || { fail_at github "gh pr view gave no state for PR #$n"; return; }
  [ "$rel" = MERGED ] || { skip_as "PR #$n is $rel, not merged: a replay runs the commit's own .review/config.sh and analyzers.local.sh"; return; }
  short="${FIRST:0:7}"
  base_tip="$(jq -r '.base.sha // empty' "$GH/pull.json")"
  branch="$(jq -r '.headRefName // "replay"' "$GH/pr.json")"
  MERGED="$(jq -r '.merge_commit_sha // empty' "$GH/pull.json")"
  [ -n "$base_tip" ] || { fail_at github "pulls/$n has no base.sha"; return; }

  # --- fetch: the PR head, the reviewed commit, its base; objects only
  fetch_commits "refs/pull/$n/head" || { fail_at fetch "$G_ERR"; return; }
  for rel in "$FIRST" "$base_tip" ${MERGED:+"$MERGED"}; do
    have_commit "$rel" || fetch_commits "$rel" || { fail_at fetch "$G_ERR"; return; }
  done
  # commits CodeRabbit commented on after a force-push: one the postmortem cannot read would
  # turn its findings into unscored ones, so a commit that cannot be fetched fails the PR
  # one input: given two files, jq goes on past an error in the first and exits 0
  jq -rs --arg cr "$CR_LOGIN" 'add | .[] | select(.user.login == $cr) | (.original_commit_id // .commit_id // empty)' \
    "$GH/comments.json" "$GH/reviews.json" > "$REC_TMP/commented.all" 2> "$REC_TMP/commented.err" \
    || { fail_at github "cannot list the commits CodeRabbit commented on: $(err_of "$REC_TMP/commented.err")"; return; }
  sort -u "$REC_TMP/commented.all" > "$REC_TMP/commented.txt" || { fail_at github "cannot list the commits CodeRabbit commented on"; return; }
  while read -r rel; do
    have_commit "$rel" || fetch_commits "$rel" \
      || { fail_at fetch "cannot fetch ${rel:0:7}, which CodeRabbit commented on, so its findings would go unscored: $G_ERR"; return; }
  done < "$REC_TMP/commented.txt"

  # --- base: where the reviewed commit left the base branch
  is_ancestor "$FIRST" "$base_tip" || { fail_at base "$G_ERR"; return; }
  if [ "$ANC" = yes ]; then
    # merged with a merge commit: the base branch before it is the merge's first parent
    rel="$MERGED"; separates=no
    if [ -n "$rel" ] && git -C "$SPOKE" rev-parse -q --verify "$rel^2" > /dev/null; then
      is_ancestor "$FIRST" "$rel^2" || { fail_at base "$G_ERR"; return; }
      if [ "$ANC" = yes ]; then
        is_ancestor "$FIRST" "$rel^1" || { fail_at base "$G_ERR"; return; }
        [ "$ANC" = yes ] || separates=yes
      fi
    fi
    [ "$separates" = yes ] || { fail_at base "the base branch tip ${base_tip:0:7} already contains $short, and no merge commit separates them"; return; }
    base_tip="$(git -C "$SPOKE" rev-parse --verify -q "$rel^1")" || { fail_at base "cannot read the first parent of ${rel:0:7}"; return; }
  fi
  base="$(git -C "$SPOKE" merge-base "$FIRST" "$base_tip")" || { fail_at base "no merge base of $short and ${base_tip:0:7}"; return; }

  # --- checkout: the reviewed commit's history and nothing else, no ref or object past it,
  # so no lens and no adjudicator can read a later fix (a worktree shares every ref)
  wt="$CHECKOUTS/replay-pr$n"
  git init -q "$wt" > "$REC_TMP/wt.err" 2>&1 && CUR_WT="$wt" \
    && GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_1=uploadpack.allowAnySHA1InWant GIT_CONFIG_VALUE_1=true \
      git -C "$wt" -c gc.auto=0 -c maintenance.auto=false fetch --quiet --no-tags --no-write-fetch-head "$SPOKE" "$FIRST" \
      < /dev/null >> "$REC_TMP/wt.err" 2>&1 \
    && git -C "$wt" -c advice.detachedHead=false checkout --quiet --detach "$FIRST" >> "$REC_TMP/wt.err" 2>&1 \
    || { fail_at checkout "cannot clone ${FIRST:0:7} alone: $(err_of "$REC_TMP/wt.err")"; return; }

  # --- kit: today's shared half over the PR's repo-owned half
  overlay "$wt" || return

  # --- review: today's pipeline over the diff CodeRabbit first saw
  # shellcheck disable=SC2086
  run_child "$REVIEW_TIMEOUT" in_dir "$wt" bash scripts/review.sh --fail-on none $REVIEW_ARGS "$base" > "$REC_TMP/review.log" 2>&1
  rel=$?
  CODEX_TOKENS="$(codex_tokens "$wt/.review/raw")"
  [ -f "$wt/.review/findings.json" ] && cp "$wt/.review/findings.json" "$wt/.review/findings.md" "$REC_TMP/" 2>/dev/null
  # each lens's own output, so a miss can be checked against what the lens returned
  raw_err=""
  mkdir -p "$REC_TMP/raw" || raw_err="cannot create $REC_TMP/raw"
  for f in "$wt"/.review/raw/out-*.json "$wt"/.review/raw/log-*.txt; do
    [ -e "$f" ] || continue
    cp "$f" "$REC_TMP/raw/" || raw_err="cannot keep .review/raw/${f##*/}"
  done
  [ "$rel" = 0 ] || { fail_at review "review.sh $(exit_why "$rel" "$REVIEW_TIMEOUT"): $(grep -E 'error:' "$REC_TMP/review.log" | tail -n1)"; return; }
  jq -e . "$REC_TMP/findings.json" > /dev/null 2>&1 || { fail_at review "no readable .review/findings.json"; return; }
  [ "$(jq '.changed_files // 0' "$REC_TMP/findings.json")" -gt 0 ] \
    || { fail_at review "nothing was reviewed (changed_files 0) over ${base:0:7}..$short"; return; }
  jq -e '.complete == true' "$REC_TMP/findings.json" > /dev/null \
    || { fail_at review "incomplete run: $(jq -c '{lenses_failed, unreadable_paths, secrets_scan}' "$REC_TMP/findings.json")"; return; }
  [ -z "$raw_err" ] || { fail_at review "$raw_err"; return; }
  ls "$REC_TMP"/raw/out-*.json > /dev/null 2>&1 || { fail_at review "review.sh left no lens output in .review/raw"; return; }

  # --- adjudicate: the verdict /review would write, with nothing applied
  claude_call adjudicate "Replay adjudication of PR #$n, commit $FIRST.

scripts/review-replay.sh checked out the first commit CodeRabbit reviewed on this PR and ran today's ./scripts/review.sh over ${base}..${FIRST}. Its report is .review/findings.json, and it is complete.

Read .review/adjudication.md and follow it, steps 2 to 5, with the deltas in its \"Replay mode\" section. Write nothing and change nothing. Your final message is the verdict and nothing else, starting with the line:
# Review verdict — $branch — $short — $(date -u +%Y-%m-%d)" \
    || { fail_at adjudicate "$G_ERR"; return; }
  verdict="$REC_TMP/verdict.md"
  # from the header on, without a closing fence or trailing blank lines
  jq -r '.result' "$REC_TMP/adjudicate.json" | awk '/^# Review verdict — / { on = 1 } on { l[++n] = $0 }
    END { while (n > 0 && l[n] ~ /^[[:space:]]*(```)?[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print l[i] }' > "$verdict"
  awk -F ' — ' -v want="$FIRST" 'NR == 1 { ok = (NF == 4 && $3 ~ /^[0-9a-f]+$/ && length($3) >= 7 && index(want, $3) == 1) } END { exit !ok }' "$verdict" \
    || { fail_at adjudicate "the reply has no verdict header naming $short: $(jq -r '.result | .[0:200]' "$REC_TMP/adjudicate.json")"; return; }
  cp "$verdict" "$wt/.review/verdict.md"

  # --- postmortem: score the verdict against CodeRabbit, record only. It compares later
  # heads, so it alone reads the spoke's objects; it still sees none of its refs
  printf '%s\n' "$COMMON/objects" > "$wt/.git/objects/info/alternates" \
    || { fail_at postmortem "cannot give the checkout the spoke's objects"; return; }
  mkdir -p "$wt/.review/replay" && cp "$GH"/*.json "$GH/pr-commits.txt" "$wt/.review/replay/" \
    || { fail_at postmortem "cannot copy the GitHub data into the checkout"; return; }
  claude_call postmortem "Replay postmortem of PR #$n.

Read .claude/commands/review-postmortem.md and follow it with the arguments: $n --replay .review/replay
Its \"Replay mode\" section says what changes: the GitHub data is already in .review/replay/, the verdict is .review/verdict.md, and you print the record instead of saving or posting it." \
    || { fail_at postmortem "$G_ERR"; return; }
  jq -r '.result' "$REC_TMP/postmortem.json" > "$REC_TMP/postmortem.out"
  first_line="$(grep -m1 '^review-postmortem: ' "$REC_TMP/postmortem.out")"
  case "$first_line" in
    "review-postmortem: scored — "*) ;;
    "review-postmortem: skipped — "*) skip_as "postmortem: ${first_line#review-postmortem: skipped — }"; return ;;
    "review-postmortem: failed — "*) fail_at postmortem "${first_line#review-postmortem: failed — }"; return ;;
    "review-postmortem: no-local-verdict — "*) fail_at postmortem "no-local-verdict despite the replay verdict: ${first_line#*— }"; return ;;
    *) fail_at postmortem "no status line: $(head -c 200 "$REC_TMP/postmortem.out")"; return ;;
  esac
  body="$REC_TMP/body.md"; json="$REC_TMP/record.json"
  awk '/^<!-- review-postmortem:v1 -->$/ { on = 1 } on' "$REC_TMP/postmortem.out" > "$body"
  awk '/^```json[[:space:]]*$/ { on = 1; next } on && /^```[[:space:]]*$/ { exit } on' "$body" > "$json"
  jq -e --arg c "$FIRST" --argjson n "$n" '.pr == $n and .status == "scored" and (.compared_commit as $cc | ($cc | type == "string" and length >= 7) and ($c | startswith($cc)))
      and ([.counts.caught, .counts.missed, .counts.rejected_wrongly, .counts.noise, .counts.unscored] | all(type == "number"))' \
    "$json" > /dev/null 2>&1 \
    || { fail_at postmortem "the record's JSON is missing, unparseable, or not a scored record of PR #$n at $short"; return; }
  jq -e 'def n($k): [.findings[] | select(.class == $k)] | length;
      def m($c): [.findings[] | select(.class == "missed" and .cause == $c)] | length;
      (.findings | type == "array" and all(.[]; .class as $k | ["caught", "missed", "rejected-wrongly", "noise", "unscored"] | index($k)))
      and .counts == {caught: n("caught"), missed: n("missed"), rejected_wrongly: n("rejected-wrongly"), noise: n("noise"), unscored: n("unscored")}
      and .missed_by_cause == {wrong_lens: m("wrong_lens"), tracing: m("tracing"), threshold: m("threshold"), structural: m("structural")}' \
    "$json" > /dev/null 2>&1 \
    || { fail_at postmortem "the record's counts or missed_by_cause do not tally its findings: $(jq -c '{counts, missed_by_cause}' "$json" 2>/dev/null)"; return; }

  # a finding the postmortem could not compare is unscored, not scored: the PR is incomplete
  gaps="$(jq -r '[.findings[] | select(.unscored_reason | strings | startswith("compare_failed"))]
      | if length == 0 then "" else "\(length) finding(s) unscored because a compare failed (\(.[0].unscored_reason | .[0:200]))" end' "$json")" \
    || { fail_at postmortem "cannot read the record's unscored reasons"; return; }

  # --- record: the replay's own facts merged into the postmortem's JSON
  jq --arg ref "$KIT_REF" --arg sha "$KIT_SHA" --arg desc "$KIT_DESC" --arg base "$base" \
     --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson owned "$OWNED" --argjson cost "$COST" \
     --argjson cu "$COST_UNKNOWN" --arg tokens "$CODEX_TOKENS" --argjson denials "$DENIALS" '. + {replay: {kit_ref: $ref, kit_sha: $sha, kit_describe: $desc,
       base: $base, repo_owned: $owned, date: $date,
       cost: {claude_usd: (if $cu > 0 then null else $cost end), codex_tokens: ($tokens | tonumber? // null)},
       permission_denials: $denials}}' \
    "$json" > "$json.tmp" && mv "$json.tmp" "$json" || { fail_at record "cannot merge the replay facts"; return; }
  {
    printf '<!-- review-replay:v1 -->\n'
    printf '> **Replay** of kit `%s` (%s) on the commit CodeRabbit first reviewed. It scores today'"'"'s kit, not the review that ran on this PR.\n\n' "$KIT_SHORT" "$KIT_DESC"
    awk -v f="$json" '/^```json[[:space:]]*$/ && !done { print; while ((getline l < f) > 0) print l; skip = 1; next }
      skip && /^```[[:space:]]*$/ { skip = 0; done = 1 } !skip' "$body"
  } > "$REC_TMP/postmortem.md" || { fail_at record "cannot write postmortem.md"; return; }
  R_COUNTS="$(jq -r '"caught \(.counts.caught) / missed \(.counts.missed) / rejected-wrongly \(.counts.rejected_wrongly) / noise \(.counts.noise) / unscored \(.counts.unscored)"' "$json")"
  [ -z "$gaps" ] || { R_MSG="$gaps"; return 3; }
}

# keep the PR's artifacts, whatever the outcome, in $LOGS: a re-run replaces them, except
# that a scored record is only ever replaced by another one
save_record() { # save_record <rc>
  LOGS="$REC"
  [ "$1" = 0 ] || [ "$1" = 3 ] || ! grep -qE '^review-replay: (replayed|incomplete) — ' "$REC/outcome.txt" 2>/dev/null || LOGS="$REC.last-unscored"
  rm -rf "$LOGS.tmp.$$" "$LOGS.old.$$" && cp -R "$REC_TMP" "$LOGS.tmp.$$" && printf '%s\n' "$R_LINE" > "$LOGS.tmp.$$/outcome.txt" \
    && { [ ! -e "$LOGS" ] || mv "$LOGS" "$LOGS.old.$$"; } || return 1
  mv "$LOGS.tmp.$$" "$LOGS" || { [ ! -e "$LOGS.old.$$" ] || mv "$LOGS.old.$$" "$LOGS"; return 1; }
  rm -rf "$LOGS.old.$$"
  [ "$1" != 0 ] && [ "$1" != 3 ] || rm -rf "$REC.last-unscored"
}

# --- the PR list -----------------------------------------------------------
N_REPLAYED=0; N_INCOMPLETE=0; N_SKIPPED=0; N_FAILED=0; N_UNREVIEWED=0; TOTAL_COST=0; TOTAL_TOKENS=0
N_COST_UNKNOWN=0; N_TOKENS_UNKNOWN=0; RECENT_JSON=null; DENIALS="{}"
N_DENIED=0; N_PRS_DENIED=0; N_DENIALS_UNKNOWN=0
# cost_of <usd> <calls of unknown cost> <tokens or "unknown">
cost_of() {
  printf 'claude $%.2f' "$1"
  [ "$2" = 0 ] || printf ' + unknown for %s call(s)' "$2"
  if [ "$3" = unknown ]; then printf ', codex tokens unknown'; else printf ', codex %s tokens' "$3"; fi
}
# count_denials — sets DENIED to " · commands denied: …" for each claude call in DENIALS
# that had a denial or gave no list (else empty), and counts them into the run's totals
count_denials() {
  local n
  DENIED="$(jq -r 'to_entries | map(select(.value == null or (.value | length) > 0)
      | "\(.key) \(if .value == null then "unknown" else .value | length end)") | join(", ")' <<< "$DENIALS")" \
    && n="$(jq -r '[.[] | select(. != null) | length] | add // 0' <<< "$DENIALS")" \
    || { DENIED="unreadable"; n=0; N_DENIALS_UNKNOWN=$((N_DENIALS_UNKNOWN + 1)); }
  [ -z "$DENIED" ] || DENIED=" · commands denied: $DENIED"
  N_DENIED=$((N_DENIED + n)); [ "$n" = 0 ] || N_PRS_DENIED=$((N_PRS_DENIED + 1))
  ! jq -e 'any(.[]; . == null)' <<< "$DENIALS" > /dev/null 2>&1 || N_DENIALS_UNKNOWN=$((N_DENIALS_UNKNOWN + 1))
}
report() { # report <rc> <n>
  local cost denied
  cost="$(cost_of "${COST:-0}" "${COST_UNKNOWN:-0}" "${CODEX_TOKENS:-0}")"
  count_denials; denied="$DENIED"
  case "$1" in
    0) R_LINE="review-replay: replayed — PR #$2 ($short, kit $KIT_SHORT): $R_COUNTS$denied · cost $cost" ;;
    3) R_LINE="review-replay: incomplete — PR #$2 ($short, kit $KIT_SHORT): $R_COUNTS · $R_MSG$denied · cost $cost" ;;
    2) R_LINE="review-replay: skipped — PR #$2: $R_MSG" ;;
    *) R_LINE="review-replay: failed — PR #$2: $R_STEP: $R_MSG$denied"
       [ "$cost" = "claude \$0.00, codex 0 tokens" ] || R_LINE="$R_LINE · cost so far $cost" ;;
  esac
  TOTAL_COST="$(jq -n --argjson a "$TOTAL_COST" --argjson b "${COST:-0}" '$a + $b')"
  N_COST_UNKNOWN=$((N_COST_UNKNOWN + ${COST_UNKNOWN:-0}))
  if [ "${CODEX_TOKENS:-0}" = unknown ]; then N_TOKENS_UNKNOWN=$((N_TOKENS_UNKNOWN + 1))
  else TOTAL_TOKENS=$((TOTAL_TOKENS + ${CODEX_TOKENS:-0})); fi
  LOGS=""
  # the run's scorecard reads its own copy: a later run can replace $REC before this one ends
  case "$1" in 0|3)
    cp "$REC_TMP/record.json" "$RUN_TMP/record-$((N_REPLAYED + N_INCOMPLETE + 1)).json" \
      || { R_LINE="review-replay: failed — PR #$2: record: cannot keep a copy for the run's scorecard"; set -- 1 "$2"; } ;;
  esac
  if [ -d "${REC_TMP:-}" ] && ! save_record "$1"; then
    LOGS=""
    case "$1" in
      0|3) R_LINE="review-replay: failed — PR #$2: record: cannot write $REC"; set -- 1 "$2" ;;
      *) R_LINE="$R_LINE (logs not saved: cannot write $REC)" ;;
    esac
  fi
  case "$1" in
    0) N_REPLAYED=$((N_REPLAYED + 1)); R_LINE="$R_LINE · record $REC/postmortem.md" ;;
    3) N_INCOMPLETE=$((N_INCOMPLETE + 1)); R_LINE="$R_LINE · record $REC/postmortem.md" ;;
    2) N_SKIPPED=$((N_SKIPPED + 1)) ;;
    *) N_FAILED=$((N_FAILED + 1)); [ -z "$LOGS" ] || R_LINE="$R_LINE (logs: $LOGS)" ;;
  esac
  say "$R_LINE"
}

run_one() {
  local n="$1" rc
  short=""; CUR_PR="$n"; replay_pr "$n"; rc=$?
  stop_child
  if ! remove_checkout; then
    [ "$rc" = 1 ] || { R_STEP=cleanup; R_MSG="the replay checkout could not be removed"; rc=1; }
  fi
  report "$rc" "$n"; CUR_PR=""
}

ATTEMPTED=0
if [ -n "$RECENT" ]; then
  LIST="$RUN_TMP/merged.json"
  gh_to "$LIST" pr list -R "$REPO" --state merged --limit "$SCAN" --json number,mergedAt \
    || die_run "cannot list merged PRs: $G_ERR"
  jq -e 'type == "array"' "$LIST" > /dev/null 2>&1 || die_run "gh pr list returned no PR list: $(head -c 200 "$LIST")"
  NUMS="$(jq -r 'sort_by(.mergedAt) | reverse | .[].number' "$LIST" 2> "$RUN_TMP/list.err")" \
    || die_run "cannot read the merged PR list: $(err_of "$RUN_TMP/list.err")"
  FOUND=0
  for n in $NUMS; do
    [ "$FOUND" -lt "$RECENT" ] || break
    REC_TMP="$RUN_TMP/pr$n"; rm -rf "$REC_TMP"; mkdir -p "$REC_TMP"; REC="$STORE/pr$n-$KIT_SHORT"; short=""; COST=0; COST_UNKNOWN=0; CODEX_TOKENS=0; DENIALS="{}"
    CUR_PR="$n"; gather "$n"; rc=$?; CUR_PR=""
    if [ "$rc" = 0 ] && [ -z "$FIRST" ]; then N_UNREVIEWED=$((N_UNREVIEWED + 1)); rm -rf "$REC_TMP"; continue; fi
    FOUND=$((FOUND + 1))
    if [ "$rc" != 0 ]; then report "$rc" "$n"; continue; fi
    if [ "$ATTEMPTED" -ge "$LIMIT" ]; then R_MSG="--limit $LIMIT reached"; REC_TMP=""; report 2 "$n"; continue; fi
    ATTEMPTED=$((ATTEMPTED + 1)); GATHERED=1; run_one "$n"
  done
  [ "$FOUND" -ge "$RECENT" ] || say_note "found $FOUND CodeRabbit-reviewed PR(s) among the $SCAN most recent merged PRs, not $RECENT"
  RECENT_JSON="{\"asked\": $RECENT, \"found\": $FOUND, \"scanned\": $SCAN}"
else
  for n in $PRS; do
    if [ "$ATTEMPTED" -ge "$LIMIT" ]; then R_MSG="--limit $LIMIT reached"; REC_TMP=""; short=""; COST=0; COST_UNKNOWN=0; CODEX_TOKENS=0; DENIALS="{}"; report 2 "$n"; continue; fi
    ATTEMPTED=$((ATTEMPTED + 1)); run_one "$n"
  done
fi

# --- aggregate -------------------------------------------------------------
AGG="$RUN_DIR/aggregate.json"
SCORE=(jq -L "$HUB/scripts/lib")
N_SCORED=$((N_REPLAYED + N_INCOMPLETE))
i=0; : > "$RUN_TMP/records.all" || die_run "cannot read the records back"
while [ "$i" -lt "$N_SCORED" ]; do
  i=$((i + 1)); cat "$RUN_TMP/record-$i.json" >> "$RUN_TMP/records.all" || die_run "cannot read the records back"
done
jq -s . "$RUN_TMP/records.all" > "$RUN_TMP/records.json" || die_run "cannot read the records back"
PRS_JSON="{\"replayed\": $N_REPLAYED, \"incomplete\": $N_INCOMPLETE, \"skipped\": $N_SKIPPED, \"failed\": $N_FAILED, \"unreviewed_passed_over\": $N_UNREVIEWED}"
COST_JSON="$(jq -n --argjson cost "$TOTAL_COST" --argjson cu "$N_COST_UNKNOWN" --argjson tokens "$TOTAL_TOKENS" --argjson tu "$N_TOKENS_UNKNOWN" \
  '{claude_usd: $cost, claude_calls_of_unknown_cost: $cu, codex_tokens: $tokens, prs_of_unknown_codex_tokens: $tu}')" || die_run "cannot sum the cost"
DENIALS_JSON="{\"commands\": $N_DENIED, \"prs_with_denials\": $N_PRS_DENIED, \"prs_of_unknown_denials\": $N_DENIALS_UNKNOWN}"
"${SCORE[@]}" -r --argjson prs "$PRS_JSON" --argjson denials "$DENIALS_JSON" 'include "replay-scorecard";
  "review-replay: aggregate — \($prs | prs_text) — \(tally | counts_text)",
  lessons("PR #\(.pr)")' "$RUN_TMP/records.json" > "$RUN_TMP/scorecard.txt" || die_run "cannot sum the records"
printf 'review-replay: cost — %s, failed and skipped PRs included\n' \
  "$(cost_of "$TOTAL_COST" "$N_COST_UNKNOWN" "$TOTAL_TOKENS")$([ "$N_TOKENS_UNKNOWN" = 0 ] || printf ' + unknown for %s PR(s)' "$N_TOKENS_UNKNOWN")" \
  >> "$RUN_TMP/scorecard.txt" || die_run "cannot sum the cost"
"${SCORE[@]}" -rn --argjson d "$DENIALS_JSON" 'include "replay-scorecard"; "review-replay: denials — \($d | denials_text), failed PRs included"' \
  >> "$RUN_TMP/scorecard.txt" || die_run "cannot sum the denials"
while IFS= read -r l; do say "$l"; done < "$RUN_TMP/scorecard.txt"
"${SCORE[@]}" --arg run "$RUN_ID" --arg repo "$REPO" --arg ref "$KIT_REF" --arg sha "$KIT_SHA" --arg desc "$KIT_DESC" \
   --argjson prs "$PRS_JSON" --argjson recent "$RECENT_JSON" --argjson cost "$COST_JSON" --argjson denials "$DENIALS_JSON" --arg check "$KIT_CHECK" \
   --rawfile summary "$SUMMARY" 'include "replay-scorecard";
  {schema: "review-replay-run/v2", run: $run, repo: $repo, kit: {ref: $ref, sha: $sha, describe: $desc, check: $check}, recent: $recent,
   prs: $prs} + tally + {cost: $cost, denials: $denials,
   summary: ($summary | split("\n") | map(select(. != ""))),
   records: .}' "$RUN_TMP/records.json" > "$AGG.tmp" && mv "$AGG.tmp" "$AGG" || die_run "cannot write $AGG"
[ -z "$SUMMARY_LOST" ] || die "cannot write every line to $SUMMARY, so the run record is incomplete"
RUN_DONE=1
printf 'review-replay: run record — %s\n' "$RUN_DIR"
[ "$N_FAILED" = 0 ] && [ "$N_INCOMPLETE" = 0 ]
