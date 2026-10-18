#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# review-update.sh — pull the shared review-kit machinery into this repo.
#
# The kit lives in one hub (github.com/theunisdk/codex-review-kit).
# This script copies the SHARED half into the current repo, overwriting what is
# there; the REPO-OWNED half is never touched:
#
#   synced (overwritten):  scripts/review*.sh, scripts/make-plugin.sh,
#                          scripts/lib/*.sh, .review/prompts/, schema.json,
#                          adjudication.md, learnings-shared.md, .gitignore,
#                          .claude/commands/, .claude/skills/pre-pr-review/,
#                          .codex/skills/, .githooks/, .claude-plugin/,
#                          REVIEW.md, OPERATING.md
#   generated (rewritten): .review/kit-version — what this run installed
#   repo-owned (never):    .review/rubric.md, config.sh, learnings.md,
#                          prompts.local/, analyzers.local.sh, and the root
#                          .coderabbit.yaml (seeded only when the repo has no
#                          CodeRabbit config in any supported spelling), and
#                          .github/workflows/review-kit-sync.yml (seeded unless
#                          .review/config.sh sets KIT_SYNC_ACTION=0)
#
#   ./scripts/review-update.sh                   # install the latest release
#   ./scripts/review-update.sh --init            # also seed repo-owned files that
#                                                # are missing, from templates/
#   ./scripts/review-update.sh --local           # install a local hub clone's
#                                                # working tree — UNRELEASED
#   ./scripts/review-update.sh --latest-release  # print the latest release tag
#                                                # and exit; installs nothing
#
# By default the kit is fetched from the hub ($REVIEW_KIT_URL, else the public
# repo) at its latest release tag (highest vN.N.N), or at $REVIEW_KIT_REF (a tag
# or full commit SHA) — never a branch, and never a local clone's working tree,
# so a stale or ahead clone cannot ship. If the release cannot be resolved or
# fetched, the run fails; it never installs something else instead.
# --local installs the working tree of $REVIEW_KIT_DIR, else
# ~/dev/private/codex-review-kit, as-is, and records it as unreleased.
# Every run prints the resolved source and the revision it installs.
#
# --latest-release exits 0 with the tag on stdout, 1 when the hub cannot be
# listed, 2 when it lists no release tag. A usage error exits 64.
# ---------------------------------------------------------------------------
set -euo pipefail

# This script overwrites ITSELF during the sync, and bash reads a script file
# as it goes: whatever it reads next comes from the new file at the old byte
# offset. So everything lives in main(), parsed before any file is copied, and
# the call and its exit share the last line — nothing is read after it.
main() {

KIT_GIT_URL="${REVIEW_KIT_URL:-https://github.com/theunisdk/codex-review-kit}"
KIT_REF="${REVIEW_KIT_REF:-}"

# Release tags (strictly vN.N.N) in `git ls-remote --tags` output on stdin,
# highest last, numeric per component so v0.10.0 beats v0.9.0.
release_tags() {
  sed -n 's|.*refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$|\1|p' \
    | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | sed 's/^/v/'
}
latest_tag() { release_tags | tail -n1; }

# TAGS = the hub's tag listing; fails with a message when it cannot be listed.
list_tags() {
  TAGS="$(git ls-remote --tags "$KIT_GIT_URL")" || {
    echo "error: cannot reach $KIT_GIT_URL — check the connection and the URL" >&2
    return 1; }
}

# The highest release tag on commit $1, from $TAGS (an annotated tag counts by
# its ^{} line). Empty when no release tag points there.
release_at() {
  printf '%s\n' "$TAGS" | awk -v want="$1" '
    { n = $2; peeled = sub(/\^\{\}$/, "", n); if (peeled || !(n in c)) c[n] = $1 }
    END { for (n in c) if (c[n] == want) print n }' | latest_tag
}

INIT=0; LOCAL=0
for arg in "$@"; do
  case "$arg" in
    --init)  INIT=1 ;;
    --local) LOCAL=1 ;;
    --latest-release)
      [ "$#" = 1 ] || { echo "error: --latest-release takes no other arguments" >&2; exit 64; }
      list_tags || exit 1
      LATEST="$(printf '%s\n' "$TAGS" | latest_tag)"
      [ -n "$LATEST" ] || { echo "error: no release tag found on $KIT_GIT_URL" >&2; exit 2; }
      echo "$LATEST"; exit 0 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "error: unknown argument '$arg' — see --help" >&2; exit 64 ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: run from inside the repo you want to update" >&2; exit 1; }
