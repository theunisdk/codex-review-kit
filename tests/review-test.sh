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
skip_test() { printf 'skip - %s\n' "$*"; }
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
    cp "$KIT/scripts/lib/common.sh" "$KIT/scripts/lib/analyzers.sh" scripts/lib/
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

# The rubric is the repo's house rules; a lens that never sees it cannot report a
# violation of one. Both code and spec mode must inline it into every prompt.
test_rubric_reaches_every_lens_prompt() {
  local repo="$WORK/rb" stub="$WORK/rb-stub"
  make_repo "$repo"; mkdir -p "$stub"
  printf '{"findings":[]}' > "$stub/correctness.json"
  printf '{"findings":[]}' > "$stub/security.json"
  (
    cd "$repo" || exit 1
    cp "$KIT/.review/prompts/_common-spec.md" .review/prompts/
    printf 'RUBRIC-SENTINEL-7f3a\n' > .review/rubric.md
    mkdir -p docs && printf '# spec\n' > docs/spec.md
    printf 'change\n' >> src.txt
    git add -A && git commit -qm 'source change'
  )
  run_review "$repo" "$stub" --lenses correctness,security
  assert "rubric: in correctness prompt" grep -qF 'RUBRIC-SENTINEL-7f3a' "$repo/.review/raw/prompt-correctness.md"
  assert "rubric: in security prompt" grep -qF 'RUBRIC-SENTINEL-7f3a' "$repo/.review/raw/prompt-security.md"

  run_review "$repo" "$stub" --spec docs/spec.md --lenses correctness
  assert "rubric: in spec-mode prompt" grep -qF 'RUBRIC-SENTINEL-7f3a' "$repo/.review/raw/prompt-correctness.md"

  if [ "$(id -u)" != 0 ]; then
    chmod 000 "$repo/.review/rubric.md"
    run_review "$repo" "$stub" --lenses correctness; local rc=$?
    chmod 644 "$repo/.review/rubric.md"
    assert "rubric: unreadable rubric exits nonzero" test "$rc" -ne 0
    assert "rubric: unreadable rubric not complete" jq -e '.complete == false' "$repo/.review/findings.json"
  fi

  rm "$repo/.review/rubric.md"
  run_review "$repo" "$stub" --lenses correctness
  assert "rubric: missing rubric warned about" grep -qF 'no .review/rubric.md' "$LOG"
}

# Without -z git C-quotes non-ASCII and backslash names; the quoted name matched
# no file, so the content never reached diff.patch while the run reported
# complete:true.
test_unusual_filenames_reach_the_diff() {
  local repo="$WORK/fn" stub="$WORK/fn-stub"
  make_repo "$repo"; mkdir -p "$stub"
  printf '{"findings":[]}' > "$stub/correctness.json"
  (
    cd "$repo" || exit 1
    git config core.quotePath true
    printf 'accent-content\n' > 'é.txt'
    printf 'backslash-content\n' > 'back\slash.txt'
  )
  run_review "$repo" "$stub" --uncommitted --lenses correctness; local rc=$?
  assert "uncommitted: run exits 0" test "$rc" -eq 0
  assert "uncommitted: untracked é.txt content in diff" grep -qF 'accent-content' "$repo/.review/raw/diff.patch"
  assert "uncommitted: untracked back\\slash.txt content in diff" grep -qF 'backslash-content' "$repo/.review/raw/diff.patch"
  assert "uncommitted: é.txt listed unquoted" grep -qxF 'é.txt' "$repo/.review/raw/changed-files.txt"
  assert "uncommitted: back\\slash.txt listed unquoted" grep -qxF 'back\slash.txt' "$repo/.review/raw/changed-files.txt"
  assert "uncommitted: complete" jq -e '.complete == true' "$repo/.review/findings.json"

  ( cd "$repo" && git add -A && git commit -qm 'odd names' )
  run_review "$repo" "$stub" --lenses correctness; rc=$?
  assert "branch: run exits 0" test "$rc" -eq 0
  assert "branch: é.txt listed unquoted" grep -qxF 'é.txt' "$repo/.review/raw/changed-files.txt"
  assert "branch: back\\slash.txt listed unquoted" grep -qxF 'back\slash.txt' "$repo/.review/raw/changed-files.txt"
  assert "branch: complete" jq -e '.complete == true' "$repo/.review/findings.json"

  if [ "$(id -u)" = 0 ]; then
    skip_test "uncommitted: unreadable file (root reads everything)"
  else
    ( cd "$repo" && printf 'x\n' > locked.txt && chmod 000 locked.txt )
    run_review "$repo" "$stub" --uncommitted --lenses correctness
    chmod 644 "$repo/locked.txt"
    assert "uncommitted: unreadable file named" jq -e '.unreadable_paths == ["locked.txt"]' "$repo/.review/findings.json"
    assert "uncommitted: unreadable file marks run incomplete" jq -e '.complete == false' "$repo/.review/findings.json"
    rm -f "$repo/locked.txt"

    mkdir -p "$repo/sealed" && printf 'x\n' > "$repo/sealed/f.txt" && chmod 000 "$repo/sealed"
    run_review "$repo" "$stub" --uncommitted --lenses correctness; rc=$?
    chmod 755 "$repo/sealed"; rm -rf "$repo/sealed"
    assert     "uncommitted: unlistable directory exits nonzero" test "$rc" -ne 0
    assert     "uncommitted: unlistable directory not complete" jq -e '.complete == false' "$repo/.review/findings.json"
  fi

  git init -q "$repo/nested" && printf 'x\n' > "$repo/nested/f.txt"
  run_review "$repo" "$stub" --uncommitted --lenses correctness
  rm -rf "$repo/nested"
  assert "uncommitted: nested repo named unreadable" jq -e '.unreadable_paths == ["nested/"]' "$repo/.review/findings.json"
  assert "uncommitted: nested repo marks run incomplete" jq -e '.complete == false' "$repo/.review/findings.json"
}

# Deleted, renamed and submodule paths are absent from disk by design; the
# unreadable-path check must not count them as unreviewed.
test_deletions_are_not_unreadable() {
  local repo="$WORK/dl" stub="$WORK/dl-stub" sub="$WORK/dl-sub"
  make_repo "$repo"; mkdir -p "$stub"
  printf '{"findings":[]}' > "$stub/correctness.json"
  git init -q -b main "$sub"
  ( cd "$sub" && git config user.email t@example.invalid && git config user.name t \
      && printf 'x\n' > f && git add f && git commit -qm sub )
  (
    cd "$repo" || exit 1
    git checkout -q main
    printf 'a\n' > gone.txt; printf 'b\n' > moved.txt; printf 'c\n' > staged.txt; printf 'd\n' > worktree.txt
    git -c protocol.file.allow=always submodule add -q "$sub" sm >/dev/null 2>&1
    git add -A && git commit -qm 'files to delete' && git checkout -qb del
    git rm -q gone.txt && git mv moved.txt renamed.txt && git rm -q sm
    git commit -qm 'delete, rename, drop submodule'
    rm worktree.txt
  )
  assert "deletions: submodule fixture built" git -C "$repo" rev-parse -q --verify main:sm
  run_review "$repo" "$stub" --lenses correctness
  assert "deletions: branch mode flags nothing" jq -e '.unreadable_paths == [] and .complete == true' "$repo/.review/findings.json"

  ( cd "$repo" && git rm -q staged.txt )
  run_review "$repo" "$stub" --uncommitted --lenses correctness
  assert "deletions: uncommitted mode flags nothing" jq -e '.unreadable_paths == [] and .complete == true' "$repo/.review/findings.json"

  # changed on the branch but missing from the working tree: the lenses cannot read it
  ( cd "$repo" && git reset -q --hard && printf 'more\n' >> src.txt && git commit -qam 'touch src' && rm src.txt )
  run_review "$repo" "$stub" --lenses correctness
  assert "deletions: branch file missing from worktree is unreadable" \
    jq -e '.unreadable_paths == ["src.txt"] and .complete == false' "$repo/.review/findings.json"
  git -C "$repo" checkout -q -- src.txt

  if [ "$(id -u)" != 0 ]; then
    chmod 000 "$repo/src.txt"
    run_review "$repo" "$stub" --lenses correctness
    chmod 644 "$repo/src.txt"
    assert "deletions: unreadable changed file is unreadable" \
      jq -e '.unreadable_paths == ["src.txt"] and .complete == false' "$repo/.review/findings.json"
  fi
}

