#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# review-sync.sh — open a PR that syncs this repo's review kit to the latest
# release. Run weekly by .github/workflows/review-kit-sync.yml, which
# `review-update.sh --init` seeds; it runs anywhere with git, gh and a token.
#
#   ./scripts/review-sync.sh
#
# Current: exits 0 with a line naming the version. Behind: runs
# review-update.sh pinned to the latest release on the branch review-kit-sync,
# force-pushes it, and opens the one PR titled "sync review kit to vX.Y.Z" — or
# retitles the open one when a newer release lands. It never merges, approves
# or enables auto-merge: a sync PR always waits for a human.
#
# Every failure exits non-zero, never a green no-op: hub unreachable (1 from
# --latest-release), no release tag (2), a failed or empty sync, a refused
# push, a gh failure, and Actions forbidden to create pull requests.
#
# Env: REVIEW_KIT_URL (the hub; default: kit-version's, then the public repo),
# REVIEW_KIT_REPO (owner/name for release notes; default: from a github.com
# hub URL), REVIEW_SYNC_BRANCH (default review-kit-sync), GH_TOKEN (gh's).
# ---------------------------------------------------------------------------
set -uo pipefail

BRANCH="${REVIEW_SYNC_BRANCH:-review-kit-sync}"
TRAILER="Review-Kit-Sync"
BODY_MAX=60000   # GitHub rejects a PR body over 65536 characters

TMP="$(mktemp -d)" || { echo "error: no temp dir" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# One line on stderr, an annotation on the run, a line in the job summary.
fail() {
  printf 'error: %s\n' "$*" >&2
  [ -z "${GITHUB_ACTIONS:-}" ] || printf '::error title=review kit sync failed::%s\n' "$*"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf 'review kit sync **failed**: %s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
  exit 1
}
done_ok() {
  printf '%s\n' "$*"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
  exit 0
}
first_line() { head -n1 "$1" 2>/dev/null | cut -c1-300; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "run from inside the repo to sync"
cd "$ROOT" || fail "cannot cd to $ROOT"
[ -f scripts/lib/common.sh ] || fail "scripts/lib/common.sh is missing — this repo's kit is incomplete"
. scripts/lib/common.sh
command -v gh >/dev/null 2>&1 || fail "gh (GitHub CLI) is not on PATH"
[ -f .review/kit-version ] \
  || fail ".review/kit-version is missing — this repo was never synced; run scripts/review-update.sh by hand once"
STATUS="$(git status --porcelain --untracked-files=all)" || fail "git status failed in $ROOT"
[ -z "$STATUS" ] \
  || fail "the working tree has changes — the sync commits everything it finds, so run it from a clean checkout"

KV_URL="$(sed -n 's/^kit: \([^ ]*\) .*/\1/p' .review/kit-version | head -n1)"
REVIEW_KIT_URL="${REVIEW_KIT_URL:-${KV_URL:-https://github.com/theunisdk/codex-review-kit}}"
export REVIEW_KIT_URL
unset REVIEW_KIT_DIR REVIEW_KIT_REF
HUB_REPO="${REVIEW_KIT_REPO:-$(printf '%s\n' "$REVIEW_KIT_URL" \
  | sed -nE 's#^(https://|ssh://git@|git@)github\.com[:/]([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//')}"

REF="$(sed -n 's/^ref: //p' .review/kit-version | head -n1)"
INSTALLED="$(sed -n 's/^release: //p' .review/kit-version | head -n1)"
# a kit-version from before release: was recorded names a release only as its ref
[ -n "$INSTALLED" ] || INSTALLED="$(printf '%s\n' "$REF" | grep -Ex 'v[0-9]+\.[0-9]+\.[0-9]+')"
printf '%s\n' "$INSTALLED" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+' || INSTALLED=""

# --- the latest release ------------------------------------------------------
bash scripts/review-update.sh --latest-release > "$TMP/latest" 2> "$TMP/latest.err"; rc=$?
LATEST="$(head -n1 "$TMP/latest" | grep -Ex 'v[0-9]+\.[0-9]+\.[0-9]+')"
case "$rc" in
  0) [ -n "$LATEST" ] || fail "the release lookup on $REVIEW_KIT_URL printed no release tag" ;;
  1) fail "hub $REVIEW_KIT_URL is unreachable: $(first_line "$TMP/latest.err")" ;;
  2) fail "hub $REVIEW_KIT_URL lists no vN.N.N release tag — nothing to sync to" ;;
  *) fail "the release lookup failed (exit $rc): $(first_line "$TMP/latest.err")" ;;