cd "$REPO_ROOT"

# --- locate the hub --------------------------------------------------------
TMP_CLONE=""
# the trap's status becomes the script's exit code — must end true
cleanup() { if [ -n "$TMP_CLONE" ]; then rm -rf "$TMP_CLONE"; fi; }
trap cleanup EXIT

LOCAL_HUB="$HOME/dev/private/codex-review-kit"
if [ "$LOCAL" = 1 ]; then
  [ -z "$KIT_REF" ] || {
    echo "error: REVIEW_KIT_REF pins a release fetch and --local installs a working tree — pick one" >&2
    exit 1; }
  if [ -n "${REVIEW_KIT_DIR:-}" ]; then
    [ -d "$REVIEW_KIT_DIR" ] || { echo "error: REVIEW_KIT_DIR '$REVIEW_KIT_DIR' is not a directory" >&2; exit 1; }
    KIT="$REVIEW_KIT_DIR"; KIT_FROM="REVIEW_KIT_DIR, unreleased"
  elif [ -d "$LOCAL_HUB/scripts" ]; then
    KIT="$LOCAL_HUB"; KIT_FROM="local clone, unreleased"
  else
    echo "error: --local found no hub clone — set REVIEW_KIT_DIR, or clone it to $LOCAL_HUB" >&2
    exit 1
  fi
else
  [ -z "${REVIEW_KIT_DIR:-}" ] || {
    echo "error: REVIEW_KIT_DIR is set without --local — pass --local to install that working tree (unreleased), or unset it to install the latest release" >&2
    exit 1; }
  list_tags || exit 1
  if [ -z "$KIT_REF" ]; then
    KIT_REF="$(printf '%s\n' "$TAGS" | latest_tag)"
    [ -n "$KIT_REF" ] || {
      echo "error: no release tag found on $KIT_GIT_URL — set REVIEW_KIT_REF to a tag or full commit SHA" >&2
      exit 1; }
  fi
  # A tag is fetched as the commit listed above (an annotated tag's is its ^{}
  # line), so a tag moved since the listing is not what gets installed.
  if [[ $KIT_REF =~ ^[0-9a-f]{40}$ ]]; then
    FETCH_REF="$KIT_REF"
  else
    FETCH_REF="$(printf '%s\n' "$TAGS" | awk -v t="refs/tags/$KIT_REF" \
      '$2 == t {s=$1} $2 == (t "^{}") {p=$1} END {print (p != "" ? p : s)}')"
  fi
  [ -n "$FETCH_REF" ] || {
    echo "error: '$KIT_REF' is not a tag on $KIT_GIT_URL or a full commit SHA — REVIEW_KIT_REF takes one of those, never a branch" >&2
    exit 1; }
  [ ! -d "$LOCAL_HUB/scripts" ] \
    || echo "note: not using the hub clone at $LOCAL_HUB — --local installs its working tree" >&2
  TMP_CLONE="$(mktemp -d)"
  echo "fetching $KIT_GIT_URL @ $KIT_REF" >&2
  git -C "$TMP_CLONE" init -q
  git -C "$TMP_CLONE" fetch --quiet --depth 1 "$KIT_GIT_URL" "$FETCH_REF" || {
    echo "error: cannot fetch '$KIT_REF' from $KIT_GIT_URL — not on the hub, or the fetch failed" >&2
    exit 1; }
  git -C "$TMP_CLONE" checkout --quiet --detach FETCH_HEAD
  KIT="$TMP_CLONE"; KIT_FROM="release"
  RELEASE="$(release_at "$(git -C "$TMP_CLONE" rev-parse HEAD)")"
  if [ -z "$RELEASE" ]; then
    RELEASE=unreleased; KIT_FROM="pinned, unreleased"
  fi