# --fail-on exits 2 after writing the report; the abort handler must leave it alone.
test_fail_on_gate_keeps_its_report() {
  local repo="$WORK/gt" stub="$WORK/gt-stub"
  make_repo "$repo"; mkdir -p "$stub"
  finding 'gate finding' > "$stub/correctness.json"
  ( cd "$repo" && printf 'change\n' >> src.txt && git add -A && git commit -qm change )
  run_review "$repo" "$stub" --lenses correctness --fail-on high; local rc=$?
  assert "gate: exits 2" test "$rc" -eq 2
  assert "gate: report kept" jq -e '.complete == true and (.findings | length) == 1' "$repo/.review/findings.json"
}

# A spec selection that resolves to no documents reviewed nothing, and any run
# that stops early must not leave the previous run's complete:true in place.
test_spec_selecting_nothing_fails() {
  local repo="$WORK/se" stub="$WORK/se-stub"
  make_repo "$repo"; mkdir -p "$stub"
  ( cd "$repo" && cp "$KIT/.review/prompts/_common-spec.md" .review/prompts/ && mkdir -p docs/empty && printf 'x\n' > docs/empty/notes.txt )
  local stale='{"findings":[],"lenses_failed":[],"complete":true}'

  printf '%s\n' "$stale" > "$repo/.review/findings.json"
  run_review "$repo" "$stub" --spec docs/empty --lenses correctness; local rc=$?
  assert "spec-empty: dir without .md exits nonzero" test "$rc" -ne 0
  assert "spec-empty: reported incomplete" jq -e '.complete == false' "$repo/.review/findings.json"

  printf '# spec\n' > "$repo/docs/real.md"
  run_review "$repo" "$stub" --spec docs/empty --spec docs/real.md --lenses correctness; rc=$?
  assert "spec-empty: empty dir alongside a real spec exits nonzero" test "$rc" -ne 0

  printf '%s\n' "$stale" > "$repo/.review/findings.json"
  run_review "$repo" "$stub" --spec docs/missing.md --lenses correctness; rc=$?
  assert "spec-empty: missing path exits nonzero" test "$rc" -ne 0
  assert "spec-empty: stale report replaced" jq -e '.complete == false' "$repo/.review/findings.json"
}

test_spec_path_with_space() {
  local repo="$WORK/sp" stub="$WORK/sp-stub"
  make_repo "$repo"; mkdir -p "$stub"
  printf '{"findings":[]}' > "$stub/correctness.json"
  ( cd "$repo" && cp "$KIT/.review/prompts/_common-spec.md" .review/prompts/ && mkdir -p 'docs/my specs' && printf '# spec\n' > 'docs/my specs/a b.md' )

  run_review "$repo" "$stub" --spec 'docs/my specs/a b.md' --lenses correctness; local rc=$?
  assert "spec-space: file path exits 0" test "$rc" -eq 0
  assert "spec-space: file listed whole" grep -qxF 'docs/my specs/a b.md' "$repo/.review/raw/changed-files.txt"
  assert "spec-space: complete" jq -e '.complete == true' "$repo/.review/findings.json"

  run_review "$repo" "$stub" --spec 'docs/my specs' --lenses correctness; rc=$?
  assert "spec-space: directory path exits 0" test "$rc" -eq 0
  assert "spec-space: directory's file listed" grep -qxF 'docs/my specs/a b.md' "$repo/.review/raw/changed-files.txt"
}

# --- analyzer stubs --------------------------------------------------------
# CI has no gitleaks/eslint/tsc, so every tool the analyzer pass reaches for is
# a stub in $WORK/abin, first on PATH. Behaviour comes from $ANALYZER_STUB_DIR.
mkdir -p "$WORK/abin"
# gitleaks: logs its args to gitleaks.calls. The history scan (no --pipe) prints
# gitleaks-history.out and exits gitleaks-history.rc; --pipe uses gitleaks-pipe.*.
# Without those files it reports a clean scan.
cat > "$WORK/abin/gitleaks" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ANALYZER_STUB_DIR/gitleaks.calls"
case " $* " in *" --pipe "*) kind=pipe; cat > /dev/null ;; *) kind=history ;; esac
if [ -f "$ANALYZER_STUB_DIR/gitleaks-$kind.out" ]; then
  cat "$ANALYZER_STUB_DIR/gitleaks-$kind.out"
  exit "$(cat "$ANALYZER_STUB_DIR/gitleaks-$kind.rc" 2>/dev/null || echo 0)"
fi
[ "$kind" = history ] && echo "1:00PM INF 1 commits scanned."
echo "1:00PM INF no leaks found"
EOF
# npx / pnpm / yarn / bun: log "<runner> <args>" to runner.calls, strip the
# runner's own verb, and resolve <tool> only if this runner is the one named in
# `runner` and <tool>.rc exists. Then print <tool>.out and exit <tool>.rc.
cat > "$WORK/abin/npx" <<'EOF'
#!/usr/bin/env bash
me="$(basename "$0")"
printf '%s %s\n' "$me" "$*" >> "$ANALYZER_STUB_DIR/runner.calls"
while [ $# -gt 0 ]; do
  case "$1" in --no-install|--silent|exec|run) shift ;; *) break ;; esac
done
tool="$1"; shift
if [ "$me" != "$(cat "$ANALYZER_STUB_DIR/runner" 2>/dev/null)" ] || [ ! -f "$ANALYZER_STUB_DIR/$tool.rc" ]; then
  echo "$me: $tool: command not found" >&2; exit 1
