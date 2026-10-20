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
# or enables auto-merge: a sync PR always waits for a human. The PR body carries
# `@coderabbitai ignore`: the hub's CodeRabbit already reviewed the kit.
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

# The sync below overwrites THIS file, and bash reads a script as it goes: what
# it reads next would come from the new release at the old byte offset. So
# everything lives in main(), parsed before any file is copied, and the call
# and its exit share the last line.
main() {

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
DEFAULT="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2> "$TMP/gh.err")" \
  || fail "cannot read the default branch (gh repo view): $(first_line "$TMP/gh.err")"
[ -n "$DEFAULT" ] || fail "gh repo view printed no default branch"
[ "$BASE" = "$DEFAULT" ] || fail "run from the default branch $DEFAULT, not $BASE"

# --- the one sync PR -----------------------------------------------------------
# A fork can name its branch review-kit-sync too; only this repo's branch counts.
gh pr list --head "$BRANCH" --state open --json number,title,url,isCrossRepository \
  --jq '.[] | select(.isCrossRepository | not) | "\(.number)\t\(.title)\t\(.url)"' > "$TMP/open" 2> "$TMP/gh.err" \
  || fail "cannot list pull requests (gh pr list): $(first_line "$TMP/gh.err")"
PR_NUM=""; PR_TITLE=""; PR_URL=""
[ ! -s "$TMP/open" ] || IFS="$(printf '\t')" read -r PR_NUM PR_TITLE PR_URL < "$TMP/open"

if [ -n "$PR_NUM" ] && [ "$PR_TITLE" = "$TITLE" ]; then
  done_ok "review kit $LATEST is waiting in sync PR #$PR_NUM ($PR_URL); installed: ${INSTALLED:-${REF:-unknown}}"
fi
if [ -n "$PR_NUM" ]; then
  # Retitling the open PR force-pushes its branch, so only commits this script
  # made may be on it — and the push leases the head that was checked.
  gh pr view "$PR_NUM" --json headRefOid,commits \
    --jq "\"\\(.headRefOid) \\([.commits[] | select((.messageBody // \"\") | test(\"(^|\\n)$TRAILER: \") | not)] | length)\"" \
    > "$TMP/head" 2> "$TMP/gh.err" || fail "cannot read the commits of sync PR #$PR_NUM: $(first_line "$TMP/gh.err")"
  read -r LEASE FOREIGN < "$TMP/head"
  printf '%s\n' "$LEASE" | grep -Eqx '[0-9a-f]{40}([0-9a-f]{24})?' \
    || fail "could not read the head of sync PR #$PR_NUM (gh printed '$(first_line "$TMP/head")')"
  case "$FOREIGN" in
    0) ;;
    ''|*[!0-9]*) fail "could not count the commits on sync PR #$PR_NUM (gh printed '$FOREIGN')" ;;
    *) fail "sync PR #$PR_NUM carries $FOREIGN commit(s) this sync did not make; updating it to $LATEST would force-push them away — merge or close #$PR_NUM, then re-run" ;;
  esac
else
  gh pr list --head "$BRANCH" --state closed --json number,title,mergedAt,isCrossRepository \
    --jq ".[] | select((.isCrossRepository | not) and .title == \"$TITLE\" and .mergedAt == null) | .number" \
    > "$TMP/declined" 2> "$TMP/gh.err" \
    || fail "cannot list closed pull requests (gh pr list): $(first_line "$TMP/gh.err")"
  DECLINED="$(head -n1 "$TMP/declined")"
  if [ -n "$DECLINED" ]; then
    done_ok "review kit $LATEST was declined: sync PR #$DECLINED was closed unmerged — reopen it to take $LATEST; the next release opens a new PR"
  fi

  # No open PR: a branch already on origin is overwritten only when its tip is a
  # sync commit (left by a closed PR, or a run whose PR creation failed).
  LEASE="$(git ls-remote origin "refs/heads/$BRANCH" 2> "$TMP/git.err")" \
    || fail "cannot read branch $BRANCH on origin: $(first_line "$TMP/git.err")"
  if [ -n "$LEASE" ]; then
    DEPTH=(); [ "$(git rev-parse --is-shallow-repository)" != true ] || DEPTH=(--depth 1)
    git fetch -q ${DEPTH[@]+"${DEPTH[@]}"} origin "refs/heads/$BRANCH" 2> "$TMP/git.err" \
      || fail "cannot fetch branch $BRANCH from origin: $(first_line "$TMP/git.err")"
    LEASE="$(git rev-parse FETCH_HEAD)" || fail "fetched $BRANCH but cannot resolve it"
    git log -1 --format=%B FETCH_HEAD | grep -q "^$TRAILER: " \
      || fail "branch $BRANCH is on origin with no open sync PR, and its tip is not a sync commit — delete or rename it, then re-run"
  fi