fi
[ -f "$KIT/scripts/review.sh" ] || {
  echo "error: '$KIT' does not look like the kit (no scripts/review.sh)" >&2; exit 1; }

if [ -n "$TMP_CLONE" ]; then
  KIT_SHOW="$KIT_GIT_URL"
  KIT_DESC="$KIT_REF"
else
  RELEASE=unreleased
  KIT_SHOW="$KIT"
  KIT_DESC="$(git -C "$KIT" describe --tags --always 2>/dev/null || echo unknown)"
  if git -C "$KIT" rev-parse --git-dir >/dev/null 2>&1; then
    FRESH=1
    git -C "$KIT" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 \
      fetch --quiet 2>/dev/null || FRESH=0
    UPSTREAM="$(git -C "$KIT" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" || UPSTREAM=""
    BEHIND=0
    if [ -n "$UPSTREAM" ]; then
      BEHIND="$(git -C "$KIT" rev-list --count "HEAD..$UPSTREAM" 2>/dev/null)" || BEHIND=0
    fi
    if [ "${BEHIND:-0}" -gt 0 ]; then
      echo "warn: hub at $KIT is $BEHIND commit(s) behind $UPSTREAM — installing it anyway, as --local asks" >&2
    elif [ "$FRESH" = 0 ] || [ -z "$UPSTREAM" ]; then
      echo "note: could not verify hub at $KIT against its origin — it may be stale" >&2
    fi
  fi
fi
KIT_COMMIT="$(git -C "$KIT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
# --local installs the hub's WORKING TREE. Uncommitted edits there are
# real content going into this repo, and a bare HEAD in kit-version would name a
# commit that cannot reproduce what was installed. Untracked files count: the
# copies are globs and whole directories, so a new prompt or skill ships too —
# `git diff` alone would call that hub clean. Ignored paths do not count, which
# keeps the kit's own generated review artifacts from marking every hub dirty.
if [ -z "$TMP_CLONE" ] && [ "$KIT_COMMIT" != unknown ] \
   && [ -n "$(git -C "$KIT" status --porcelain --untracked-files=all 2>/dev/null)" ]; then
  KIT_COMMIT="$KIT_COMMIT-dirty"
  KIT_DESC="$KIT_DESC-dirty"
  echo "warn: hub at $KIT has uncommitted changes — installing them; recorded as $KIT_COMMIT" >&2
fi
echo "installing from $KIT_SHOW ($KIT_FROM) @ $KIT_DESC ($KIT_COMMIT)" >&2

# --- sync the shared half --------------------------------------------------
mkdir -p scripts/lib .review/prompts .claude/commands .claude/skills \
         .codex/skills .githooks .claude-plugin

cp "$KIT"/scripts/review.sh "$KIT"/scripts/review-install.sh \
   "$KIT"/scripts/review-update.sh "$KIT"/scripts/make-plugin.sh scripts/
# releases before v1.3.0 have no review-sync.sh, and a pin may name one
if [ -f "$KIT"/scripts/review-sync.sh ]; then
  cp "$KIT"/scripts/review-sync.sh scripts/
  chmod +x scripts/review-sync.sh