fi
[ "${1:-}" = --version ] && { echo v0.0.0-stub; exit 0; }
cat "$ANALYZER_STUB_DIR/$tool.out" 2>/dev/null
exit "$(cat "$ANALYZER_STUB_DIR/$tool.rc")"
EOF
for r in pnpm yarn bun; do cp "$WORK/abin/npx" "$WORK/abin/$r"; done
printf '#!/usr/bin/env bash\necho %s\n' "'{\"results\":[]}'" > "$WORK/abin/semgrep"
chmod +x "$WORK"/abin/*

analyzer_repo() { # analyzer_repo <id> — fixture repo + stub dir in $AREPO/$ASTUB
  AREPO="$WORK/$1"; ASTUB="$WORK/$1-stub"
  make_repo "$AREPO"; mkdir -p "$ASTUB"
  printf '{"findings":[]}' > "$ASTUB/correctness.json"
}

run_review_analyzers() { # run_review_analyzers <dir> <stubdir> <review.sh args...>; output in $LOG
  local dir="$1" stub="$2"; shift 2
  LOG="$dir.log"
  (
    cd "$dir" && PATH="$WORK/abin:$WORK/bin:$PATH" CODEX_STUB_DIR="$stub" ANALYZER_STUB_DIR="$stub" \
      REVIEW_SKIP_AUTH_CHECK=1 bash scripts/review.sh --lenses correctness "$@"
  ) > "$LOG" 2>&1
}

section_body() { # section_body <report> <title> — the lines under "### <title>"
  awk -v h="### $2" '$0 == h { on = 1; next } /^### / { on = 0 } on' "$1"
}

section_nonempty() { [ -n "$(section_body "$1" "$2" | tr -d '[:space:]')" ]; }

# --- analyzer tests: secrets ----------------------------------------------
# Branch mode must scan each commit in the range, not only the net diff — a
# token added then removed on the branch is absent from diff.patch. Regression
# for #9. The net-diff scan stays alongside it.
test_gitleaks_scans_branch_history() {
  analyzer_repo g1
  ( cd "$AREPO" && printf 'change\n' >> src.txt && git add -A && git commit -qm change )
  local mb; mb="$(git -C "$AREPO" merge-base main HEAD)"
  run_review_analyzers "$AREPO" "$ASTUB" main
  local report="$AREPO/.review/raw/analyzers.txt"

  assert     "g1: history scan given --log-opts=<merge-base>..HEAD" grep -qF -- "--log-opts=$mb..HEAD" "$ASTUB/gitleaks.calls"
  assert     "g1: net diff still scanned with --pipe" grep -qF -- '--pipe' "$ASTUB/gitleaks.calls"
  assert     "g1: both scans labelled in the report" \
    sh -c 'grep -qF -- "-- commit history" "$1" && grep -qF -- "-- net diff" "$1"' _ "$report"
  assert     "g1: clean scan reports no leaks" grep -qF 'no leaks found' "$report"
  assert_not "g1: clean scan is not SCAN FAILED" grep -qF 'SCAN FAILED' "$report"
}

# rc 1 is not "findings": a broken .gitleaks.toml exits 1 with only an FTL line.
test_gitleaks_fatal_is_scan_failed() {
  analyzer_repo g2
  ( cd "$AREPO" && printf 'change\n' >> src.txt && git add -A && git commit -qm change )
  printf '1:00PM FTL unable to load gitleaks config\n' > "$ASTUB/gitleaks-history.out"
  printf '1\n' > "$ASTUB/gitleaks-history.rc"
  run_review_analyzers "$AREPO" "$ASTUB" main

  assert "g2: FTL + rc 1 is SCAN FAILED" grep -qF 'SCAN FAILED (rc=1' "$AREPO/.review/raw/analyzers.txt"
}

# A bad --log-opts range logs ERR, scans 0 commits, says "no leaks found", rc 0.
test_gitleaks_error_line_is_scan_failed() {
  analyzer_repo g3
  ( cd "$AREPO" && printf 'change\n' >> src.txt && git add -A && git commit -qm change )
  printf '%s\n' "1:00PM ERR [git] fatal: ambiguous argument 'nosuchref..HEAD'" \
    '1:00PM INF 0 commits scanned.' '1:00PM INF no leaks found' > "$ASTUB/gitleaks-history.out"
  run_review_analyzers "$AREPO" "$ASTUB" main

  assert "g3: ERR + 0 commits + rc 0 is SCAN FAILED" grep -qF 'SCAN FAILED' "$AREPO/.review/raw/analyzers.txt"
}

# Zero commits scanned on a range that adds lines is a failed scan even with no
# ERR line; on a deletion-only range it is the honest count, not a failure.
test_gitleaks_commit_count_checked() {
  analyzer_repo g4
  ( cd "$AREPO" && printf 'change\n' >> src.txt && git add -A && git commit -qm change )
  printf '%s\n' '1:00PM INF 0 commits scanned.' '1:00PM INF no leaks found' > "$ASTUB/gitleaks-history.out"
  run_review_analyzers "$AREPO" "$ASTUB" main
  assert "g4: 0 commits scanned on an adding range is SCAN FAILED" \
    grep -qF 'SCAN FAILED (0 commits scanned)' "$AREPO/.review/raw/analyzers.txt"

  analyzer_repo g4b
  ( cd "$AREPO" && : > src.txt && git add -A && git commit -qm 'delete only' )
  printf '%s\n' '1:00PM INF 0 commits scanned.' '1:00PM INF no leaks found' > "$ASTUB/gitleaks-history.out"
  run_review_analyzers "$AREPO" "$ASTUB" main
  assert_not "g4: 0 commits scanned on a deletion-only range is not a failure" \
    grep -qF 'SCAN FAILED' "$AREPO/.review/raw/analyzers.txt"
}

test_gitleaks_leaks_reported() {
  analyzer_repo g5
  ( cd "$AREPO" && printf 'change\n' >> src.txt && git add -A && git commit -qm change )
  printf '%s\n' 'Finding:     REDACTED' 'RuleID:      github-pat' 'File:        s.txt' \
    '1:00PM INF 1 commits scanned.' '1:00PM WRN leaks found: 1' > "$ASTUB/gitleaks-history.out"
  printf '3\n' > "$ASTUB/gitleaks-history.rc"
  run_review_analyzers "$AREPO" "$ASTUB" main
  local report="$AREPO/.review/raw/analyzers.txt"

  assert     "g5: rc 3 reports the finding" grep -qF 'RuleID:      github-pat' "$report"
  assert_not "g5: rc 3 is not SCAN FAILED" grep -qF 'SCAN FAILED' "$report"
}

test_gitleaks_uncommitted_scans_diff_only() {
  analyzer_repo g6
  ( cd "$AREPO" && printf 'change\n' >> src.txt )
  run_review_analyzers "$AREPO" "$ASTUB" --uncommitted
  assert_not "g6: uncommitted mode has no history scan" grep -qF -- '--log-opts' "$ASTUB/gitleaks.calls"
  assert     "g6: uncommitted mode scans the diff" grep -qF -- '--pipe' "$ASTUB/gitleaks.calls"
}

# --- analyzer tests: JS / TS ----------------------------------------------
# js_review <id> <setup snippet> — commits the setup plus a changed app.ts, runs
# the analyzer pass. The stub resolves tools only via the runner in $ASTUB/runner.
js_review() {
  analyzer_repo "$1"
  ( cd "$AREPO" && eval "$2" && printf 'export const x = 1;\n' > app.ts \
      && git add -A && git commit -qm 'js change' )
  run_review_analyzers "$AREPO" "$ASTUB" main
  JS_REPORT="$AREPO/.review/raw/analyzers.txt"
}

# Neither section may come out empty: empty reads as clean to the lenses.
assert_js_sections_nonempty() { # assert_js_sections_nonempty <id> <tsc title>
  assert "$1: eslint section is not empty" section_nonempty "$JS_REPORT" eslint
  assert "$1: $2 section is not empty" section_nonempty "$JS_REPORT" "$2"
}

# One case per package manager, by packageManager field and by lockfile. The
# field outranks a stray lockfile. Regression for #18 (npx assumed everywhere).
test_js_runner_follows_package_manager() {
  local id setup runner want
  while IFS='~' read -r id setup runner want; do
    [ -n "$id" ] || continue
    analyzer_repo "$id"
    printf '%s\n' "$runner" > "$ASTUB/runner"
    printf "app.ts:1:14  error  'x' is assigned a value but never used\n" > "$ASTUB/eslint.out"
    printf '1\n' > "$ASTUB/eslint.rc"
    ( cd "$AREPO" && eval "$setup" && printf 'export const x = 1;\n' > app.ts \
        && git add -A && git commit -qm 'js change' )
    run_review_analyzers "$AREPO" "$ASTUB" main
    JS_REPORT="$AREPO/.review/raw/analyzers.txt"
    assert "$id: eslint run as '$want'" grep -qxF "$want app.ts" "$ASTUB/runner.calls"
    assert "$id: eslint findings reported" grep -qF "'x' is assigned a value" "$JS_REPORT"
    assert_js_sections_nonempty "$id" 'tsc --noEmit'
  done <<'EOF'
j1~printf '{"packageManager":"pnpm@9.1.0"}' > package.json; : > package-lock.json~pnpm~pnpm exec eslint
j2~printf '{"packageManager":"yarn@4.1.0+sha512.abc"}' > package.json~yarn~yarn exec eslint
j3~printf '{"packageManager":"yarn@1.22.19"}' > package.json~yarn~yarn --silent run eslint
j4~printf '{"packageManager":"bun@1.1.0"}' > package.json~bun~bun run eslint
j5~printf '{"packageManager":"npm@10.2.0"}' > package.json~npx~npx --no-install eslint
j6~printf '{}' > package.json; : > pnpm-lock.yaml~pnpm~pnpm exec eslint
j7~printf '{}' > package.json; printf '# yarn lockfile v1\n' > yarn.lock~yarn~yarn --silent run eslint
j8~printf '{}' > package.json; printf '__metadata:\n  version: 8\n' > yarn.lock~yarn~yarn exec eslint
j9~printf '{}' > package.json; : > bun.lock~bun~bun run eslint
j10~printf '{}' > package.json; printf '{}' > package-lock.json~npx~npx --no-install eslint
EOF
}

# A tool the runner cannot resolve gets a named skip line, never an empty section.
test_js_unresolvable_tool_is_named() {
  js_review j11 "printf '{}' > package.json; : > pnpm-lock.yaml; printf '{}' > tsconfig.json; echo pnpm > '$WORK/j11-stub/runner'"
  assert "j11: eslint skip names the runner" \
    grep -qF 'analyzer skipped: eslint not resolvable via pnpm exec (pnpm-lock.yaml)' "$JS_REPORT"
  assert "j11: tsc skip names the runner" \
    grep -qF 'analyzer skipped: tsc not resolvable via pnpm exec' "$JS_REPORT"
  assert_js_sections_nonempty j11 'tsc --noEmit'
}

# eslint 9 with no config exits 2 with empty stdout: that is a failed lint, not a clean one.
test_js_eslint_crash_is_failed() {
  mkdir -p "$WORK/j12-stub"
  printf 'pnpm\n' > "$WORK/j12-stub/runner"; printf '2\n' > "$WORK/j12-stub/eslint.rc"
  js_review j12 "printf '{}' > package.json; : > pnpm-lock.yaml"
  assert "j12: eslint rc 2 is FAILED" grep -qF 'eslint FAILED (rc=2)' "$JS_REPORT"
  assert_js_sections_nonempty j12 'tsc --noEmit'
}

# A clean run says so, and a root tsconfig with references is type-checked with --build.
test_js_clean_run_and_tsc_build() {
  mkdir -p "$WORK/j13-stub"
  printf 'pnpm\n' > "$WORK/j13-stub/runner"
  printf '0\n' > "$WORK/j13-stub/eslint.rc"; printf '0\n' > "$WORK/j13-stub/tsc.rc"
  js_review j13 "printf '{}' > package.json; : > pnpm-lock.yaml; printf '{\"files\":[],\"references\":[{\"path\":\"pkg\"}]}' > tsconfig.json"
  assert "j13: clean eslint says 0 problems" grep -qF 'eslint: 0 problems in 1 file(s)' "$JS_REPORT"
  assert "j13: references root runs tsc --build" grep -qxF 'pnpm exec tsc --build' "$ASTUB/runner.calls"
  assert "j13: clean tsc says no errors" grep -qF 'tsc --build: no errors' "$JS_REPORT"
  assert_js_sections_nonempty j13 'tsc --build'
}

# No root package.json used to drop the whole JS section — indistinguishable
# from "no JS changed".
test_js_without_package_json_is_named() {
  js_review j14 ":"
  assert "j14: no package.json gets a skip line" grep -qF 'no package.json at the repo root' "$JS_REPORT"
  assert "j14: eslint section is not empty" section_nonempty "$JS_REPORT" eslint
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

run_update_init() { # run_update_init <spoke> [VAR=val ...] — --init run, output in $LOG
  local dir="$1"; shift
  LOG="$dir.log"
  mkdir -p "$WORK/nohome"
  ( cd "$dir" && env -i HOME="$WORK/nohome" PATH="$PATH" "$@" \
      bash "$KIT/scripts/review-update.sh" --init ) > "$LOG" 2>&1
}

# YAML well-formedness, when a parser is available. A malformed seeded config
# is worse than none: CodeRabbit discards the whole file and silently falls
# back to defaults, taking any inherited org settings down with it.
yaml_parses() { python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$1"; }
have_yaml_parser() { python3 -c 'import yaml' 2>/dev/null; }

# Assert a parsed property of a config. Text greps cannot do this job: the
# template mentions rubric.md and applyTo in its own comments, so a substring
# match reports an unwired mapping as wired.
cfg_holds() { # cfg_holds <file> <python expression over `d`>
  python3 -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
sys.exit(0 if eval(sys.argv[2]) else 1)' "$1" "$2"
}

# In CI a missing parser is a failure, not a silent skip.
require_yaml_parser() { [ "${REVIEW_TEST_REQUIRE_YAML:-0}" = 1 ]; }

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

# A local hub is installed from its WORKING TREE, so uncommitted edits there are
# real content in the spoke — and a bare HEAD in kit-version would name a commit
# that cannot reproduce what was installed.
test_update_marks_a_dirty_local_hub() {
  local hub="$WORK/u9-hub" spoke="$WORK/u9-spoke"
  make_hub "$hub"; make_spoke "$spoke"
  printf '\n# uncommitted hub edit\n' >> "$hub/scripts/review.sh"
  run_update "$spoke" REVIEW_KIT_DIR="$hub"; local rc=$?

  assert "u9: run exits 0" test "$rc" -eq 0
  assert "u9: the uncommitted edit was installed" \
    grep -qF 'uncommitted hub edit' "$spoke/scripts/review.sh"
  assert "u9: dirty hub warned about" grep -qF 'uncommitted changes' "$LOG"
  assert "u9: kit-version marks the commit dirty" \
    grep -q '^kit: .*-dirty$' "$spoke/.review/kit-version"
  assert "u9: kit-version marks the ref dirty" \
    grep -q '^ref: .*-dirty$' "$spoke/.review/kit-version"
}

# The copies are globs and whole directories, so an untracked file in the hub
# ships into the spoke too — and `git diff` alone calls that hub clean.
test_update_marks_an_untracked_hub_file() {
  local hub="$WORK/u11-hub" spoke="$WORK/u11-spoke"
  make_hub "$hub"; make_spoke "$spoke"
  printf '# untracked helper\n' > "$hub/scripts/lib/extra.sh"
  run_update "$spoke" REVIEW_KIT_DIR="$hub"; local rc=$?

  assert "u11: run exits 0" test "$rc" -eq 0
  assert "u11: the untracked file was installed" test -f "$spoke/scripts/lib/extra.sh"
  assert "u11: dirty hub warned about" grep -qF 'uncommitted changes' "$LOG"
  assert "u11: kit-version marks the commit dirty" \
    grep -q '^kit: .*-dirty$' "$spoke/.review/kit-version"
}

# The counterpart: a clean hub must not be labelled dirty.
test_update_leaves_a_clean_local_hub_unmarked() {
  local hub="$WORK/u10-hub" spoke="$WORK/u10-spoke"
  make_hub "$hub"; make_spoke "$spoke"
  run_update "$spoke" REVIEW_KIT_DIR="$hub"; local rc=$?

  assert     "u10: run exits 0" test "$rc" -eq 0
  assert_not "u10: kit-version not marked dirty" grep -q -- '-dirty' "$spoke/.review/kit-version"
  assert_not "u10: no dirty warning" grep -qF 'uncommitted changes' "$LOG"
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

# --init seeds repo-owned files that are missing. Nothing seeds without it,
# and nothing already in the repo is overwritten. `.coderabbit.yaml` is the
# case that bites: it configures the PR gate, and CodeRabbit resolves exactly
# one configuration source — a file we drop in outranks central and org-level
# settings, so overwriting (or duplicating) a repo's own config silently
# disables whatever it was inheriting.
test_init_seeds_coderabbit_config() {
  local spoke="$WORK/u6-spoke"
  make_spoke "$spoke"

  run_update "$spoke" REVIEW_KIT_DIR="$KIT"; local rc=$?
  assert     "u6: plain sync exits 0" test "$rc" -eq 0
  assert_not "u6: plain sync seeds no config" test -f "$spoke/.coderabbit.yaml"
  assert_not "u6: plain sync seeds no rubric" test -f "$spoke/.review/rubric.md"

  run_update_init "$spoke" REVIEW_KIT_DIR="$KIT"; rc=$?
  assert "u6: --init exits 0" test "$rc" -eq 0
  assert "u6: --init seeds the config" test -f "$spoke/.coderabbit.yaml"
  assert "u6: --init seeds the rubric" test -f "$spoke/.review/rubric.md"

  local cfg="$spoke/.coderabbit.yaml"
  if ! have_yaml_parser; then
    if require_yaml_parser; then
      fail "u6: python3 yaml module required (REVIEW_TEST_REQUIRE_YAML=1) but missing"
    else
      skip_test "u6: seeded-config assertions (no python3 yaml module)"
    fi
    return
  fi

  assert "u6: seeded config is well-formed YAML" yaml_parses "$cfg"
  # Without inheritance, seeding this file silently drops the org's settings.
  assert "u6: seeded config opts into inheritance" \
    cfg_holds "$cfg" 'd.get("inheritance") is True'
  # Default is 5, which pauses auto-review mid branch; a paused gate reads as
  # a clean one.
  assert "u6: seeded config disables the auto-review pause" \
    cfg_holds "$cfg" 'd["reviews"]["auto_review"]["auto_pause_after_reviewed_commits"] == 0'
  # The rubric lives outside the source tree, so it governs nothing without an
  # explicit repo-wide applyTo ON ITS OWN entry.
  assert "u6: rubric mapped repo-wide in code_guidelines" \
    cfg_holds "$cfg" 'any(e.get("files") == ".review/rubric.md" and e.get("applyTo") == "**/*" for e in d["knowledge_base"]["code_guidelines"]["filePatterns"])'
  assert "u6: learnings mapped repo-wide in code_guidelines" \
    cfg_holds "$cfg" 'any(e.get("files") == ".review/learnings.md" and e.get("applyTo") == "**/*" for e in d["knowledge_base"]["code_guidelines"]["filePatterns"])'
}