esac

if [ "$INSTALLED" = "$LATEST" ]; then
  done_ok "review kit current: $INSTALLED is the latest release of $REVIEW_KIT_URL"
fi
if [ -n "$INSTALLED" ] && release_older "$LATEST" "$INSTALLED"; then
  [ -z "${GITHUB_ACTIONS:-}" ] || echo "::warning::review kit $INSTALLED is newer than the hub's latest release $LATEST"
  done_ok "review kit ahead: $INSTALLED is newer than $REVIEW_KIT_URL's latest release $LATEST — nothing to sync"
fi
TITLE="sync review kit to $LATEST"

BASE="$(git symbolic-ref --short -q HEAD)" || fail "HEAD is detached — check out the default branch first"
[ "$BASE" != "$BRANCH" ] || fail "run from the default branch, not $BRANCH"

# --- the one sync PR -----------------------------------------------------------
gh pr list --head "$BRANCH" --state open --json number,title,url \
  --jq '.[] | "\(.number)\t\(.title)\t\(.url)"' > "$TMP/open" 2> "$TMP/gh.err" \
  || fail "cannot list pull requests (gh pr list): $(first_line "$TMP/gh.err")"
PR_NUM=""; PR_TITLE=""; PR_URL=""
[ ! -s "$TMP/open" ] || IFS="$(printf '\t')" read -r PR_NUM PR_TITLE PR_URL < "$TMP/open"

if [ -n "$PR_NUM" ] && [ "$PR_TITLE" = "$TITLE" ]; then
  done_ok "review kit $LATEST is waiting in sync PR #$PR_NUM ($PR_URL); installed: ${INSTALLED:-${REF:-unknown}}"
fi
if [ -n "$PR_NUM" ]; then
  # Retitling the open PR force-pushes its branch, so only commits this script
  # made may be on it.
  FOREIGN="$(gh pr view "$PR_NUM" --json commits \
    --jq "[.commits[] | select((.messageBody // \"\") | test(\"(^|\\n)$TRAILER: \") | not)] | length" \
    2> "$TMP/gh.err")" || fail "cannot read the commits of sync PR #$PR_NUM: $(first_line "$TMP/gh.err")"
  case "$FOREIGN" in
    0) ;;
    ''|*[!0-9]*) fail "could not count the commits on sync PR #$PR_NUM (gh printed '$FOREIGN')" ;;
    *) fail "sync PR #$PR_NUM carries $FOREIGN commit(s) this sync did not make; updating it to $LATEST would force-push them away — merge or close #$PR_NUM, then re-run" ;;
  esac
else
  gh pr list --head "$BRANCH" --state closed --json number,title,mergedAt \
    --jq ".[] | select(.title == \"$TITLE\" and .mergedAt == null) | .number" > "$TMP/declined" 2> "$TMP/gh.err" \
    || fail "cannot list closed pull requests (gh pr list): $(first_line "$TMP/gh.err")"
  DECLINED="$(head -n1 "$TMP/declined")"
  if [ -n "$DECLINED" ]; then
    done_ok "review kit $LATEST was declined: sync PR #$DECLINED was closed unmerged — reopen it to take $LATEST; the next release opens a new PR"
  fi
fi

REMOTE_OID="$(git ls-remote origin "refs/heads/$BRANCH" 2> "$TMP/git.err")" \
  || fail "cannot read branch $BRANCH on origin: $(first_line "$TMP/git.err")"
REMOTE_OID="$(printf '%s\n' "$REMOTE_OID" | cut -f1)"

# --- sync -------------------------------------------------------------------------
git checkout -q -B "$BRANCH" 2> "$TMP/git.err" || fail "cannot create branch $BRANCH: $(first_line "$TMP/git.err")"
REVIEW_KIT_REF="$LATEST" bash scripts/review-update.sh > "$TMP/update.out" 2>&1; rc=$?
cat "$TMP/update.out" >&2
[ "$rc" = 0 ] || fail "scripts/review-update.sh failed (exit $rc) syncing to $LATEST — its output is above"
GOT="$(sed -n 's/^release: //p' .review/kit-version | head -n1)"
[ "$GOT" = "$LATEST" ] \
  || fail "scripts/review-update.sh exited 0 but .review/kit-version records release '${GOT:-none}', not $LATEST"
STATUS="$(git status --porcelain --untracked-files=all)" || fail "git status failed after the sync"
[ -n "$STATUS" ] \
  || fail "the sync to $LATEST changed nothing, though .review/kit-version said ${INSTALLED:-${REF:-unknown}}"