fi

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
# The updater that ran is this repo's older copy, which knows only the files it copies.
UPDATER_CHANGED=0
NEW_UPDATER="$(git hash-object scripts/review-update.sh)" || fail "cannot hash scripts/review-update.sh after the sync"
[ "$NEW_UPDATER" = "$(git rev-parse -q --verify HEAD:scripts/review-update.sh)" ] || UPDATER_CHANGED=1

# A lookup that fails now would leave a PR missing its notes for good: the next
# run finds it open under the latest title and leaves it be. So they fail.
git ls-remote --tags "$REVIEW_KIT_URL" > "$TMP/tags" 2> "$TMP/git.err" \
  || fail "cannot list the hub's tags for the release notes: $(first_line "$TMP/git.err")"
sed -n 's|.*refs/tags/v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$|\1|p' "$TMP/tags" \
  | sort -t. -k1,1nr -k2,2nr -k3,3nr | uniq | sed 's/^/v/' > "$TMP/releases"

# --- synced files whose spoke-local edits this sync overwrote ----------------------
# A modified file is a local edit when it differed from the release it was synced
# at; a file new in the release that the repo already tracked was the repo's own.
git add -A || fail "cannot stage the sync"
git -c core.quotePath=false diff --cached --name-status --no-renames > "$TMP/changed" \
  || fail "cannot list the files the sync changed"
: > "$TMP/edits"
if [ -z "$INSTALLED" ]; then
  EDITS_NOTE="Not checked: the installed kit (\`${REF:-unknown}\`) is not a release, so there is nothing to compare against."
elif ! grep -qxF "$INSTALLED" "$TMP/releases"; then
  EDITS_NOTE="Not checked: $INSTALLED is no longer a tag on $REVIEW_KIT_URL, so there is nothing to compare against."
else
  { git -C "$TMP" init -q hub && git -C "$TMP/hub" fetch -q --depth 1 "$REVIEW_KIT_URL" "refs/tags/$INSTALLED"; } 2> "$TMP/git.err" \
    || fail "cannot fetch $INSTALLED from $REVIEW_KIT_URL to check for overwritten local edits: $(first_line "$TMP/git.err")"
  OLD="$(git -C "$TMP/hub" rev-parse 'FETCH_HEAD^{commit}')" || fail "fetched $INSTALLED but cannot resolve it"
  while IFS="$(printf '\t')" read -r st p; do
    [ -n "$p" ] || continue
    [ "$p" != .review/kit-version ] || continue
    IN_OLD="$(git -C "$TMP/hub" ls-tree --name-only "$OLD" -- "$p")" || fail "cannot look up $p in $INSTALLED"
    case "$st" in
      A) [ -z "$IN_OLD" ] \
           || printf -- '- `%s` — deleted here since %s; the sync restores it\n' "$p" "$INSTALLED" >> "$TMP/edits" ;;
      M|T)
        if [ -z "$IN_OLD" ]; then
          printf -- '- `%s` — not in %s: the repo'"'"'s own file, replaced by the kit'"'"'s\n' "$p" "$INSTALLED" >> "$TMP/edits"
          continue
        fi
        git show "HEAD:$p" > "$TMP/mine" 2>/dev/null || fail "cannot read $p as committed"
        git -C "$TMP/hub" show "$OLD:$p" > "$TMP/theirs" 2>/dev/null || fail "cannot read $p in $INSTALLED"
        cmp -s "$TMP/mine" "$TMP/theirs"; c=$?
        case "$c" in
          0) ;;
          1) printf -- '- `%s` — edited here since %s\n' "$p" "$INSTALLED" >> "$TMP/edits" ;;
          *) fail "cannot compare $p with $INSTALLED (cmp exit $c)" ;;
        esac ;;
    esac
  done < "$TMP/changed"
  if [ -s "$TMP/edits" ]; then
    EDITS_NOTE="These synced files carried changes made in this repo, which the sync replaced. Move anything worth keeping into the hub or a repo-owned file before merging:"
  else
    EDITS_NOTE="None: every file the sync changed matched $INSTALLED as released."
  fi