# A second --init must not clobber the repo's own edits to a seeded file.
test_init_never_overwrites_existing_config() {
  local spoke="$WORK/u7-spoke"
  make_spoke "$spoke"
  printf 'reviews:\n  profile: assertive\n' > "$spoke/.coderabbit.yaml"

  run_update_init "$spoke" REVIEW_KIT_DIR="$KIT"; local rc=$?
  assert "u7: run exits 0" test "$rc" -eq 0
  assert "u7: existing config left untouched" \
    grep -qF 'profile: assertive' "$spoke/.coderabbit.yaml"
  assert_not "u7: template did not overwrite it" \
    grep -qE '^inheritance: *true' "$spoke/.coderabbit.yaml"
}

# CodeRabbit also reads `.coderabbit.yml`, and YAML in either spelling beats
# `.coderabbit.config.ts` outright. Seeding alongside any of them would leave
# the repo with a second config it never asked for and cannot see losing.
test_init_respects_other_config_spellings() {
  local rc name spoke
  # The first three are CodeRabbit's documented names; the undotted pair is
  # guarded defensively, since seeding over a live gate config is silent.
  for name in .coderabbit.yml .coderabbit.config.ts coderabbit.yaml coderabbit.yml; do
    spoke="$WORK/u8-$name-spoke"
    make_spoke "$spoke"
    : > "$spoke/$name"

    run_update_init "$spoke" REVIEW_KIT_DIR="$KIT"; rc=$?
    assert     "u8: --init exits 0 with $name present" test "$rc" -eq 0
    assert_not "u8: no .coderabbit.yaml seeded alongside $name" \
      test -f "$spoke/.coderabbit.yaml"
  done
}