# --- synced files whose spoke-local edits this sync overwrote ----------------------
# A modified file is a local edit when it differed from the release it was synced
# at; a file new in the release that the repo already tracked was the repo's own.
git -c core.quotePath=false diff --name-only > "$TMP/changed" || fail "cannot list the files the sync changed"
: > "$TMP/edits"
if [ -z "$INSTALLED" ]; then
  EDITS_NOTE="Not checked: the installed kit (\`${REF:-unknown}\`) is not a release, so there is nothing to compare against."
elif ! { git -C "$TMP" init -q hub && git -C "$TMP/hub" fetch -q --depth 1 "$REVIEW_KIT_URL" "refs/tags/$INSTALLED"; } 2> "$TMP/git.err"; then
  EDITS_NOTE="Not checked: cannot fetch $INSTALLED from $REVIEW_KIT_URL ($(first_line "$TMP/git.err"))."
else
  OLD="$(git -C "$TMP/hub" rev-parse 'FETCH_HEAD^{commit}')" || fail "fetched $INSTALLED but cannot resolve it"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$p" != .review/kit-version ] || continue
    git show "HEAD:$p" > "$TMP/mine" 2>/dev/null || continue
    if ! git -C "$TMP/hub" show "$OLD:$p" > "$TMP/theirs" 2>/dev/null; then
      printf -- '- `%s` — not in %s: the repo'"'"'s own file, replaced by the kit'"'"'s\n' "$p" "$INSTALLED" >> "$TMP/edits"
    elif ! cmp -s "$TMP/mine" "$TMP/theirs"; then
      printf -- '- `%s` — edited here since %s\n' "$p" "$INSTALLED" >> "$TMP/edits"
    fi
  done < "$TMP/changed"
  if [ -s "$TMP/edits" ]; then
    EDITS_NOTE="These synced files carried changes made in this repo, which the sync replaced. Move anything worth keeping into the hub or a repo-owned file before merging:"
  else
    EDITS_NOTE="None: every file the sync changed matched $INSTALLED as released."
  fi
fi

# --- release notes for every release skipped over ----------------------------------
NOTES_NOTE=""
if git ls-remote --tags "$REVIEW_KIT_URL" > "$TMP/tags" 2> "$TMP/git.err"; then
  sed -n 's|.*refs/tags/v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$|\1|p' "$TMP/tags" \
    | sort -t. -k1,1nr -k2,2nr -k3,3nr | uniq | sed 's/^/v/' > "$TMP/releases"
else
  NOTES_NOTE="Could not list the hub's tags ($(first_line "$TMP/git.err")); showing $LATEST only."
  echo "$LATEST" > "$TMP/releases"
fi
: > "$TMP/skipped"
while IFS= read -r t; do
  release_older "$LATEST" "$t" && continue
  [ -z "$INSTALLED" ] || release_older "$INSTALLED" "$t" || continue
  echo "$t" >> "$TMP/skipped"
  [ -n "$INSTALLED" ] || break   # nothing to count from: the latest alone
done < "$TMP/releases"
grep -qxF "$LATEST" "$TMP/skipped" || { echo "$LATEST" > "$TMP/skipped"; }

: > "$TMP/upgrading"; : > "$TMP/notes"
while IFS= read -r t; do
  if [ -z "$HUB_REPO" ]; then
    printf '_No notes: %s is not a github.com repo; set REVIEW_KIT_REPO to owner/name._\n' "$REVIEW_KIT_URL" > "$TMP/n"
  elif ! gh release view "$t" -R "$HUB_REPO" --json body --jq .body > "$TMP/n" 2> "$TMP/gh.err"; then
    printf '_No release notes for %s: %s_\n' "$t" "$(first_line "$TMP/gh.err")" > "$TMP/n"
  fi
  printf '### %s\n\n' "$t" >> "$TMP/upgrading"
  if grep -Eq '^##[[:space:]]+Upgrading' "$TMP/n"; then
    awk '/^##[[:space:]]+Upgrading/ {on=1; next} on && /^##[[:space:]]/ {exit} on' "$TMP/n" >> "$TMP/upgrading"
  else
    printf '**%s'"'"'s notes have no `## Upgrading` section** — read them in full below for steps or contract changes.\n' "$t" >> "$TMP/upgrading"
  fi
  printf '\n' >> "$TMP/upgrading"
  { printf '<details><summary>%s release notes</summary>\n\n' "$t"; cat "$TMP/n"; printf '\n</details>\n\n'; } >> "$TMP/notes"
done < "$TMP/skipped"

