#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# review-test.sh — regression tests for scripts/review.sh.
#
# Drives the real script end-to-end inside a throwaway git repo, with a
# stubbed `codex` on PATH — no network, no Codex login, no real lenses.
# Each test builds a fresh fixture repo with the kit installed, points the
# stub at per-lens fixtures, and asserts on the report the run leaves behind.
#
#   ./tests/review-test.sh
#
# Exit codes: 0 all passed · 1 at least one assertion failed
# ---------------------------------------------------------------------------
set -uo pipefail

KIT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
pass() { printf 'ok   - %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf 'FAIL - %s\n' "$*"; }
assert()     { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
assert_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }

# --- codex stub ------------------------------------------------------------
# Writes $CODEX_STUB_DIR/<lens>.json to the -o path and exits with the code
# in $CODEX_STUB_DIR/<lens>.rc (default 0). `codex login status` succeeds.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/codex" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "login" ] && exit 0
out=""
while [ $# -gt 0 ]; do
  [ "$1" = "-o" ] && { out="$2"; shift; }
  shift
done
lens="$(basename "$out" .json)"; lens="${lens#out-}"
[ -n "$out" ] && [ -f "$CODEX_STUB_DIR/$lens.json" ] && cp "$CODEX_STUB_DIR/$lens.json" "$out"
rc=0
[ -f "$CODEX_STUB_DIR/$lens.rc" ] && rc="$(cat "$CODEX_STUB_DIR/$lens.rc")"
exit "$rc"
EOF
chmod +x "$WORK/bin/codex"

# --- fixture helpers -------------------------------------------------------
make_repo() { # make_repo <dir> — kit installed, one commit on main, branch `change` checked out
  local dir="$1"
  git init -q -b main "$dir"
  (
    cd "$dir" || exit 1
    git config user.email review-test@example.invalid
    git config user.name review-test
    mkdir -p scripts/lib .review/prompts .review/raw
    cp "$KIT/scripts/review.sh" scripts/
    cp "$KIT/scripts/lib/common.sh" scripts/lib/
    cp "$KIT/.review/schema.json" .review/
    cp "$KIT/.review/prompts/_common.md" "$KIT/.review/prompts/correctness.md" \
       "$KIT/.review/prompts/security.md" .review/prompts/
    printf 'house rules\n' > .review/rubric.md
    printf 'seed\n' > .review/findings.md
    printf 'seed\n' > .review/raw/seed.txt
    printf 'seed\n' > src.txt
    git add -A && git commit -qm base && git checkout -qb change
  )
}

finding() { # finding <title> — one schema-shaped, above-threshold finding
  printf '{"findings":[{"file":"src.txt","line_start":1,"line_end":1,"severity":"high","category":"correctness","title":"%s","why_it_matters":"stub","evidence":"stub","suggested_fix":"stub","confidence":0.9}]}' "$1"
}

LOG=""
run_review() { # run_review <dir> <stubdir> <review.sh args...>; output in $LOG
  local dir="$1" stub="$2"; shift 2
  LOG="$dir.log"
  (
    cd "$dir" && PATH="$WORK/bin:$PATH" CODEX_STUB_DIR="$stub" \
      REVIEW_SKIP_AUTH_CHECK=1 bash scripts/review.sh --no-analyzers "$@" main
  ) > "$LOG" 2>&1
}

# --- tests -----------------------------------------------------------------
assert "review.sh parses (bash -n)" bash -n "$KIT/scripts/review.sh"

# A branch changing only tracked .review/ sources must still be reviewed:
# those files are review INPUTS (rubric, prompts, config). Only the kit's
# generated artifacts stay excluded. Regression for the filter that dropped
# ^.review/ wholesale and made rubric-only branches take the zero-change
# exit with complete:true.
test_tracked_review_sources_survive_filter() {
  local repo="$WORK/t1" stub="$WORK/t1-stub"
  make_repo "$repo"; mkdir -p "$stub"
  printf '{"findings":[]}' > "$stub/correctness.json"
  (
    cd "$repo" || exit 1
    printf 'updated rule\n' >> .review/rubric.md
    printf 'stale\n' >> .review/findings.md
    printf 'junk\n' >> .review/raw/seed.txt
    git add -A && git commit -qm 'change review sources and artifacts'
  )
  run_review "$repo" "$stub" --lenses correctness; local rc=$?

  assert    "t1: run exits 0" test "$rc" -eq 0
  assert_not "t1: zero-change early exit not taken" grep -q 'no changes to review' "$LOG"
  assert    "t1: rubric survives the filter" grep -qxF '.review/rubric.md' "$repo/.review/raw/changed-files.txt"
  assert_not "t1: generated findings.md still filtered" grep -qxF '.review/findings.md' "$repo/.review/raw/changed-files.txt"
  assert_not "t1: generated raw/ still filtered" grep -qE '^\.review/raw/' "$repo/.review/raw/changed-files.txt"
  assert    "t1: lens launched" test -f "$repo/.review/raw/log-correctness.txt"
  assert    "t1: clean run reports complete:true" jq -e '.complete == true' "$repo/.review/findings.json"
}

# A lens that leaves valid JSON but exits nonzero (timeout kill, salvaged
# truncated output) did not finish its review. Its findings are kept, but it
# must land in lenses_failed and force complete:false — this is the case
# where the report otherwise asserts something false.
test_nonzero_rc_lens_marked_failed() {
  local repo="$WORK/t2" stub="$WORK/t2-stub"
  make_repo "$repo"; mkdir -p "$stub"
  finding 'clean lens finding'  > "$stub/correctness.json"
  finding 'failed lens finding' > "$stub/security.json"
  printf '42\n' > "$stub/security.rc"
  (
    cd "$repo" || exit 1
    printf 'change\n' >> src.txt
    git add -A && git commit -qm 'source change'
  )
  run_review "$repo" "$stub" --lenses correctness,security; local rc=$?

  assert "t2: run exits 0" test "$rc" -eq 0
  assert "t2: nonzero-rc lens in lenses_failed" jq -e '.lenses_failed == ["security"]' "$repo/.review/findings.json"
  assert "t2: complete is false" jq -e '.complete == false' "$repo/.review/findings.json"
  assert "t2: failed lens findings retained" \
    jq -e '[.findings[] | select(.title == "failed lens finding")] | length == 1' "$repo/.review/findings.json"
  assert "t2: clean lens findings retained" \
    jq -e '[.findings[] | select(.title == "clean lens finding")] | length == 1' "$repo/.review/findings.json"
}

# Every lens crashing WITH parseable output must still reach the merge and
# report its findings — failed-but-salvaged gates completeness, not the
# every-lens-failed abort.
test_all_lenses_failed_with_output_still_merges() {
  local repo="$WORK/t3" stub="$WORK/t3-stub"
  make_repo "$repo"; mkdir -p "$stub"
  finding 'salvaged finding' > "$stub/security.json"
  printf '42\n' > "$stub/security.rc"
  (
    cd "$repo" || exit 1
    printf 'change\n' >> src.txt
    git add -A && git commit -qm 'source change'
  )
  run_review "$repo" "$stub" --lenses security; local rc=$?

  assert     "t3: run exits 0" test "$rc" -eq 0
  assert_not "t3: every-lens-failed abort not taken" grep -q 'every lens failed' "$LOG"
  assert     "t3: findings retained" \
    jq -e '[.findings[] | select(.title == "salvaged finding")] | length == 1' "$repo/.review/findings.json"
  assert     "t3: complete is false" jq -e '.complete == false' "$repo/.review/findings.json"
  assert     "t3: lens in lenses_failed" jq -e '.lenses_failed == ["security"]' "$repo/.review/findings.json"
}

# --- updater fixtures ------------------------------------------------------
make_hub() { # make_hub <dir> — minimal kit tree, one commit, no tags
  local dir="$1"
  git init -q -b main "$dir"
  (
    cd "$dir" || exit 1
    git config user.email review-test@example.invalid
    git config user.name review-test
    mkdir -p scripts/lib .review/prompts .claude/commands .claude/skills \
             .codex/skills .githooks .claude-plugin
    cp "$KIT"/scripts/review.sh "$KIT"/scripts/review-install.sh \
       "$KIT"/scripts/review-update.sh "$KIT"/scripts/make-plugin.sh scripts/
    cp "$KIT"/scripts/lib/*.sh scripts/lib/
    cp "$KIT"/.review/prompts/_common.md .review/prompts/
    cp "$KIT"/.review/schema.json "$KIT"/.review/adjudication.md \
       "$KIT"/.review/.gitignore "$KIT"/.review/learnings-shared.md .review/
    cp "$KIT"/.claude/commands/review.md .claude/commands/
    cp -R "$KIT"/.claude/skills/pre-pr-review .claude/skills/
    cp -R "$KIT"/.codex/skills/. .codex/skills/
    cp "$KIT"/.githooks/pre-push .githooks/
    cp "$KIT"/.claude-plugin/*.json .claude-plugin/
    cp "$KIT"/REVIEW.md "$KIT"/OPERATING.md .
    git add -A && git commit -qm kit-base
  )
}

make_spoke() { git init -q -b main "$1"; }

run_update() { # run_update <spoke> [VAR=val ...] — output in $LOG
  local dir="$1"; shift
  LOG="$dir.log"
  mkdir -p "$WORK/nohome"
  ( cd "$dir" && env -i HOME="$WORK/nohome" PATH="$PATH" "$@" \
      bash "$KIT/scripts/review-update.sh" ) > "$LOG" 2>&1
}

# --- updater tests ---------------------------------------------------------
assert "review-update.sh parses (bash -n)" bash -n "$KIT/scripts/review-update.sh"

# Every run must say WHERE it installed from — resolved source and revision —
# and kit-version must record a ref and source, not just a short SHA.
# Regression for the sync that reported only a short commit at the end.
test_update_reports_source_and_revision() {
  local spoke="$WORK/u1-spoke"
  make_spoke "$spoke"
  run_update "$spoke" REVIEW_KIT_DIR="$KIT"; local rc=$?

  assert "u1: run exits 0" test "$rc" -eq 0
  assert "u1: resolved source printed" grep -F "installing from $KIT" "$LOG"
  assert "u1: files synced" test -x "$spoke/scripts/review.sh"
  assert "u1: kit-version records a ref" grep -q '^ref: ..*' "$spoke/.review/kit-version"
  assert "u1: kit-version records the source" grep -qF "source: $KIT" "$spoke/.review/kit-version"
}

# With no local hub, the fetch must pin to the highest release tag — never the
# default branch tip. v0.10.0 vs v0.9.0 also guards the numeric tag sort.
# Regression for the unpinned `git clone --depth 1` of the default branch.
test_update_network_pins_to_latest_tag() {
  local hub="$WORK/u2-hub" spoke="$WORK/u2-spoke"
  make_hub "$hub"
  (
    cd "$hub" || exit 1
    printf 'MARKER: nine\n' >> REVIEW.md && git commit -aqm nine && git tag v0.9.0
    printf 'MARKER: ten\n'  >> REVIEW.md && git commit -aqm ten  && git tag v0.10.0
    printf 'MARKER: tip\n'  >> REVIEW.md && git commit -aqm tip
  )
  make_spoke "$spoke"
  run_update "$spoke" REVIEW_KIT_URL="file://$hub"; local rc=$?

  assert     "u2: run exits 0" test "$rc" -eq 0
  assert     "u2: latest tag content installed" grep -q 'MARKER: ten' "$spoke/REVIEW.md"
  assert_not "u2: branch tip content NOT installed" grep -q 'MARKER: tip' "$spoke/REVIEW.md"
  assert     "u2: kit-version records the tag" grep -q '^ref: v0\.10\.0$' "$spoke/.review/kit-version"
  assert     "u2: pinned revision printed" grep -q 'v0\.10\.0' "$LOG"
}

# REVIEW_KIT_REF overrides tag discovery with an explicit pin.
test_update_network_honors_explicit_ref() {
  local hub="$WORK/u3-hub" spoke="$WORK/u3-spoke"
  make_hub "$hub"
  (
    cd "$hub" || exit 1
    printf 'MARKER: nine\n' >> REVIEW.md && git commit -aqm nine && git tag v0.9.0
    printf 'MARKER: ten\n'  >> REVIEW.md && git commit -aqm ten  && git tag v0.10.0
  )
  make_spoke "$spoke"
  run_update "$spoke" REVIEW_KIT_URL="file://$hub" REVIEW_KIT_REF=v0.9.0; local rc=$?

  assert     "u3: run exits 0" test "$rc" -eq 0
  assert     "u3: pinned tag content installed" grep -q 'MARKER: nine' "$spoke/REVIEW.md"
  assert_not "u3: later content NOT installed" grep -q 'MARKER: ten' "$spoke/REVIEW.md"
  assert     "u3: kit-version records the pin" grep -q '^ref: v0\.9\.0$' "$spoke/.review/kit-version"
}

# A remote with no release tag and no explicit ref must refuse, not silently
# take whatever the default branch points at.
test_update_network_refuses_without_pin() {
  local hub="$WORK/u4-hub" spoke="$WORK/u4-spoke"
  make_hub "$hub"
  make_spoke "$spoke"
  run_update "$spoke" REVIEW_KIT_URL="file://$hub"; local rc=$?

  assert     "u4: run refuses" test "$rc" -ne 0
  assert     "u4: refusal names the fix" grep -q 'REVIEW_KIT_REF' "$LOG"
  assert_not "u4: nothing synced" test -f "$spoke/.review/kit-version"
}

# A local hub clone that is behind its own origin must warn — a stale clone
# silently winning over the network is the failure mode from the issue.
test_update_warns_on_stale_local_clone() {
  local origin="$WORK/u5-origin" clone="$WORK/u5-clone" spoke="$WORK/u5-spoke"
  make_hub "$origin"
  git clone -q "$origin" "$clone"
  make_spoke "$spoke"

  run_update "$spoke" REVIEW_KIT_DIR="$clone"; local rc=$?
  assert     "u5: fresh clone exits 0" test "$rc" -eq 0
  assert_not "u5: fresh clone does not warn" grep -q 'behind' "$LOG"

  ( cd "$origin" && printf 'MARKER: ahead\n' >> REVIEW.md && git commit -aqm ahead )
  run_update "$spoke" REVIEW_KIT_DIR="$clone"; rc=$?
  assert "u5: stale clone still exits 0" test "$rc" -eq 0
  assert "u5: stale clone warns it is behind" grep -q 'behind' "$LOG"
}

test_tracked_review_sources_survive_filter
test_nonzero_rc_lens_marked_failed
test_all_lenses_failed_with_output_still_merges
test_update_reports_source_and_revision
test_update_network_pins_to_latest_tag
test_update_network_honors_explicit_ref
test_update_network_refuses_without_pin
test_update_warns_on_stale_local_clone

echo
if [ "$FAILURES" -gt 0 ]; then
  printf '%d assertion(s) FAILED\n' "$FAILURES"; exit 1
fi
echo "all tests passed"