# --- installer fixtures ----------------------------------------------------
make_installed_spoke() { # <dir> — a spoke with the kit synced and seeded
  local dir="$1"
  make_spoke "$dir"
  ( cd "$dir" && env -i HOME="$WORK/nohome" PATH="$PATH" REVIEW_KIT_DIR="$KIT" \
      bash "$KIT/scripts/review-update.sh" --init ) >/dev/null 2>&1
}

make_synced_spoke() { # <dir> — synced but NOT seeded, for bring-your-own configs
  local dir="$1"
  make_spoke "$dir"
  ( cd "$dir" && env -i HOME="$WORK/nohome" PATH="$PATH" REVIEW_KIT_DIR="$KIT" \
      bash "$KIT/scripts/review-update.sh" ) >/dev/null 2>&1
}

run_install_check() { # <spoke> — --check output in $LOG (stubbed codex on PATH)
  local dir="$1"
  LOG="$dir.install.log"
  mkdir -p "$WORK/nohome"
  ( cd "$dir" && env -i HOME="$WORK/nohome" PATH="$WORK/bin:$PATH" \
      bash scripts/review-install.sh --check ) > "$LOG" 2>&1
}

run_install_full() { # <spoke> — full install, so --check has nothing else to fail on
  local dir="$1"
  mkdir -p "$WORK/nohome"
  ( cd "$dir" && env -i HOME="$WORK/nohome" PATH="$WORK/bin:$PATH" \
      bash scripts/review-install.sh ) >/dev/null 2>&1
}