# --- PR body ---------------------------------------------------------------------
{
  printf '> [!IMPORTANT]\n> Opened by `scripts/review-sync.sh`. It never merges: review and merge it yourself.\n\n'
  printf 'Syncs the review kit from `%s` to **%s**, from `%s`.\n\n' \
    "${INSTALLED:-${REF:-unknown}}" "$LATEST" "$REVIEW_KIT_URL"
  [ -n "$INSTALLED" ] || printf '**The installed kit is not a release.** If it carried hub changes that %s lacks, close this PR.\n\n' "$LATEST"
  printf '## Overwritten local edits\n\n%s\n\n' "$EDITS_NOTE"
  [ ! -s "$TMP/edits" ] || { cat "$TMP/edits"; printf '\n'; }
  printf '## Upgrading: contract changes and steps\n\n'
  printf 'Each skipped release'"'"'s `## Upgrading` section. Repo-owned files (rubric, config, analyzers, consumers of `findings.json`) are never synced: adapt them here, on this branch.\n\n'
  cat "$TMP/upgrading"
  printf '## Release notes\n\n'
  [ -z "$NOTES_NOTE" ] || printf '%s\n\n' "$NOTES_NOTE"
  cat "$TMP/notes"
  printf '## review-update.sh output\n\n```text\n'
  cat "$TMP/update.out"
  printf '```\n'
} > "$TMP/body.md"
if [ "$(( $(wc -c < "$TMP/body.md") ))" -gt "$BODY_MAX" ]; then
  head -c "$BODY_MAX" "$TMP/body.md" > "$TMP/body.cut"
  printf '\n\n_…truncated to fit a PR body; the full notes are on the hub'"'"'s releases page._\n' >> "$TMP/body.cut"
  mv "$TMP/body.cut" "$TMP/body.md"
fi

# --- commit, push, PR ----------------------------------------------------------------
git add -A
ID=()
git config user.email >/dev/null 2>&1 \
  || ID=(-c user.name='github-actions[bot]' -c user.email='41898233+github-actions[bot]@users.noreply.github.com')
git ${ID[@]+"${ID[@]}"} commit -q -m "$TITLE" -m "$TRAILER: $LATEST" 2> "$TMP/git.err" \
  || fail "cannot commit the sync: $(first_line "$TMP/git.err")"
if ! git push -q --force-with-lease="refs/heads/$BRANCH:$REMOTE_OID" origin "HEAD:refs/heads/$BRANCH" 2> "$TMP/git.err"; then
  if grep -Eqi '403|denied|not allowed|protected' "$TMP/git.err"; then
    fail "push to $BRANCH refused — the job needs 'permissions: contents: write' and no branch rule may cover $BRANCH: $(first_line "$TMP/git.err")"
  fi
  fail "push to $BRANCH failed (a push since this run read it is refused too): $(first_line "$TMP/git.err")"
fi
git checkout -q "$BASE" 2>/dev/null || true

if [ -n "$PR_NUM" ]; then
  gh pr edit "$PR_NUM" --title "$TITLE" --body-file "$TMP/body.md" > /dev/null 2> "$TMP/gh.err" \
    || fail "pushed $BRANCH, but cannot update sync PR #$PR_NUM: $(first_line "$TMP/gh.err")"
  done_ok "review kit ${INSTALLED:-${REF:-unknown}} is behind $LATEST: updated sync PR #$PR_NUM ($PR_URL)"
fi
if ! gh pr create --base "$BASE" --head "$BRANCH" --title "$TITLE" --body-file "$TMP/body.md" \
     > "$TMP/pr" 2> "$TMP/gh.err"; then
  if grep -qi 'not permitted to create or approve pull requests' "$TMP/gh.err"; then
    fail "GitHub Actions may not create pull requests here. Tick Settings > Actions > General > Workflow permissions > 'Allow GitHub Actions to create and approve pull requests' (in an organization, tick it under Organization settings > Actions > General first), or set a REVIEW_KIT_SYNC_TOKEN secret. $BRANCH is pushed; the next run opens the PR."
  fi
  if grep -qi 'Resource not accessible by integration' "$TMP/gh.err"; then
    fail "the token cannot create pull requests — the job needs 'permissions: pull-requests: write': $(first_line "$TMP/gh.err")"
  fi
  fail "pushed $BRANCH, but cannot open the sync PR: $(first_line "$TMP/gh.err")"
fi
done_ok "review kit ${INSTALLED:-${REF:-unknown}} is behind $LATEST: opened sync PR $(first_line "$TMP/pr")"