fi
cp "$KIT"/scripts/lib/*.sh scripts/lib/
cp "$KIT"/.review/prompts/*.md .review/prompts/
cp "$KIT"/.review/schema.json "$KIT"/.review/adjudication.md \
   "$KIT"/.review/.gitignore .review/
cp "$KIT"/.review/learnings-shared.md .review/
cp "$KIT"/.claude/commands/*.md .claude/commands/
cp -R "$KIT"/.claude/skills/pre-pr-review .claude/skills/
cp -R "$KIT"/.codex/skills/. .codex/skills/
cp "$KIT"/.githooks/pre-push .githooks/
cp "$KIT"/.claude-plugin/*.json .claude-plugin/
cp "$KIT"/REVIEW.md "$KIT"/OPERATING.md .
chmod +x scripts/review.sh scripts/review-install.sh scripts/review-update.sh \
         scripts/make-plugin.sh .githooks/pre-push

# --- seed repo-owned files on --init ---------------------------------------
if [ "$INIT" = 1 ]; then
  mkdir -p .review/prompts.local
  for f in rubric.md config.sh learnings.md; do
    [ -f ".review/$f" ] || cp "$KIT/templates/$f" ".review/$f"
  done
  [ -f .review/analyzers.local.sh ] || cp "$KIT/templates/analyzers.local.sh" .review/
  [ -f .review/prompts.local/README.md ] || cp "$KIT/templates/prompts.local/README.md" .review/prompts.local/
  # CodeRabbit resolves a single config source, and YAML in either spelling
  # outranks .coderabbit.config.ts — so a file seeded next to an existing one
  # would quietly take over the gate. Only seed a repo that configures nothing.
  # The two undotted names are not in CodeRabbit's documented discovery order;
  # they are checked anyway because the costs are lopsided — skipping a repo
  # that needed seeding is visible, overriding a live gate config is not.
  seed_gate=1
  for f in .coderabbit.yaml .coderabbit.yml .coderabbit.config.ts \
           coderabbit.yaml coderabbit.yml; do
    [ -f "$f" ] && { seed_gate=0; break; }
  done
  [ "$seed_gate" = 1 ] && cp "$KIT/templates/coderabbit.yaml" .coderabbit.yaml

  # The weekly job that opens a PR for each new release. The schedule is spread
  # by repo name, so one release does not open every spoke's PR at once.
  wf=.github/workflows/review-kit-sync.yml
  sync_opt="$( (set +eu; bash -n ./.review/config.sh 2>/dev/null || exit 1; . ./.review/config.sh >/dev/null 2>&1; printf '%s' "${KIT_SYNC_ACTION:-1}") )" || sync_opt=""
  slug="$(git remote get-url origin 2>/dev/null \
    | sed -E 's#/+$##; s#\.git$##; s#^.*[:/]([^/:]+/[^/:]+)$#\1#')" || slug=""
  [ -n "$slug" ] || slug="$(basename "$REPO_ROOT")"
  n="$(printf '%s' "$slug" | cksum | cut -d' ' -f1)"
  cron="$((n % 60)) $((n / 60 % 24)) * * $((n / 1440 % 7))"
  if [ "$sync_opt" = 0 ]; then
    echo "note: $wf not seeded — .review/config.sh sets KIT_SYNC_ACTION=0" >&2
  elif [ ! -f "$KIT/templates/review-kit-sync.yml" ]; then
    echo "note: $wf not seeded — kit $KIT_DESC has no templates/review-kit-sync.yml" >&2
  elif [ -z "$sync_opt" ]; then
    echo "warn: $wf not seeded — .review/config.sh could not be read to check KIT_SYNC_ACTION" >&2
  elif [ ! -e "$wf" ]; then
    mkdir -p .github/workflows
    sed "s|@CRON@|$cron|" "$KIT/templates/review-kit-sync.yml" > "$wf.tmp"
    mv "$wf.tmp" "$wf"
    echo "seeded $wf (weekly, cron '$cron') — opt out with KIT_SYNC_ACTION=0 in .review/config.sh" >&2
  elif ! sed "s|@CRON@|$cron|" "$KIT/templates/review-kit-sync.yml" | cmp -s - "$wf"; then
    echo "note: kept $wf — it differs from the kit's template (templates/review-kit-sync.yml); delete it and re-run --init to take the template" >&2
  fi
fi

# --- record what we synced to ----------------------------------------------
# release: is the vN.N.N tag on the installed commit, or `unreleased`.
printf 'kit: %s %s\nref: %s\nrelease: %s\nsource: %s\nsynced: %s\n' \
  "$KIT_GIT_URL" "$KIT_COMMIT" "$KIT_DESC" "$RELEASE" "$KIT_SHOW" "$(date +%Y-%m-%d)" \
  > .review/kit-version

echo "synced from kit @ $KIT_DESC ($KIT_COMMIT, $RELEASE) → run scripts/review-install.sh if this is a new machine"

}
main "$@"; exit $?