write_cfg() { printf '%s\n' "$2" > "$1/.coderabbit.yaml"; }

# --- installer tests -------------------------------------------------------
# The PR-gate section is the installer's only repo-state-dependent check, and
# its job is to notice a gate that is present but not actually wired to the
# rubric — the state that otherwise looks identical to a configured one.
test_install_check_reports_gate_state() {
  local spoke="$WORK/i1-spoke"
  make_installed_spoke "$spoke"

  run_install_check "$spoke"
  assert     "i1: wired config reported wired" \
    grep -qF 'wires inheritance and both guideline mappings' "$LOG"
  assert_not "i1: no inheritance complaint when wired" grep -q "omits 'inheritance: true'" "$LOG"
  assert_not "i1: no mapping complaint when wired" grep -q 'has no knowledge_base' "$LOG"

  # absent entirely — advisory, since a repo may deliberately not use CodeRabbit
  mv "$spoke/.coderabbit.yaml" "$spoke/held.yaml"
  run_install_check "$spoke"
  assert "i2: missing config reported" grep -qF 'no CodeRabbit config' "$LOG"
  mv "$spoke/held.yaml" "$spoke/.coderabbit.yaml"

  # a TypeScript config is the active one; it must never be reported verified
  local ts="$WORK/i5-spoke"
  make_synced_spoke "$ts"
  : > "$ts/.coderabbit.config.ts"
  run_install_check "$ts"
  assert "i5: typescript config reported uninspected" grep -qF 'is NOT inspected here' "$LOG"

  # The seed guard refuses to seed alongside an undotted name, so detection
  # must not advise seeding one — nor vouch for a file that is absent from
  # CodeRabbit's documented discovery.
  local un="$WORK/i12-spoke"
  make_synced_spoke "$un"
  : > "$un/coderabbit.yaml"
  run_install_check "$un"
  assert     "i12: undotted config reported present" grep -qF 'not one of CodeRabbit' "$LOG"
  assert_not "i12: does not advise seeding alongside it" grep -qF 'no CodeRabbit config' "$LOG"
  assert_not "i12: does not vouch for its wiring" grep -qF 'wires inheritance' "$LOG"
}

# A gate that is present but silently unwired must FAIL --check, not merely
# warn: onboarding requires wiring a pre-existing config and requires --check
# to pass, so an advisory-only result lets that requirement go unmet. A
# missing config stays advisory — declining to use CodeRabbit is a choice.
test_install_check_fails_on_unwired_gate() {
  local spoke="$WORK/i6-spoke" rc
  make_installed_spoke "$spoke"
  run_install_full "$spoke"

  run_install_check "$spoke"; rc=$?
  assert "i6: fully wired repo passes --check" test "$rc" -eq 0
  cp "$spoke/.coderabbit.yaml" "$WORK/i6-held.yaml"

  # the live rubric mapping deleted, comments left intact: the state a
  # substring search called correctly wired
  python3 - "$spoke/.coderabbit.yaml" <<'EOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('      - files: ".review/rubric.md"\n        applyTo: "**/*"\n', ''))
EOF
  run_install_check "$spoke"; rc=$?
  assert "i3: unwired rubric fails --check" test "$rc" -ne 0
  assert "i3: unwired rubric named" grep -qF 'entry mapping .review/rubric.md' "$LOG"
  assert "i3: rubric.md still present in comments" grep -qF '.review/rubric.md' "$spoke/.coderabbit.yaml"

  # inheritance dropped: the file then replaces the org's settings silently
  cp "$WORK/i6-held.yaml" "$spoke/.coderabbit.yaml"
  python3 - "$spoke/.coderabbit.yaml" <<'EOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('inheritance: true', '# inheritance removed'))
EOF
  run_install_check "$spoke"; rc=$?
  assert "i4: missing inheritance fails --check" test "$rc" -ne 0
  assert "i4: missing inheritance named" grep -q "omits 'inheritance: true'" "$LOG"

  # only the learnings mapping removed — must also be caught
  cp "$WORK/i6-held.yaml" "$spoke/.coderabbit.yaml"
  python3 - "$spoke/.coderabbit.yaml" <<'EOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('      - files: ".review/learnings.md"\n        applyTo: "**/*"\n', ''))
EOF
  run_install_check "$spoke"; rc=$?
  assert "i7: unwired learnings fails --check" test "$rc" -ne 0
  assert "i7: unwired learnings named" grep -qF 'entry mapping .review/learnings.md' "$LOG"

  # the right pair in the wrong section is not a guideline at all
  write_cfg "$spoke" 'inheritance: true
reviews:
  path_instructions:
    - files: ".review/rubric.md"
      applyTo: "**/*"'
  run_install_check "$spoke"; rc=$?
  assert "i8: mapping under path_instructions fails --check" test "$rc" -ne 0

  # a valid config that merely quotes differently must NOT be called broken
  write_cfg "$spoke" "inheritance: true
knowledge_base:
  code_guidelines:
    filePatterns:
      - applyTo: '**/*'
        files: '.review/rubric.md'
      - {files: .review/learnings.md, applyTo: '**/*'}"
  run_install_check "$spoke"; rc=$?
  assert     "i9: differently quoted config passes --check" test "$rc" -eq 0
  assert_not "i9: differently quoted config not called broken" grep -q 'has no knowledge_base' "$LOG"

  # mapped but switched off: CodeRabbit applies neither file, so the mappings
  # being present proves nothing
  write_cfg "$spoke" 'inheritance: true
knowledge_base:
  code_guidelines:
    enabled: false
    filePatterns:
      - files: ".review/rubric.md"
        applyTo: "**/*"
      - files: ".review/learnings.md"
        applyTo: "**/*"'
  run_install_check "$spoke"; rc=$?
  assert "i11: disabled code_guidelines fails --check" test "$rc" -ne 0
  assert "i11: disabled code_guidelines named" grep -qF 'enabled to false' "$LOG"

  # valid YAML of the wrong shape: the wiring check used to raise, and with
  # stderr discarded an empty result read as "no problems found"
  write_cfg "$spoke" 'inheritance: true
knowledge_base:
  code_guidelines:
    filePatterns: 1'
  run_install_check "$spoke"; rc=$?
  assert "i13: wrong-shaped filePatterns fails --check" test "$rc" -ne 0
  assert "i13: wrong-shaped filePatterns named" grep -qF 'rather than a list' "$LOG"

  # an unparseable config discards everything CodeRabbit would have read
  printf 'inheritance: true\n  bad: [unclosed\n' > "$spoke/.coderabbit.yaml"
  run_install_check "$spoke"; rc=$?
  assert "i10: unparseable config fails --check" test "$rc" -ne 0
  assert "i10: unparseable config named as such" grep -qF 'does not parse' "$LOG"

  # PyYAML keeps the LAST of a duplicated key, so wiring in an overridden block
  # would be vouched for here; parsers that reject duplicates outright discard
  # the file entirely. Either way the gate applies something else.
  write_cfg "$spoke" 'inheritance: true
knowledge_base:
  code_guidelines:
    enabled: false
knowledge_base:
  code_guidelines:
    filePatterns:
      - files: ".review/rubric.md"
        applyTo: "**/*"
      - files: ".review/learnings.md"
        applyTo: "**/*"'
  run_install_check "$spoke"; rc=$?
  assert "i14: duplicate mapping key fails --check" test "$rc" -ne 0
  assert "i14: duplicate key named" grep -qF 'duplicate key' "$LOG"

  # Anchors and `<<` merges are valid YAML that SafeLoader flattens. The
  # duplicate-key check must not see the merge pseudo-key as a parse error and
  # call a correctly wired config broken.
  write_cfg "$spoke" 'defaults: &d
  enabled: true
inheritance: true
knowledge_base:
  code_guidelines:
    <<: *d
    filePatterns:
      - files: ".review/rubric.md"
        applyTo: "**/*"
      - files: ".review/learnings.md"
        applyTo: "**/*"'
  run_install_check "$spoke"; rc=$?
  assert     "i15: merged-anchor config passes --check" test "$rc" -eq 0
  assert_not "i15: merged-anchor config not called unparseable" grep -q 'does not parse' "$LOG"
}