fi

# --- release notes for every release skipped over ----------------------------------
: > "$TMP/skipped"
while IFS= read -r t; do
  release_older "$LATEST" "$t" && continue
  [ -z "$INSTALLED" ] || release_older "$INSTALLED" "$t" || continue
  echo "$t" >> "$TMP/skipped"
  [ -n "$INSTALLED" ] || break   # nothing to count from: the latest alone
done < "$TMP/releases"
grep -qxF "$LATEST" "$TMP/skipped" || { echo "$LATEST" > "$TMP/skipped"; }

: > "$TMP/upgrading"; : > "$TMP/notes"; : > "$TMP/links"
while IFS= read -r t; do
  if [ -z "$HUB_REPO" ]; then
    printf '_No notes: %s is not a github.com repo; set REVIEW_KIT_REPO to owner/name._\n' "$REVIEW_KIT_URL" > "$TMP/n"
  elif ! gh release view "$t" -R "$HUB_REPO" --json body --jq .body > "$TMP/n" 2> "$TMP/gh.err"; then
    grep -qi 'release not found' "$TMP/gh.err" \
      || fail "cannot read the release notes for $t from $HUB_REPO: $(first_line "$TMP/gh.err")"
    printf '_%s is a tag with no GitHub release, so it has no notes._\n' "$t" > "$TMP/n"
  fi
  printf '### %s\n\n' "$t" >> "$TMP/upgrading"
  if grep -Eq '^##[[:space:]]+Upgrading' "$TMP/n"; then
    awk '/^##[[:space:]]+Upgrading/ {on=1; next} on && /^##[[:space:]]/ {exit} on' "$TMP/n" >> "$TMP/upgrading"
  else
    printf '**%s'"'"'s notes have no `## Upgrading` section** — read them in full below for steps or contract changes.\n' "$t" >> "$TMP/upgrading"
  fi
  printf '\n' >> "$TMP/upgrading"
  { printf '<details><summary>%s release notes</summary>\n\n' "$t"; cat "$TMP/n"; printf '\n</details>\n\n'; } >> "$TMP/notes"
  if [ -n "$HUB_REPO" ]; then
    printf -- '- [%s](https://github.com/%s/releases/tag/%s)\n' "$t" "$HUB_REPO" "$t" >> "$TMP/links"
  fi
done < "$TMP/skipped"

