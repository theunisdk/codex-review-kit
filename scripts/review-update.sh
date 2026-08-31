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
#                          .claude/commands+skill, .codex/skills, .githooks,
#                          .claude-plugin/, REVIEW.md
#   repo-owned (never):    .review/rubric.md, config.sh, learnings.md,
#                          prompts.local/, analyzers.local.sh
#
#   ./scripts/review-update.sh           # sync machinery from the hub
#   ./scripts/review-update.sh --init    # also seed repo-owned files that are
#                                        # missing, from the kit's templates/
#
# Hub resolution order: $REVIEW_KIT_DIR, then the local clone at
# ~/dev/private/codex-review-kit, then a pinned fetch from the public repo:
# its latest release tag, or $REVIEW_KIT_REF (a tag or full commit SHA) —
# never the mutable default branch. Local sources are used as-is (offline
# stays fine), with a warning when a local clone is behind its own origin.
# Every run prints the resolved source and the revision it installs.
# ---------------------------------------------------------------------------
set -euo pipefail

# Everything lives in main() so bash parses the whole script before any file
# is copied — this script overwrites ITSELF during the sync, and an
# interpreter still reading the old file at that moment continues at the same
# byte offset in the new one.
main() {

KIT_GIT_URL="${REVIEW_KIT_URL:-https://github.com/theunisdk/codex-review-kit}"
KIT_REF="${REVIEW_KIT_REF:-}"

INIT=0
[ "${1:-}" = "--init" ] && INIT=1

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: run from inside the repo you want to update" >&2; exit 1; }
cd "$REPO_ROOT"

# --- locate the hub --------------------------------------------------------
TMP_CLONE=""
# the trap's status becomes the script's exit code — must end true
cleanup() { if [ -n "$TMP_CLONE" ]; then rm -rf "$TMP_CLONE"; fi; }
trap cleanup EXIT

# Highest release tag (vN.N…) on the remote, numeric per component so
# v0.10.0 beats v0.9.0. Empty when unreachable or untagged.
latest_tag() {
  git ls-remote --tags "$1" 'v[0-9]*' 2>/dev/null \
    | sed -n 's|.*refs/tags/v\([0-9][0-9.]*\)$|\1|p' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1 | sed 's/^/v/'
}

if [ -n "${REVIEW_KIT_DIR:-}" ] && [ -d "$REVIEW_KIT_DIR" ]; then
  KIT="$REVIEW_KIT_DIR"; KIT_FROM="REVIEW_KIT_DIR"
elif [ -d "$HOME/dev/private/codex-review-kit/scripts" ]; then
  KIT="$HOME/dev/private/codex-review-kit"; KIT_FROM="local clone"
else
  if [ -z "$KIT_REF" ]; then
    KIT_REF="$(latest_tag "$KIT_GIT_URL")" || KIT_REF=""
    [ -n "$KIT_REF" ] || {
      echo "error: no release tag found on $KIT_GIT_URL — check the connection, or set REVIEW_KIT_REF to a tag or full commit SHA" >&2
      exit 1; }
  fi
  TMP_CLONE="$(mktemp -d)"
  echo "no local hub found — fetching $KIT_GIT_URL @ $KIT_REF" >&2
  git -C "$TMP_CLONE" init -q
  git -C "$TMP_CLONE" fetch --quiet --depth 1 "$KIT_GIT_URL" "$KIT_REF" || {
    echo "error: cannot fetch '$KIT_REF' from $KIT_GIT_URL — needs a tag or full commit SHA" >&2
    exit 1; }
  git -C "$TMP_CLONE" checkout --quiet --detach FETCH_HEAD
  KIT="$TMP_CLONE"; KIT_FROM="network"
fi
[ -f "$KIT/scripts/review.sh" ] || {
  echo "error: '$KIT' does not look like the kit (no scripts/review.sh)" >&2; exit 1; }

if [ -n "$TMP_CLONE" ]; then
  KIT_SHOW="$KIT_GIT_URL"
  KIT_DESC="$KIT_REF"
else
  KIT_SHOW="$KIT"
  KIT_DESC="$(git -C "$KIT" describe --tags --always 2>/dev/null || echo unknown)"
  [ -z "$KIT_REF" ] || echo "warn: REVIEW_KIT_REF only applies to network fetches — using $KIT as-is" >&2
  # a stale local clone otherwise delivers stale files under a success message
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
      echo "warn: hub at $KIT is $BEHIND commit(s) behind $UPSTREAM — syncing anyway; 'git -C $KIT pull' first for the latest kit" >&2
    elif [ "$FRESH" = 0 ] || [ -z "$UPSTREAM" ]; then
      echo "note: could not verify hub at $KIT against its origin — it may be stale" >&2
    fi
  fi
fi

KIT_COMMIT="$(git -C "$KIT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "installing from $KIT_SHOW ($KIT_FROM) @ $KIT_DESC ($KIT_COMMIT)" >&2

# --- sync the shared half --------------------------------------------------
mkdir -p scripts/lib .review/prompts .claude/commands .claude/skills \
         .codex/skills .githooks .claude-plugin

cp "$KIT"/scripts/review.sh "$KIT"/scripts/review-install.sh \
   "$KIT"/scripts/review-update.sh "$KIT"/scripts/make-plugin.sh scripts/
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
fi

# --- record what we synced to ----------------------------------------------
printf 'kit: %s %s\nref: %s\nsource: %s\nsynced: %s\n' \
  "$KIT_GIT_URL" "$KIT_COMMIT" "$KIT_DESC" "$KIT_SHOW" "$(date +%Y-%m-%d)" \
  > .review/kit-version

echo "synced from kit @ $KIT_DESC ($KIT_COMMIT) → run scripts/review-install.sh if this is a new machine"

}
main "$@"