# `git push origin HEAD~1:refs/heads/feature` hands the hook a commit
# expression as <local ref>; selecting branches by it matched no refs/heads/*
# and skipped the check, so REVIEW_STRICT could not block that push.
test_prepush_judges_destination_ref() {
  local repo="$WORK/h1" remote="$WORK/h1-remote.git" out="$WORK/h1.push.log" rc=0
  git init -q --bare "$remote"
  git init -q -b main "$repo"
  (
    cd "$repo" || exit 1
    git config user.email review-test@example.invalid
    git config user.name review-test
    git config core.hooksPath .githooks
    mkdir -p scripts .githooks
    cp "$KIT/.githooks/pre-push" .githooks/
    cp "$KIT/scripts/review.sh" scripts/
    printf 'seed\n' > f.txt
    git add -A && git commit -qm c1
    printf 'more\n' >> f.txt && git commit -qam c2
  )

  ( cd "$repo" && REVIEW_STRICT=1 git push "$remote" 'HEAD~1:refs/heads/feature' ) > "$out" 2>&1
  rc=$?
  assert "h1: commit-expression push is gated" test "$rc" -ne 0
  assert "h1: the hook names the destination branch" \
    grep -qF 'feature — no review verdict found' "$out"

  # A tag's sha is the tag object, never a reviewed commit, so a verdict could
  # never match it — blocking every tag push is the failure to avoid here.
  ( cd "$repo" && git tag -a v9.9.9 -m t \
      && REVIEW_STRICT=1 git push "$remote" refs/tags/v9.9.9 ) > "$out" 2>&1
  rc=$?
  assert "h1: tag push not gated" test "$rc" -eq 0

  ( cd "$repo" && REVIEW_STRICT=1 git push "$remote" 'HEAD:refs/heads/main' ) > "$out" 2>&1
  rc=$?
  assert "h1: main exempt by destination name" test "$rc" -eq 0
}

# The verdict names the judged commit in its header, as `git rev-parse --short`
# prints it. Matching a fixed 10-character prefix called every current verdict
# stale; matching anywhere in the file let a SHA quoted in the body pass.
test_prepush_reads_the_verdict_header() {
  local repo="$WORK/h2" remote="$WORK/h2-remote.git" out="$WORK/h2.push.log" rc=0 head short
  git init -q --bare "$remote"
  git init -q -b main "$repo"
  (
    cd "$repo" || exit 1
    git config user.email review-test@example.invalid
    git config user.name review-test
    git config core.hooksPath .githooks
    mkdir -p scripts .githooks .review
    cp "$KIT/.githooks/pre-push" .githooks/
    cp "$KIT/scripts/review.sh" scripts/
    printf 'seed\n' > f.txt
    git add -A && git commit -qm c1
    printf 'more\n' >> f.txt && git commit -qam c2
  )
  head=$(git -C "$repo" rev-parse HEAD)
  short=$(git -C "$repo" rev-parse --short HEAD)

  printf '# Review verdict — feature — %s — 2026-01-01\n\nclean\n' "$short" > "$repo/.review/verdict.md"
  ( cd "$repo" && REVIEW_STRICT=1 git push "$remote" 'HEAD:refs/heads/feature' ) > "$out" 2>&1
  rc=$?
  assert "h2: a short-SHA header covers its commit" test "$rc" -eq 0

  printf '# Review verdict — feature — 0000000 — 2026-01-01\n\nmentions %s in passing\n' "$head" \
    > "$repo/.review/verdict.md"
  ( cd "$repo" && REVIEW_STRICT=1 git push "$remote" 'HEAD:refs/heads/feature2' ) > "$out" 2>&1
  rc=$?
  assert "h2: a SHA in the body does not cover it" test "$rc" -ne 0

  printf 'no header here\n%s\n' "$head" > "$repo/.review/verdict.md"
  ( cd "$repo" && REVIEW_STRICT=1 git push "$remote" 'HEAD:refs/heads/feature3' ) > "$out" 2>&1
  rc=$?
  assert "h2: an unreadable header is stale" test "$rc" -ne 0
  printf '# Review verdict — feature — %s — 2026-01-01\n' "${head:0:4}" > "$repo/.review/verdict.md"
  ( cd "$repo" && REVIEW_STRICT=1 git push "$remote" 'HEAD:refs/heads/feature4' ) > "$out" 2>&1
  rc=$?
  assert "h2: git's shortest abbreviation covers its commit" test "$rc" -eq 0

  printf '# Review verdict — feature — 0000000 — note — %s — 2026-01-01\n' "$short" \
    > "$repo/.review/verdict.md"
  ( cd "$repo" && REVIEW_STRICT=1 git push "$remote" 'HEAD:refs/heads/feature5' ) > "$out" 2>&1
  rc=$?
  assert "h2: a SHA in a later header field does not cover it" test "$rc" -ne 0
}