# --- PR body ---------------------------------------------------------------------
cp "$TMP/update.out" "$TMP/output"
body() {
{
  printf '> [!IMPORTANT]\n> Opened by `scripts/review-sync.sh`. It never merges: review and merge it yourself.\n\n'
  printf 'CodeRabbit skips this PR: its synced files were reviewed in the hub PRs that shipped them, though against the hub'"'"'s path instructions, not this repo'"'"'s, so your review is the remaining check. Commits you push here are skipped too. To have CodeRabbit review it, delete the line below, then comment `@coderabbitai review`; the next release'"'"'s update of this PR adds it back.\n\n@coderabbitai ignore\n\n'
  printf 'Syncs the review kit from `%s` to **%s**, from `%s`.\n\n' \
    "${INSTALLED:-${REF:-unknown}}" "$LATEST" "$REVIEW_KIT_URL"
  [ -n "$INSTALLED" ] || printf '**The installed kit is not a release.** If it carried hub changes that %s lacks, close this PR.\n\n' "$LATEST"
  [ "$UPDATER_CHANGED" = 0 ] || printf '**%s changes `scripts/review-update.sh`.** The sync ran the older copy, which installs only the files it knows of. Before merging, check out this branch, run `REVIEW_KIT_REF=%s bash scripts/review-update.sh` once more, and push anything it changes.\n\n' "$LATEST" "$LATEST"
  printf '## Overwritten local edits\n\n%s\n\n' "$EDITS_NOTE"
  [ ! -s "$TMP/edits" ] || { cat "$TMP/edits"; printf '\n'; }
  printf '## Upgrading: contract changes and steps\n\n'
  printf 'Each skipped release'"'"'s `## Upgrading` section. Repo-owned files (rubric, config, analyzers, consumers of `findings.json`) are never synced: adapt them here, on this branch.\n\n'
  cat "$TMP/upgrading"
  printf '## Release notes\n\n'
  cat "$TMP/notes"
  printf '## review-update.sh output\n\n```text\n'
  cat "$TMP/output"
  printf '```\n'
} > "$TMP/body.md"
}
too_long() { [ "$(( $(wc -c < "$TMP/body.md") ))" -gt "$BODY_MAX" ]; }
body
if too_long; then
  { printf '_The full notes are too long for a PR body; read them on the hub:_\n\n'; cat "$TMP/links"; printf '\n'; } > "$TMP/notes"
  body
fi
if too_long; then
  { printf '(too long for a PR body; the last 40 lines)\n'; tail -n 40 "$TMP/update.out"; } > "$TMP/output"
  body
fi
too_long && fail "the PR body is over $BODY_MAX bytes even without the release notes — the Upgrading sections alone are too long"

# --- commit, push, PR ----------------------------------------------------------------
ID=()
git config user.email >/dev/null 2>&1 \
  || ID=(-c user.name='github-actions[bot]' -c user.email='41898233+github-actions[bot]@users.noreply.github.com')
git ${ID[@]+"${ID[@]}"} commit -q -m "$TITLE" -m "$TRAILER: $LATEST" 2> "$TMP/git.err" \
  || fail "cannot commit the sync: $(first_line "$TMP/git.err")"
if ! git push -q --force-with-lease="refs/heads/$BRANCH:$LEASE" origin "HEAD:refs/heads/$BRANCH" 2> "$TMP/git.err"; then
  # with -q the first line is "To <url>"; the reason is on the rejection or remote line
  WHY="$(grep -m1 -E '^ ! \[|^(remote|fatal|error): *[^ ]' "$TMP/git.err" | cut -c1-300)"
  [ -n "$WHY" ] || WHY="$(first_line "$TMP/git.err")"
  if grep -qi 'without .workflows. permission' "$TMP/git.err"; then
    fail "push to $BRANCH refused: it would move the branch across a workflow change on $BASE, which the token may not do. Delete $BRANCH on origin (it closes any sync PR) so the next run starts it fresh, or give REVIEW_KIT_SYNC_TOKEN Workflows write: $WHY"
  fi
  if grep -Eqi '403|denied|not allowed|protected' "$TMP/git.err"; then
    fail "push to $BRANCH refused — the job needs 'permissions: contents: write' and no branch rule may cover $BRANCH: $WHY"
  fi
  fail "push to $BRANCH failed (a push since this run read it is refused too): $WHY"
fi
git checkout -q "$BASE" 2>/dev/null || true

if [ -n "$PR_NUM" ]; then
  gh pr edit "$PR_NUM" --base "$BASE" --title "$TITLE" --body-file "$TMP/body.md" > /dev/null 2> "$TMP/gh.err" \
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

}
main "$@"; exit $?