# /review-spec wrote the same file and header as /review, so a spec review naming
# HEAD cleared the code-review gate. Spec verdicts now carry their own header and
# file; a misfiled one is rejected by name, and one beside verdict.md is ignored.
test_prepush_rejects_a_spec_verdict() {
  local repo="$WORK/h3" remote="$WORK/h3-remote.git" out="$WORK/h3.push.log" rc=0 short
  git init -q --bare "$remote"
  git init -q -b main "$repo"
  (
    cd "$repo" || exit 1
    git config user.email review-test@example.invalid
    git config user.name review-test
    git config core.hooksPath .githooks
    mkdir -p scripts .githooks .review
    cp "$KIT/.githooks/pre-push" .githooks/
    cp "$KIT/scripts/review.sh" scripts/
    printf 'seed\n' > f.txt
    git add -A && git commit -qm c1
  )
  short=$(git -C "$repo" rev-parse --short HEAD)

  printf '# Spec verdict — feature — %s — 2026-01-01\n\nclean\n' "$short" > "$repo/.review/verdict.md"
  ( cd "$repo" && REVIEW_STRICT=1 git push "$remote" 'HEAD:refs/heads/feature' ) > "$out" 2>&1
  rc=$?
  assert "h3: a spec verdict does not clear the code-review gate" test "$rc" -ne 0
  assert "h3: the hook says the verdict is spec-mode" grep -qF 'feature — spec-mode verdict' "$out"

  printf '# Review verdict — feature — %s — 2026-01-01\n\nclean\n' "$short" > "$repo/.review/verdict.md"
  ( cd "$repo" && REVIEW_STRICT=1 git push "$remote" 'HEAD:refs/heads/feature2' ) > "$out" 2>&1
  rc=$?
  assert "h3: a code verdict naming HEAD still passes" test "$rc" -eq 0

  printf '# Spec verdict — feature — 0000000 — 2026-01-01\n' > "$repo/.review/spec-verdict.md"
  ( cd "$repo" && REVIEW_STRICT=1 git push "$remote" 'HEAD:refs/heads/feature3' ) > "$out" 2>&1
  rc=$?
  assert "h3: a stale spec-verdict.md beside a current verdict passes" test "$rc" -eq 0

  rm "$repo/.review/verdict.md"
  printf '# Spec verdict — feature — %s — 2026-01-01\n' "$short" > "$repo/.review/spec-verdict.md"
  ( cd "$repo" && REVIEW_STRICT=1 git push "$remote" 'HEAD:refs/heads/feature4' ) > "$out" 2>&1
  rc=$?
  assert "h3: a current spec-verdict.md alone does not clear the gate" test "$rc" -ne 0
  assert "h3: … because there is no code verdict" grep -qF 'feature4 — no review verdict found' "$out"
}

# In a SHA-256 repository a deletion's local_sha is 64 zeros; matching only the
# 40-zero SHA-1 form judged `git push origin :feature` as a push of a commit and
# blocked it for lack of a verdict.
test_prepush_skips_a_sha256_deletion() {
  local repo="$WORK/h4" out="$WORK/h4.push.log" rc=0 z40 z64
  git init -q -b main "$repo"
  mkdir -p "$repo/scripts" "$repo/.githooks"
  cp "$KIT/.githooks/pre-push" "$repo/.githooks/"
  cp "$KIT/scripts/review.sh" "$repo/scripts/"
  z40=0000000000000000000000000000000000000000
  z64=0000000000000000000000000000000000000000000000000000000000000000
  ( cd "$repo" && printf '(delete) %s refs/heads/feature %s\n' "$z64" "$z64" \
      | REVIEW_STRICT=1 bash .githooks/pre-push origin url ) > "$out" 2>&1
  rc=$?
  assert "h4: a SHA-256 branch deletion is not gated" test "$rc" -eq 0
  ( cd "$repo" && printf '(delete) %s refs/heads/feature %s\n' "$z40" "$z40" \
      | REVIEW_STRICT=1 bash .githooks/pre-push origin url ) > "$out" 2>&1
  rc=$?
  assert "h4: a SHA-1 branch deletion is not gated" test "$rc" -eq 0
  ( cd "$repo" && printf 'HEAD %s refs/heads/feature %s\n' "${z64%0}1" "$z64" \
      | REVIEW_STRICT=1 bash .githooks/pre-push origin url ) > "$out" 2>&1
  rc=$?
  assert "h4: a 64-character SHA that is not all zeros is still gated" test "$rc" -ne 0
  assert "h4: … for want of a verdict" grep -qF 'feature — no review verdict found' "$out"
}

# A destination that denies listing looks empty to `ls -A`, and empty is the one
# state this guard lets through — into the rm -rf of commands/skills/scripts.
test_make_plugin_refuses_an_unlistable_destination() {
  if [ "$(id -u)" = 0 ]; then
    skip_test "m1: unlistable-destination guard (root ignores the directory mode)"
    return
  fi
  local dest="$WORK/m1-dest" out="$WORK/m1.log" rc=0
  mkdir -p "$dest/commands"
  printf 'precious\n' > "$dest/commands/keep.md"
  chmod 300 "$dest"
  ( cd "$KIT" && bash scripts/make-plugin.sh "$dest" ) > "$out" 2>&1
  rc=$?
  chmod 700 "$dest"

  assert "m1: unlistable destination refused" test "$rc" -ne 0
  assert "m1: refusal names the cause" grep -qF 'cannot list' "$out"
  assert "m1: existing content survives" test -f "$dest/commands/keep.md"
}

run_tests() {
  local t
  for t in "$@"; do
    if declare -F "$t" >/dev/null 2>&1; then
      "$t"
    else
      fail "harness: test '$t' is listed but not defined"
    fi
  done
}

run_tests \
  test_tracked_review_sources_survive_filter \
  test_nonzero_rc_lens_marked_failed \
  test_all_lenses_failed_with_output_still_merges \
  test_rubric_reaches_every_lens_prompt \
  test_unusual_filenames_reach_the_diff \
  test_deletions_are_not_unreadable \
  test_fail_on_gate_keeps_its_report \
  test_spec_selecting_nothing_fails \
  test_spec_path_with_space \
  test_gitleaks_scans_branch_history \
  test_gitleaks_fatal_is_scan_failed \
  test_gitleaks_error_line_is_scan_failed \
  test_gitleaks_commit_count_checked \
  test_gitleaks_leaks_reported \
  test_gitleaks_uncommitted_scans_diff_only \
  test_js_runner_follows_package_manager \
  test_js_unresolvable_tool_is_named \
  test_js_eslint_crash_is_failed \
  test_js_clean_run_and_tsc_build \
  test_js_without_package_json_is_named \
  test_update_reports_source_and_revision \
  test_update_marks_a_dirty_local_hub \
  test_update_marks_an_untracked_hub_file \
  test_update_leaves_a_clean_local_hub_unmarked \
  test_update_network_pins_to_latest_tag \
  test_update_network_honors_explicit_ref \
  test_update_network_refuses_without_pin \
  test_update_warns_on_stale_local_clone \
  test_init_seeds_coderabbit_config \
  test_init_never_overwrites_existing_config \
  test_init_respects_other_config_spellings \
  test_install_check_reports_gate_state \
  test_install_check_fails_on_unwired_gate \
  test_prepush_judges_destination_ref \
  test_prepush_reads_the_verdict_header \
  test_prepush_rejects_a_spec_verdict \
  test_prepush_skips_a_sha256_deletion \
  test_make_plugin_refuses_an_unlistable_destination

echo
if [ "$FAILURES" -gt 0 ]; then
  printf '%d assertion(s) FAILED\n' "$FAILURES"; exit 1
fi
echo "all tests passed"
