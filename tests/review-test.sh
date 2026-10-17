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

# A configured lens with no prompt file reviewed nothing: it fails the run
# rather than dropping out of it, and the other lenses still run.
test_missing_lens_prompt_is_failed() {
  local repo="$WORK/t4" stub="$WORK/t4-stub"
  make_repo "$repo"; mkdir -p "$stub"
  finding 'clean lens finding' > "$stub/correctness.json"
  ( cd "$repo" && printf 'change\n' >> src.txt && git add -A && git commit -qm 'source change' )
  run_review "$repo" "$stub" --lenses correctness,missing-lens; local rc=$?
  local json="$repo/.review/findings.json"

  assert "t4: run exits 0" test "$rc" -eq 0
  assert "t4: the valid lens still runs" \
    jq -e '[.findings[] | select(.title == "clean lens finding")] | length == 1' "$json"
  assert "t4: the missing lens is in lenses_failed" jq -e '.lenses_failed == ["missing-lens"]' "$json"
  assert "t4: complete is false" jq -e '.complete == false' "$json"
  assert "t4: findings.md says INCOMPLETE" grep -qF 'INCOMPLETE REVIEW' "$repo/.review/findings.md"
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

# An empty positional base used to fall back to the detected default branch,
# silently widening a scoped re-review (an unset $PRE_FIX) to the whole branch.
test_empty_base_ref_dies() {
  local repo="$WORK/eb" stub="$WORK/eb-stub"
  make_repo "$repo"; mkdir -p "$stub"
  printf '{"findings":[]}' > "$stub/correctness.json"
  ( cd "$repo" && printf 'change\n' >> src.txt && git add -A && git commit -qm change )
  LOG="$repo.log"
  ( cd "$repo" && PATH="$WORK/bin:$PATH" CODEX_STUB_DIR="$stub" REVIEW_SKIP_AUTH_CHECK=1 \
      bash scripts/review.sh --no-analyzers "" --lenses correctness ) > "$LOG" 2>&1; local rc=$?
  assert     "empty-base: exits nonzero" test "$rc" -ne 0
  assert     "empty-base: says why" grep -qF 'empty base ref' "$LOG"
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
# With gitleaks-history.git holding a pattern, the history scan instead reads
# `git log -p -U0 <log-opts>` as gitleaks does, and reports a leak if an added
# line matches. Without those files it reports a clean scan.
cat > "$WORK/abin/gitleaks" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ANALYZER_STUB_DIR/gitleaks.calls"
case " $* " in *" --pipe "*) kind=pipe; cat > /dev/null ;; *) kind=history ;; esac
if [ "$kind" = history ] && [ -f "$ANALYZER_STUB_DIR/gitleaks-history.git" ]; then
  for a in "$@"; do case "$a" in --log-opts=*) opts="${a#--log-opts=}" ;; esac; done
  # shellcheck disable=SC2086 # gitleaks splits --log-opts on spaces
  log="$(git log -p -U0 $opts)" || { echo "1:00PM ERR [git] log failed"; exit 1; }
  printf '1:00PM INF %s commits scanned.\n' "$(grep -c '^commit ' <<< "$log")"
  if grep -q "^+.*$(cat "$ANALYZER_STUB_DIR/gitleaks-history.git")" <<< "$log"; then
    printf '%s\n' 'RuleID:      generic-api-key' '1:00PM WRN leaks found: 1'; exit 3
  fi
  echo "1:00PM INF no leaks found"; exit 0
fi
if [ -f "$ANALYZER_STUB_DIR/gitleaks-$kind.out" ]; then
  cat "$ANALYZER_STUB_DIR/gitleaks-$kind.out"
  exit "$(cat "$ANALYZER_STUB_DIR/gitleaks-$kind.rc" 2>/dev/null || echo 0)"
fi
[ "$kind" = history ] && echo "1:00PM INF 1 commits scanned."
echo "1:00PM INF no leaks found"
EOF
# npx / pnpm / yarn / bun: log "<runner> <args>" to runner.calls, strip the
# runner's own verb, and resolve <tool> only if this runner is the one named in
# `runner` and <tool>.rc exists. Then run <tool>.sh if present, else print
# <tool>.out and exit <tool>.rc. Copied into node_modules/.bin as eslint/tsc it
# is the bin-dir runner, named `bin` in `runner`.
cat > "$WORK/abin/npx" <<'EOF'
#!/usr/bin/env bash
me="$(basename "$0")"
case "$me" in
  npx|pnpm|yarn|bun)
    printf '%s %s\n' "$me" "$*" >> "$ANALYZER_STUB_DIR/runner.calls"
    while [ $# -gt 0 ]; do
      case "$1" in --no-install|--silent|exec|run) shift ;; *) break ;; esac
    done ;;
  *) printf 'node_modules/.bin/%s %s\n' "$me" "$*" >> "$ANALYZER_STUB_DIR/runner.calls"
     set -- "$me" "$@"; me=bin ;;
esac
tool="$1"; shift
if [ "$me" != "$(cat "$ANALYZER_STUB_DIR/runner" 2>/dev/null)" ] || [ ! -f "$ANALYZER_STUB_DIR/$tool.rc" ]; then
  echo "$me: $tool: command not found" >&2; exit 1
fi
[ "${1:-}" = --version ] && { echo v0.0.0-stub; exit 0; }
[ -f "$ANALYZER_STUB_DIR/$tool.sh" ] && exec bash "$ANALYZER_STUB_DIR/$tool.sh" "$@"
cat "$ANALYZER_STUB_DIR/$tool.out" 2>/dev/null
exit "$(cat "$ANALYZER_STUB_DIR/$tool.rc")"
EOF
for r in pnpm yarn bun; do cp "$WORK/abin/npx" "$WORK/abin/$r"; done
# semgrep: records its argv in semgrep.args; prints semgrep.out (default: no
# results), semgrep.err on stderr, and exits semgrep.rc (default 0).
cat > "$WORK/abin/semgrep" <<'EOF'
#!/usr/bin/env bash
d="$ANALYZER_STUB_DIR"
printf '%s\n' "$@" > "$d/semgrep.args"
[ -f "$d/semgrep.err" ] && cat "$d/semgrep.err" >&2
if [ -f "$d/semgrep.out" ]; then cat "$d/semgrep.out"; else echo '{"results":[],"errors":[]}'; fi
exit "$(cat "$d/semgrep.rc" 2>/dev/null || echo 0)"
EOF
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

bin_stubs() { # bin_stubs — eslint/tsc stubs in ./node_modules/.bin
  mkdir -p node_modules/.bin
  cp "$WORK/abin/npx" node_modules/.bin/eslint; cp "$WORK/abin/npx" node_modules/.bin/tsc
}

section_nonempty() { [ -n "$(section_body "$1" "$2" | tr -d '[:space:]')" ]; }
section_has() { section_body "$1" "$2" | grep -qF -- "$3"; }

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

  assert     "g1: history scan given --log-opts=--remerge-diff <merge-base>..HEAD" grep -qF -- "--log-opts=--remerge-diff $mb..HEAD" "$ASTUB/gitleaks.calls"
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
  assert     "g4: deletion-only range was scanned" \
    grep -qF -- '-- commit history' "$AREPO/.review/raw/analyzers.txt"
}

# The added-lines count sets how many commits gitleaks must report. A git log that
# failed counted as zero added lines, so a scan of zero commits passed as clean.
test_gitleaks_failed_line_count_is_scan_failed() {
  local real; real="$(command -v git)"
  mkdir -p "$WORK/g10-bin"
  printf '#!/bin/sh\ncase " $* " in *" --numstat "*) echo "fatal: shim" >&2; exit 128 ;; esac\nexec %s "$@"\n' \
    "$real" > "$WORK/g10-bin/git"
  chmod +x "$WORK/g10-bin/git"
  analyzer_repo g10
  ( cd "$AREPO" && printf 'change\n' >> src.txt && git add -A && git commit -qm change )
  printf '%s\n' '1:00PM INF 0 commits scanned.' '1:00PM INF no leaks found' > "$ASTUB/gitleaks-history.out"
  PATH="$WORK/g10-bin:$PATH" run_review_analyzers "$AREPO" "$ASTUB" main
  assert "g10: a failed added-lines count is SCAN FAILED" \
    grep -qF 'SCAN FAILED' "$AREPO/.review/raw/analyzers.txt"

  reverted_secret_branch g10b
  PATH="$WORK/g10-bin:$PATH" run_review_analyzers "$AREPO" "$ASTUB" main
  assert "g10: … and on an empty net diff the run is incomplete" \
    jq -e '.complete == false and .history_scan.result == "failed"' "$AREPO/.review/findings.json"
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

# On a non-empty diff a leak reached only analyzers.txt, which the lenses are
# told not to re-report, so findings.json said nothing. Regression for #35.
test_gitleaks_leak_on_a_nonempty_diff_is_critical() {
  analyzer_repo g11
  finding 'lens finding' > "$ASTUB/correctness.json"
  ( cd "$AREPO" && printf 'change\n' >> src.txt && git add -A && git commit -qm change )
  printf '%s\n' 'Finding:     REDACTED' 'RuleID:      generic-api-key' 'File:        creds.txt' \
    '1:00PM INF 1 commits scanned.' '1:00PM WRN leaks found: 1' > "$ASTUB/gitleaks-history.out"
  printf '3\n' > "$ASTUB/gitleaks-history.rc"
  local rc json="$AREPO/.review/findings.json"
  run_review_analyzers "$AREPO" "$ASTUB" main; rc=$?

  assert "g11: a history leak is a critical finding" \
    jq -e '[.findings[] | select(.severity == "critical" and .lens == "gitleaks")] | length == 1' "$json"
  assert "g11: … carrying gitleaks' output" jq -e '.findings[0].evidence | contains("generic-api-key")' "$json"
  assert "g11: … alongside the lens findings, renumbered" \
    jq -e '[.findings[].id] == ["F1", "F2"] and .findings[1].title == "lens finding"' "$json"
  assert "g11: findings.md lists it" grep -qF 'Secret in branch commit history' "$AREPO/.review/findings.md"
  assert "g11: secrets_scan says leaks" jq -e '.secrets_scan == "leaks" and .complete == true' "$json"
  assert "g11: the finding cites the gitleaks section" \
    test "$(sed -n "$(jq -r '.findings[0].line_start' "$json")p" "$AREPO/.review/raw/analyzers.txt")" = '### gitleaks (secrets)'
  assert "g11: exit 0 without --fail-on" test "$rc" -eq 0
  run_review_analyzers "$AREPO" "$ASTUB" main --fail-on critical; rc=$?
  assert "g11: --fail-on critical exits 2" test "$rc" -eq 2

  analyzer_repo g11b
  ( cd "$AREPO" && printf 'change\n' >> src.txt )
  printf '%s\n' 'RuleID:      generic-api-key' '1:00PM WRN leaks found: 1' > "$ASTUB/gitleaks-pipe.out"
  printf '3\n' > "$ASTUB/gitleaks-pipe.rc"
  run_review_analyzers "$AREPO" "$ASTUB" --uncommitted
  assert "g11: a net-diff leak is a critical finding too" \
    jq -e '[.findings[] | select(.severity == "critical" and .title == "Secret in the change set")] | length == 1' \
    "$AREPO/.review/findings.json"

  rm -f "$ASTUB/correctness.json"
  ( cd "$AREPO" && git add -A && git commit -qm change )
  run_review_analyzers "$AREPO" "$ASTUB" main
  assert "g11: with every lens failed, the leak is still a finding" \
    jq -e '.complete == false and .secrets_scan == "leaks" and .changed_files == 1
           and ([.findings[] | select(.lens == "gitleaks")] | length == 1)' "$AREPO/.review/findings.json"
  assert "g11: … and findings.md says so" grep -qF 'gitleaks found a secret' "$AREPO/.review/findings.md"
}

# A failed scan on a non-empty diff left complete:true. Regression for #35.
test_gitleaks_failure_on_a_nonempty_diff_is_incomplete() {
  analyzer_repo g12
  ( cd "$AREPO" && printf 'change\n' >> src.txt && git add -A && git commit -qm change )
  printf '1:00PM FTL unable to load gitleaks config\n' > "$ASTUB/gitleaks-history.out"
  printf '1\n' > "$ASTUB/gitleaks-history.rc"
  local json="$AREPO/.review/findings.json"
  run_review_analyzers "$AREPO" "$ASTUB" main

  assert "g12: a failed history scan is complete:false" \
    jq -e '.complete == false and .lenses_failed == [] and .secrets_scan == "failed"' "$json"
  assert "g12: findings.md says the secret scan FAILED" grep -qF 'secret scan FAILED' "$AREPO/.review/findings.md"
  assert "g12: … and not that the run was clean" grep -qF 'the run was incomplete' "$AREPO/.review/findings.md"

  rm -f "$ASTUB/gitleaks-history.out" "$ASTUB/gitleaks-history.rc"
  run_review_analyzers "$AREPO" "$ASTUB" main
  assert "g12: a clean scan stays complete" jq -e '.complete == true and .secrets_scan == "clean"' "$json"

  printf '%s\n' 'RuleID:      generic-api-key' '1:00PM ERR [git] fatal: partial' \
    '1:00PM INF 1 commits scanned.' '1:00PM WRN leaks found: 1' > "$ASTUB/gitleaks-history.out"
  printf '3\n' > "$ASTUB/gitleaks-history.rc"
  run_review_analyzers "$AREPO" "$ASTUB" main
  assert "g12: a leak from a scan that also failed is still a critical finding" \
    jq -e '.complete == false and ([.findings[] | select(.lens == "gitleaks")] | length == 1)' "$json"

  chmod 000 "$AREPO/.review/rubric.md"
  if [ -r "$AREPO/.review/rubric.md" ]; then
    skip_test "g12: running as root; cannot make the rubric unreadable"
  else
    run_review_analyzers "$AREPO" "$ASTUB" main
    assert "g12: a run that dies after the scan keeps the leak" \
      jq -e '.complete == false and .changed_files == 1 and .secrets_scan == "failed"
             and ([.findings[] | select(.lens == "gitleaks")] | length == 1)' "$json"
  fi
  chmod 644 "$AREPO/.review/rubric.md"

  analyzer_repo g12b
  ( cd "$AREPO" && printf 'change\n' >> src.txt )
  printf '1:00PM FTL unable to load gitleaks config\n' > "$ASTUB/gitleaks-pipe.out"
  printf '1\n' > "$ASTUB/gitleaks-pipe.rc"
  run_review_analyzers "$AREPO" "$ASTUB" --uncommitted
  assert "g12: a failed net-diff scan is complete:false too" jq -e '.complete == false' "$AREPO/.review/findings.json"
}

test_gitleaks_uncommitted_scans_diff_only() {
  analyzer_repo g6
  ( cd "$AREPO" && printf 'change\n' >> src.txt )
  run_review_analyzers "$AREPO" "$ASTUB" --uncommitted
  assert_not "g6: uncommitted mode has no history scan" grep -qF -- '--log-opts' "$ASTUB/gitleaks.calls"
  assert     "g6: uncommitted mode scans the diff" grep -qF -- '--pipe' "$ASTUB/gitleaks.calls"
}

# A branch whose commits net out to no diff never reached the analyzers: the
# zero-change exit reported complete:true and gitleaks never ran. Regression
# for #19. The history scan runs there now, and its outcome is the report.
reverted_secret_branch() { # reverted_secret_branch <id> — $AREPO: add a secret, then revert it
  analyzer_repo "$1"
  ( cd "$AREPO" && printf 'api_key = "%s"\n' "not-a-real-key-0123456789" > creds.txt \
      && git add -A && git commit -qm 'add creds' && git rm -q creds.txt && git commit -qm 'drop creds' )
}

test_gitleaks_scans_history_of_an_empty_net_diff() {
  reverted_secret_branch g7
  local mb rc; mb="$(git -C "$AREPO" merge-base main HEAD)"
  printf '%s\n' 'Finding:     REDACTED' 'RuleID:      generic-api-key' 'File:        creds.txt' \
    '1:00PM INF 2 commits scanned.' '1:00PM WRN leaks found: 1' > "$ASTUB/gitleaks-history.out"
  printf '3\n' > "$ASTUB/gitleaks-history.rc"
  run_review_analyzers "$AREPO" "$ASTUB" main; rc=$?
  local json="$AREPO/.review/findings.json"

  assert     "g7: the net diff is empty" grep -qF 'no changes to review' "$LOG"
  assert     "g7: history scanned with --log-opts=--remerge-diff <merge-base>..HEAD" grep -qF -- "--log-opts=--remerge-diff $mb..HEAD" "$ASTUB/gitleaks.calls"
  assert     "g7: the leak is a critical finding" \
    jq -e '[.findings[] | select(.severity == "critical" and .lens == "gitleaks")] | length == 1' "$json"
  assert     "g7: … carrying gitleaks' output" jq -e '.findings[0].evidence | contains("generic-api-key")' "$json"
  assert     "g7: history_scan names the leak" jq -e '.history_scan == {commits: 2, result: "leaks"}' "$json"
  assert     "g7: findings.md says so" grep -qF 'SECRET IN BRANCH HISTORY' "$AREPO/.review/findings.md"
  assert_not "g7: findings.md is not a bare no-changes report" \
    test "$(grep -c . < "$AREPO/.review/findings.md")" -le 2
  assert     "g7: exit 0 without --fail-on" test "$rc" -eq 0
  run_review_analyzers "$AREPO" "$ASTUB" main --fail-on high; rc=$?
  assert     "g7: --fail-on high exits 2" test "$rc" -eq 2

  rm -f "$ASTUB/gitleaks-history.out" "$ASTUB/gitleaks-history.rc"
  run_review_analyzers "$AREPO" "$ASTUB" main
  assert     "g7: a clean history scan still reviewed nothing" jq -e '.complete == false and .findings == []' "$json"
  assert     "g7: … and says it scanned" jq -e '.history_scan.result == "clean" and .secrets_scan == "clean"' "$json"

  analyzer_repo g7b
  : > "$ASTUB/gitleaks.calls"
  run_review_analyzers "$AREPO" "$ASTUB" main
  assert     "g7: no commits takes the zero-change exit" \
    sh -c 'grep -qF "no changes to review" "$1" && jq -e ".complete == false" "$2"' _ "$LOG" "$AREPO/.review/findings.json"
  assert_not "g7: no commits, no history scan" grep -q . "$ASTUB/gitleaks.calls"
  assert     "g7: … and no history_scan field" jq -e 'has("history_scan") | not' "$AREPO/.review/findings.json"
}

test_gitleaks_failure_on_empty_net_diff_is_failed() {
  reverted_secret_branch g8
  printf '1:00PM FTL unable to load gitleaks config\n' > "$ASTUB/gitleaks-history.out"
  printf '1\n' > "$ASTUB/gitleaks-history.rc"
  run_review_analyzers "$AREPO" "$ASTUB" main
  local json="$AREPO/.review/findings.json"

  assert "g8: a failed scan is complete:false" jq -e '.complete == false' "$json"
  assert "g8: history_scan names the failure" jq -e '.history_scan.result == "failed"' "$json"
  assert "g8: findings.md says FAILED" grep -qF 'FAILED' "$AREPO/.review/findings.md"
  assert "g8: the report says SCAN FAILED" grep -qF 'SCAN FAILED (rc=1' "$AREPO/.review/raw/analyzers.txt"
  assert "g8: secrets_scan says failed" jq -e '.secrets_scan == "failed"' "$json"

  printf '%s\n' 'RuleID:      generic-api-key' '1:00PM ERR [git] fatal: partial' \
    '1:00PM INF 2 commits scanned.' '1:00PM WRN leaks found: 1' > "$ASTUB/gitleaks-history.out"
  printf '3\n' > "$ASTUB/gitleaks-history.rc"
  run_review_analyzers "$AREPO" "$ASTUB" main
  assert "g8: a leak from a scan that also failed is still a critical finding" \
    jq -e '.secrets_scan == "failed" and ([.findings[] | select(.severity == "critical")] | length == 1)' "$json"
  assert "g8: … and findings.md says so" grep -qF 'SECRET IN BRANCH HISTORY' "$AREPO/.review/findings.md"

  printf '%s\n' '1:00PM INF 0 commits scanned.' '1:00PM INF no leaks found' > "$ASTUB/gitleaks-history.out"
  printf '0\n' > "$ASTUB/gitleaks-history.rc"
  run_review_analyzers "$AREPO" "$ASTUB" main
  assert "g8: 0 commits scanned of a range that added lines is FAILED" jq -e '.complete == false' "$json"
}

path_without() { # path_without <tool>... — $PATH minus every dir holding one of them
  local d t p="" IFS=:
  for d in $PATH; do
    for t in "$@"; do [ -x "$d/$t" ] && continue 2; done
    p="$p${p:+:}$d"
  done
  printf '%s\n' "$p"
}

test_gitleaks_missing_on_empty_net_diff_is_named() {
  reverted_secret_branch g9
  local p json="$AREPO/.review/findings.json"
  p="$(path_without gitleaks)"
  if ! PATH="$p" command -v git >/dev/null || ! PATH="$p" command -v jq >/dev/null; then
    skip_test "g9: gitleaks shares a PATH dir with git or jq; cannot hide it"; return
  fi
  ( cd "$AREPO" && PATH="$WORK/bin:$p" CODEX_STUB_DIR="$ASTUB" REVIEW_SKIP_AUTH_CHECK=1 \
      bash scripts/review.sh --lenses correctness main ) > "$AREPO.log" 2>&1
  assert "g9: history_scan says not scanned" jq -e '.history_scan.result == "not_scanned"' "$json"
  assert "g9: … and an unscanned history is not complete" jq -e '.complete == false and .secrets_scan == "not_scanned"' "$json"
  assert "g9: findings.md says the history was NOT scanned" \
    grep -qF 'NOT scanned for secrets: gitleaks is not installed' "$AREPO/.review/findings.md"
  assert "g9: … and so does stderr" grep -qF 'not scanned for secrets: gitleaks is not installed' "$AREPO.log"

  run_review "$AREPO" "$ASTUB" --lenses correctness
  assert "g9: --no-analyzers is named too" \
    grep -qF 'NOT scanned for secrets: --no-analyzers' "$AREPO/.review/findings.md"
}

# `git log -p` prints no patch for a merge without -m, so a secret that only
# merge resolutions add and remove was in no scanned patch. Regression for #36.
merge_resolution_secret_branch() { # merge_resolution_secret_branch <id> — $AREPO: a secret only merges carry
  analyzer_repo "$1"
  (
    cd "$AREPO" || exit 1
    git checkout -q main && printf 'main 1\n' >> src.txt && git commit -qam 'main 1'
    git checkout -q change && git merge -q --no-ff --no-commit main
    printf 'api_key = "%s"\n' "not-a-real-key-0123456789" > creds.txt
    git add creds.txt && git commit -qm 'merge main'
    git checkout -q main && printf 'main 2\n' >> src.txt && git commit -qam 'main 2'
    git checkout -q change && git merge -q --no-ff --no-commit main
    git rm -q creds.txt && git commit -qm 'merge main again'
  )
}

test_gitleaks_scans_merge_resolutions() {
  merge_resolution_secret_branch g13
  printf 'not-a-real-key\n' > "$ASTUB/gitleaks-history.git"
  local json="$AREPO/.review/findings.json"
  run_review_analyzers "$AREPO" "$ASTUB" main

  assert "g13: the net diff is empty" grep -qF 'no changes to review' "$LOG"
  assert "g13: the history scan is merge-aware" grep -qF -- '--log-opts=--remerge-diff ' "$ASTUB/gitleaks.calls"
  assert "g13: a secret only merge resolutions carried is found" \
    jq -e '.history_scan.result == "leaks" and ([.findings[] | select(.severity == "critical")] | length == 1)' "$json"

  rm -f "$ASTUB/gitleaks-history.git"
  printf '%s\n' '1:00PM INF 0 commits scanned.' '1:00PM INF no leaks found' > "$ASTUB/gitleaks-history.out"
  run_review_analyzers "$AREPO" "$ASTUB" main
  assert "g13: 0 commits scanned of merges that add lines is FAILED" \
    jq -e '.history_scan.result == "failed"' "$json"

  # A git without --remerge-diff falls back to -m, never to no merge flag.
  local real; real="$(command -v git)"
  mkdir -p "$WORK/g13-bin"
  printf '#!/bin/sh\ncase " $* " in *" --remerge-diff "*) echo "fatal: unrecognized argument" >&2; exit 128 ;; esac\nexec %s "$@"\n' \
    "$real" > "$WORK/g13-bin/git"
  chmod +x "$WORK/g13-bin/git"
  rm -f "$ASTUB/gitleaks-history.out"; : > "$ASTUB/gitleaks.calls"
  printf 'not-a-real-key\n' > "$ASTUB/gitleaks-history.git"
  PATH="$WORK/g13-bin:$PATH" run_review_analyzers "$AREPO" "$ASTUB" main
  assert "g13: without --remerge-diff the scan uses -m" grep -qF -- '--log-opts=-m ' "$ASTUB/gitleaks.calls"
  assert "g13: … and still finds the secret" jq -e '.history_scan.result == "leaks"' "$json"

  # A secret main already carries is not branch history.
  analyzer_repo g13b
  (
    cd "$AREPO" || exit 1
    printf 'x\n' > b.txt && git add b.txt && git commit -qm 'branch change'
    git checkout -q main && printf 'api_key = "%s"\n' "not-a-real-key-0123456789" > main-creds.txt
    git add main-creds.txt && git commit -qm 'main carries a secret'
    git checkout -q change && git merge -q --no-edit main
  )
  printf 'not-a-real-key\n' > "$ASTUB/gitleaks-history.git"
  run_review_analyzers "$AREPO" "$ASTUB" main
  assert "g13: a secret merged in from main is not reported as branch history" \
    jq -e '.secrets_scan == "clean" and .findings == []' "$AREPO/.review/findings.json"
}

# A run with nothing to review said complete:true, like a clean review, so a
# wrong BASE read as a pass. Regression for #37.
test_zero_change_run_is_not_a_review() {
  analyzer_repo g14
  ( cd "$AREPO" && printf 'change\n' >> src.txt && git add -A && git commit -qm change )
  local json="$AREPO/.review/findings.json"
  run_review_analyzers "$AREPO" "$ASTUB" HEAD
  assert "g14: BASE == HEAD reviewed nothing" \
    jq -e '.complete == false and .changed_files == 0 and .secrets_scan == "not_scanned"' "$json"
  assert "g14: findings.md says so" grep -qF 'Nothing was reviewed' "$AREPO/.review/findings.md"

  run_review_analyzers "$AREPO" "$ASTUB" --uncommitted
  assert "g14: --uncommitted on a clean tree reviewed nothing" \
    jq -e '.complete == false and .changed_files == 0' "$json"

  run_review_analyzers "$AREPO" "$ASTUB" main
  assert "g14: a real review counts its files" \
    jq -e '.complete == true and .changed_files == 1 and .secrets_scan == "clean"' "$json"
  assert "g14: adjudication refuses a verdict from a zero-change run" \
    grep -qF '`changed_files` is 0' "$KIT/.review/adjudication.md"
}

# A missing gitleaks or semgrep left no section at all, so "not installed" read
# the same as "clean". Regression for #37.
test_missing_gitleaks_and_semgrep_are_named() {
  analyzer_repo g15
  ( cd "$AREPO" && printf 'change\n' >> src.txt && git add -A && git commit -qm change )
  local p report="$AREPO/.review/raw/analyzers.txt"
  p="$(path_without gitleaks semgrep)"
  if ! PATH="$p" command -v git >/dev/null || ! PATH="$p" command -v jq >/dev/null; then
    skip_test "g15: gitleaks or semgrep shares a PATH dir with git or jq; cannot hide it"; return
  fi
  ( cd "$AREPO" && PATH="$WORK/bin:$p" CODEX_STUB_DIR="$ASTUB" REVIEW_SKIP_AUTH_CHECK=1 \
      bash scripts/review.sh --lenses correctness main ) > "$AREPO.log" 2>&1
  assert "g15: a missing gitleaks is named" \
    section_has "$report" "gitleaks (secrets)" 'analyzer skipped: gitleaks is not installed'
  assert "g15: a missing semgrep is named" grep -qF 'analyzer skipped: semgrep is not installed' "$report"
  assert "g15: findings.md says secrets were NOT checked" \
    grep -qF 'Secrets were NOT checked: gitleaks is not installed' "$AREPO/.review/findings.md"
  assert "g15: … and findings.json says not_scanned" \
    jq -e '.secrets_scan == "not_scanned" and .complete == true' "$AREPO/.review/findings.json"

  run_review "$AREPO" "$ASTUB" --lenses correctness
  assert "g15: --no-analyzers is not_scanned too" \
    sh -c 'jq -e ".secrets_scan == \"not_scanned\"" "$1" && grep -qF "Secrets were NOT checked: --no-analyzers" "$2"' \
    _ "$AREPO/.review/findings.json" "$AREPO/.review/findings.md"

  analyzer_repo g15b
  (
    cd "$AREPO" || exit 1
    git rm -rq --cached .review/raw .review/findings.md && cp "$KIT/.review/.gitignore" .review/
    git add -A && git commit -qm 'ignore generated artifacts'
    mkdir nested && git -C nested init -q && printf 'x\n' > nested/f
  )
  run_review_analyzers "$AREPO" "$ASTUB" --uncommitted
  assert "g15: an empty diff says secrets were NOT checked" \
    sh -c 'jq -e ".secrets_scan == \"not_scanned\"" "$1" && grep -qF "Secrets were NOT checked: no diff to scan" "$2"' \
    _ "$AREPO/.review/findings.json" "$AREPO/.review/findings.md"
}

# The changed-file list is newline-delimited: a name with a space is one path.
test_semgrep_gets_whole_paths() {
  analyzer_repo sg1
  ( cd "$AREPO" && printf 'x\n' > 'a b.txt' && git add -A && git commit -qm 'spaced name' )
  run_review_analyzers "$AREPO" "$ASTUB" main
  assert     "sg1: spaced name passed as one argument" grep -qxF 'a b.txt' "$ASTUB/semgrep.args"
  assert_not "sg1: name not split" grep -qxF 'a' "$ASTUB/semgrep.args"
  assert     "sg1: clean run says so" grep -qF 'semgrep: no findings in' "$AREPO/.review/raw/analyzers.txt"
}

# semgrep_case <id> <rc> <stdout> [stderr] — one run with a scripted semgrep
semgrep_case() {
  analyzer_repo "$1"
  printf '%s\n' "$2" > "$ASTUB/semgrep.rc"
  printf '%s' "$3" > "$ASTUB/semgrep.out"
  [ -z "${4:-}" ] || printf '%s\n' "$4" > "$ASTUB/semgrep.err"
  ( cd "$AREPO" && printf 'change\n' >> src.txt && git add -A && git commit -qm change )
  run_review_analyzers "$AREPO" "$ASTUB" main
  SG_REPORT="$AREPO/.review/raw/analyzers.txt"
}

# With --error, rc 1 is findings; rc 2+ or output that isn't semgrep JSON is a
# failed scan, which used to leave the section empty — read as clean.
test_semgrep_failure_is_named() {
  semgrep_case sg2 1 '{"results":[{"path":"src.txt","start":{"line":1},"check_id":"rule.x","extra":{"message":"bad"}}],"errors":[]}'
  assert     "sg2: rc 1 lists the finding" grep -qF -- '- src.txt:1 [rule.x] bad' "$SG_REPORT"
  assert_not "sg2: rc 1 is not FAILED" grep -qF 'semgrep FAILED' "$SG_REPORT"

  semgrep_case sg3 2 '' 'semgrep: invalid configuration'
  assert "sg3: rc 2 is FAILED" grep -qF 'semgrep FAILED (rc=2)' "$SG_REPORT"
  assert "sg3: FAILED carries stderr" grep -qF 'invalid configuration' "$SG_REPORT"

  semgrep_case sg4 0 ''
  assert "sg4: rc 0 with no JSON is FAILED" grep -qF 'semgrep FAILED (rc=0)' "$SG_REPORT"

  semgrep_case sg5 0 '{"results":[],"errors":[{"type":"Syntax error","message":"src.txt: parse failure"}]}'
  assert "sg5: per-file errors are named" grep -qF 'some files or rules were NOT scanned' "$SG_REPORT"
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
# field outranks a stray lockfile. yarn classic and bun must call
# node_modules/.bin directly (their `run` prefers a same-named package.json
# script): the stub resolves only via the runner named in $ASTUB/runner, so a
# `yarn run`/`bun run` call fails these cases. Regression for #18.
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
    assert_js_sections_nonempty "$id" tsc
  done <<'EOF'
j1~printf '{"packageManager":"pnpm@9.1.0"}' > package.json; : > package-lock.json~pnpm~pnpm exec eslint
j2~printf '{"packageManager":"yarn@4.1.0+sha512.abc"}' > package.json~yarn~yarn exec eslint
j3~printf '{"packageManager":"yarn@1.22.19"}' > package.json; bin_stubs~bin~node_modules/.bin/eslint
j4~printf '{"packageManager":"bun@1.1.0"}' > package.json; bin_stubs~bin~node_modules/.bin/eslint
j5~printf '{"packageManager":"npm@10.2.0"}' > package.json~npx~npx --no-install eslint
j6~printf '{}' > package.json; : > pnpm-lock.yaml~pnpm~pnpm exec eslint
j7~printf '{}' > package.json; printf '# yarn lockfile v1\n' > yarn.lock; bin_stubs~bin~node_modules/.bin/eslint
j8~printf '{}' > package.json; printf '__metadata:\n  version: 8\n' > yarn.lock~yarn~yarn exec eslint
j9~printf '{}' > package.json; : > bun.lock; bin_stubs~bin~node_modules/.bin/eslint
j10~printf '{}' > package.json; printf '{}' > package-lock.json~npx~npx --no-install eslint
j15~printf '{}' > package.json; : > yarn.lock; : > .yarnrc.yml~yarn~yarn exec eslint
j16~printf '{}' > package.json; : > bun.lockb; bin_stubs~bin~node_modules/.bin/eslint
EOF
}

# A tool the runner cannot resolve gets a named skip line, never an empty section.
test_js_unresolvable_tool_is_named() {
  js_review j11 "printf '{}' > package.json; : > pnpm-lock.yaml; printf '{}' > tsconfig.json; echo pnpm > '$WORK/j11-stub/runner'"
  assert "j11: eslint skip names the runner" \
    grep -qF 'analyzer skipped: eslint not resolvable via pnpm exec (pnpm-lock.yaml)' "$JS_REPORT"
  assert "j11: tsc skip names the runner" \
    grep -qF 'analyzer skipped: tsc not resolvable via pnpm exec' "$JS_REPORT"
  assert_js_sections_nonempty j11 tsc
}

# eslint 9 with no config exits 2 with empty stdout: that is a failed lint, not a clean one.
test_js_eslint_crash_is_failed() {
  mkdir -p "$WORK/j12-stub"
  printf 'pnpm\n' > "$WORK/j12-stub/runner"; printf '2\n' > "$WORK/j12-stub/eslint.rc"
  js_review j12 "printf '{}' > package.json; : > pnpm-lock.yaml"
  assert "j12: eslint rc 2 is FAILED" grep -qF 'eslint FAILED (rc=2)' "$JS_REPORT"
  assert_js_sections_nonempty j12 tsc
}

# A clean run says so, and a root tsconfig with references is type-checked with
# --build, without emitting where TypeScript allows it.
test_js_clean_run_and_tsc_build() {
  mkdir -p "$WORK/j13-stub"
  printf 'pnpm\n' > "$WORK/j13-stub/runner"
  printf '0\n' > "$WORK/j13-stub/eslint.rc"; printf '0\n' > "$WORK/j13-stub/tsc.rc"
  js_review j13 "printf '{}' > package.json; : > pnpm-lock.yaml; printf '{\"files\":[],\"references\":[{\"path\":\"pkg\"}]}' > tsconfig.json"
  assert "j13: clean eslint says so" grep -qF 'eslint: no errors in 1 file(s)' "$JS_REPORT"
  assert "j13: references root runs tsc --build --noEmit" grep -qxF 'pnpm exec tsc --build --noEmit --pretty false' "$ASTUB/runner.calls"
  assert "j13: clean tsc says so" grep -qF 'tsc --build --noEmit: no errors' "$JS_REPORT"
  assert_js_sections_nonempty j13 tsc
}

# eslint warnings exit 0: the clean line still leads, the warnings follow it.
test_js_eslint_warnings_keep_clean_line() {
  mkdir -p "$WORK/j20-stub"
  printf 'pnpm\n' > "$WORK/j20-stub/runner"; printf '0\n' > "$WORK/j20-stub/eslint.rc"
  printf 'app.ts:1:1  warning  prefer-const\n' > "$WORK/j20-stub/eslint.out"
  js_review j20 "printf '{}' > package.json; : > pnpm-lock.yaml"
  assert "j20: clean line present" grep -qF 'eslint: no errors in 1 file(s)' "$JS_REPORT"
  assert "j20: clean line leads the warnings" \
    sh -c 'section_body() { awk -v h="### eslint" "\$0 == h { on = 1; next } /^### / { on = 0 } on" "$1"; }
           [ "$(section_body "$1" | grep . | head -n 1)" = "eslint: no errors in 1 file(s)" ]' _ "$JS_REPORT"
  assert "j20: warning kept" grep -qF 'warning  prefer-const' "$JS_REPORT"
}

# Located type errors are findings; a config error checked nothing and is FAILED.
test_js_tsc_findings_vs_failure() {
  mkdir -p "$WORK/j17-stub" "$WORK/j18-stub"
  printf 'pnpm\n' > "$WORK/j17-stub/runner"; printf '2\n' > "$WORK/j17-stub/tsc.rc"
  printf "app.ts(1,14): error TS2322: Type 'string' is not assignable to type 'number'.\n" > "$WORK/j17-stub/tsc.out"
  js_review j17 "printf '{}' > package.json; : > pnpm-lock.yaml; printf '{}' > tsconfig.json"
  assert     "j17: type error reported" grep -qF 'error TS2322' "$JS_REPORT"
  assert_not "j17: type error is not FAILED" grep -qF 'tsc --noEmit FAILED' "$JS_REPORT"

  printf 'pnpm\n' > "$WORK/j18-stub/runner"; printf '1\n' > "$WORK/j18-stub/tsc.rc"
  printf "error TS18003: No inputs were found in config file 'tsconfig.json'.\n" > "$WORK/j18-stub/tsc.out"
  js_review j18 "printf '{}' > package.json; : > pnpm-lock.yaml; printf '{}' > tsconfig.json"
  assert "j18: config error is FAILED" grep -qF 'tsc --noEmit FAILED (rc=1)' "$JS_REPORT"
}

# TypeScript < 5.6 rejects --build --noEmit (TS5094). Plain --build would write
# build output into the tree, so it is a named skip instead.
test_js_tsc_build_skipped_before_ts56() {
  mkdir -p "$WORK/j19-stub"
  printf 'pnpm\n' > "$WORK/j19-stub/runner"; printf '0\n' > "$WORK/j19-stub/tsc.rc"
  cat > "$WORK/j19-stub/tsc.sh" <<'EOF'
case " $* " in
  *" --noEmit "*) echo "error TS5094: Compiler option '--noEmit' may not be used with '--build'."; exit 1 ;;
esac
exit 0
EOF
  js_review j19 "printf '{}' > package.json; : > pnpm-lock.yaml; printf '{\"references\":[{\"path\":\"pkg\"}]}' > tsconfig.json"
  assert_not "j19: never runs an emitting tsc --build" grep -qxF 'pnpm exec tsc --build --pretty false' "$ASTUB/runner.calls"
  assert     "j19: named skip" grep -qF 'analyzer skipped: tsc --build --noEmit needs TypeScript >= 5.6' "$JS_REPORT"
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

# A spoke runs ITS OWN copy of the updater, which the sync overwrites. When the
# hub's copy is longer, bash must not read past main() into the new file.
# Regression for the clean sync that exited 2 with "syntax error".
test_update_survives_replacing_itself() {
  local hub="$WORK/u12-hub" spoke="$WORK/u12-spoke"
  make_hub "$hub"; make_spoke "$spoke"
  mkdir -p "$spoke/scripts"
  cp "$KIT/scripts/review-update.sh" "$spoke/scripts/"
  (
    cd "$hub" || exit 1
    printf 'echo TAIL-EXECUTED >&2; exit 7\n%.0s' 1 2 3 4 5 6 7 8 >> scripts/review-update.sh
    git commit -aqm longer-updater
  )
  LOG="$spoke.log"
  ( cd "$spoke" && env -i HOME="$WORK/nohome" PATH="$PATH" REVIEW_KIT_DIR="$hub" \
      bash scripts/review-update.sh ) > "$LOG" 2>&1; local rc=$?

  assert     "u12: run exits 0" test "$rc" -eq 0
  assert_not "u12: no syntax error" grep -q 'syntax error' "$LOG"
  assert_not "u12: no bytes of the new file executed" grep -q 'TAIL-EXECUTED' "$LOG"
  assert     "u12: the longer updater was installed" grep -q 'TAIL-EXECUTED' "$spoke/scripts/review-update.sh"
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

make_tagged_hub() { # make_tagged_hub <dir> — annotated v0.9.0, then an untagged tip on main
  make_hub "$1"
  (
    cd "$1" || exit 1
    printf 'MARKER: nine\n' >> REVIEW.md && git commit -aqm nine \
      && git -c tag.gpgSign=false tag -a -m nine v0.9.0
    printf 'MARKER: tip\n'  >> REVIEW.md && git commit -aqm tip
  )
}

# REVIEW_KIT_REF names a pin, so a branch — mutable by definition — is refused
# rather than fetched. Regression for REVIEW_KIT_REF=main installing the tip.
test_update_network_refuses_a_branch_ref() {
  local hub="$WORK/u13-hub" spoke="$WORK/u13-spoke"
  make_tagged_hub "$hub"; make_spoke "$spoke"
  run_update "$spoke" REVIEW_KIT_URL="file://$hub" REVIEW_KIT_REF=main; local rc=$?

  assert     "u13: run refuses" test "$rc" -ne 0
  assert     "u13: refusal says it is not a tag" grep -q "'main' is not a tag" "$LOG"
  assert_not "u13: nothing synced" test -f "$spoke/.review/kit-version"
  assert_not "u13: branch tip content NOT installed" grep -qs 'MARKER: tip' "$spoke/REVIEW.md"
}

# A full commit SHA is a pin too, and is recorded as given. An annotated tag
# installs the commit it points at.
test_update_network_honors_a_commit_sha() {
  local hub="$WORK/u14-hub" spoke="$WORK/u14-spoke" sha
  make_tagged_hub "$hub"; make_spoke "$spoke"
  sha="$(git -C "$hub" rev-parse 'v0.9.0^{commit}')"
  run_update "$spoke" REVIEW_KIT_URL="file://$hub" REVIEW_KIT_REF="$sha"; local rc=$?

  assert     "u14: run exits 0" test "$rc" -eq 0
  assert     "u14: pinned commit content installed" grep -q 'MARKER: nine' "$spoke/REVIEW.md"
  assert_not "u14: branch tip content NOT installed" grep -q 'MARKER: tip' "$spoke/REVIEW.md"
  assert     "u14: kit-version records the SHA" grep -q "^ref: $sha\$" "$spoke/.review/kit-version"

  rm -rf "$spoke"; make_spoke "$spoke"
  run_update "$spoke" REVIEW_KIT_URL="file://$hub" REVIEW_KIT_REF=v0.9.0; rc=$?
  assert     "u14: annotated tag exits 0" test "$rc" -eq 0
  assert     "u14: annotated tag content installed" grep -q 'MARKER: nine' "$spoke/REVIEW.md"
  assert     "u14: annotated tag installs its commit" \
    grep -q "^kit: .* ${sha:0:7}" "$spoke/.review/kit-version"
}

# An unreachable hub and a missing tag both refuse, but must not read alike:
# one is a connection to fix, the other a pin to correct.
test_update_network_tells_unreachable_from_missing() {
  local hub="$WORK/u15-hub" spoke="$WORK/u15-spoke" gone="file://$WORK/u15-nowhere"
  make_tagged_hub "$hub"; make_spoke "$spoke"

  run_update "$spoke" REVIEW_KIT_URL="file://$hub" REVIEW_KIT_REF=v9.9.9; local rc=$?
  assert     "u15: missing tag refuses" test "$rc" -ne 0
  assert     "u15: missing tag says so" grep -q "'v9.9.9' is not a tag" "$LOG"
  assert_not "u15: missing tag is not called unreachable" grep -q 'cannot reach' "$LOG"

  run_update "$spoke" REVIEW_KIT_URL="$gone" REVIEW_KIT_REF=v0.9.0; rc=$?
  assert     "u15: unreachable hub refuses" test "$rc" -ne 0
  assert     "u15: unreachable hub says so" grep -q 'cannot reach' "$LOG"
  assert_not "u15: unreachable hub is not called a missing tag" grep -q 'is not a tag' "$LOG"

  run_update "$spoke" REVIEW_KIT_URL="$gone"; rc=$?
  assert     "u15: unreachable hub refuses tag discovery" test "$rc" -ne 0
  assert     "u15: tag discovery says unreachable" grep -q 'cannot reach' "$LOG"
  assert_not "u15: tag discovery does not claim no tags" grep -q 'no release tag' "$LOG"
  assert_not "u15: nothing synced" test -f "$spoke/.review/kit-version"
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

# --- no-clone bootstrap ----------------------------------------------------
bootstrap_block() { # bootstrap_block <md file> — the fenced block that runs ls-remote
  awk '/^```bash$/ {inb=1; b=""; next}
       /^```$/ && inb {inb=0; if (b ~ /ls-remote/) printf "%s", b; next}
       inb {b = b $0 "\n"}' "$1"
}

# Runs the onboard bootstrap against a local hub: curl is stubbed to read the
# hub at the commit in the URL, and less is a no-op.
run_bootstrap() { # run_bootstrap <spoke> <hub> [VAR=val ...] — output in $LOG
  local dir="$1" hub="$2"; shift 2
  LOG="$dir.log"
  mkdir -p "$WORK/nohome" "$WORK/bootbin"
  cat > "$WORK/bootbin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
sha="$(printf '%s\n' "$url" | sed -n 's|.*/codex-review-kit/\([^/]*\)/scripts/.*|\1|p')"
git -C "$BOOT_HUB" show "$sha:scripts/review-update.sh" > "$out"
EOF
  printf '#!/bin/sh\nexit 0\n' > "$WORK/bootbin/less"
  chmod +x "$WORK/bootbin/curl" "$WORK/bootbin/less"
  bootstrap_block "$KIT/.claude/commands/review-onboard.md" \
    | sed "s|^\\( *\\)KIT=https://.*|\\1KIT=file://$hub|" > "$dir.boot.sh"
  grep -q "KIT=file://" "$dir.boot.sh" || { echo "run_bootstrap: KIT not redirected" > "$LOG"; return 99; }
  ( cd "$dir" && env -i HOME="$WORK/nohome" PATH="$WORK/bootbin:$PATH" BOOT_HUB="$hub" \
      REVIEW_KIT_URL="file://$hub" "$@" bash "$dir.boot.sh" ) > "$LOG" 2>&1
}

make_boot_hub() { # make_boot_hub <dir> — annotated v0.9.0, untagged tip, stub installer
  make_hub "$1"
  (
    cd "$1" || exit 1
    cp -R "$KIT/templates" .
    printf '#!/bin/sh\necho INSTALL-RAN\n' > scripts/review-install.sh
    printf 'MARKER: nine\n' >> REVIEW.md && git add -A && git commit -qm nine \
      && git -c tag.gpgSign=false tag -a -m nine v0.9.0
    printf 'MARKER: tip\n'  >> REVIEW.md && git commit -aqm tip
  )
}

# REVIEW.md and /review-onboard carry the same no-clone bootstrap; the copy
# nobody tests must not drift from the one that is. It gets pasted into
# interactive shells, and zsh there does not treat `#` as a comment.
test_bootstrap_block_matches_in_both_docs() {
  local a b
  a="$(bootstrap_block "$KIT/.claude/commands/review-onboard.md")"
  b="$(bootstrap_block "$KIT/REVIEW.md")"
  assert "b1: review-onboard has the bootstrap" test -n "$a"
  assert "b1: REVIEW.md carries the same bootstrap" test "$a" = "$b"
  assert_not "b1: no comment lines (interactive zsh runs them)" \
    grep -qE '^[[:space:]]*#' <<< "$a"
}

# The bootstrap installs a release tag — an annotated one resolved to its
# commit — and refuses a branch before anything is downloaded or run.
# Regression for SHA="${SHA:-$REF}" passing REF=main through as the SHA.
test_bootstrap_pins_and_refuses_a_branch() {
  local hub="$WORK/b2-hub" spoke="$WORK/b2-spoke" sha
  make_boot_hub "$hub"; make_spoke "$spoke"
  sha="$(git -C "$hub" rev-parse 'v0.9.0^{commit}')"

  run_bootstrap "$spoke" "$hub"; local rc=$?
  assert     "b2: tag bootstrap exits 0" test "$rc" -eq 0
  assert     "b2: tag content installed" grep -q 'MARKER: nine' "$spoke/REVIEW.md"
  assert_not "b2: branch tip content NOT installed" grep -q 'MARKER: tip' "$spoke/REVIEW.md"
  assert     "b2: kit-version records the tag's commit" grep -q "^ref: $sha\$" "$spoke/.review/kit-version"
  assert     "b2: installer ran" grep -q 'INSTALL-RAN' "$LOG"

  rm -rf "$spoke"; make_spoke "$spoke"
  run_bootstrap "$spoke" "$hub" REVIEW_KIT_REF=main; rc=$?
  assert     "b2: branch refused" test "$rc" -ne 0
  assert     "b2: refusal says it is not a tag" grep -q "'main' is neither a tag" "$LOG"
  assert_not "b2: nothing synced" test -f "$spoke/.review/kit-version"
}

# As in the updater: an unreachable hub and a missing tag stop with different words.
test_bootstrap_tells_unreachable_from_missing() {
  local hub="$WORK/b3-hub" spoke="$WORK/b3-spoke"
  make_boot_hub "$hub"; make_spoke "$spoke"

  run_bootstrap "$spoke" "$hub" REVIEW_KIT_REF=v9.9.9; local rc=$?
  assert     "b3: missing tag stops" test "$rc" -ne 0
  assert     "b3: missing tag says so" grep -q "'v9.9.9' is neither a tag" "$LOG"
  assert_not "b3: missing tag is not called unreachable" grep -q 'cannot reach' "$LOG"

  run_bootstrap "$spoke" "$WORK/b3-nowhere"; rc=$?
  assert     "b3: unreachable hub stops" test "$rc" -ne 0
  assert     "b3: unreachable hub says so" grep -q 'cannot reach' "$LOG"
  assert_not "b3: unreachable hub does not claim no tags" grep -q 'no release tag' "$LOG"
  assert_not "b3: nothing synced" test -f "$spoke/.review/kit-version"
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

# A foreign core.hooksPath used to be a `skip`, so --check passed while the
# kit's pre-push hook never ran. It passes now only when that hooks dir chains it.
test_install_check_foreign_hooks_path() {
  local spoke="$WORK/i16-spoke" rc
  make_installed_spoke "$spoke"
  run_install_full "$spoke"
  ( cd "$spoke" && mkdir -p .husky && printf '#!/bin/sh\nnpm test\n' > .husky/pre-push \
      && chmod +x .husky/pre-push && git config core.hooksPath .husky )

  run_install_check "$spoke"; rc=$?
  assert "i16: unchained foreign hooksPath fails --check" test "$rc" -ne 0
  assert "i16: … reported as not wired" grep -qF 'pre-push hook not wired' "$LOG"
  assert "i16: … with a husky example" grep -qF 'e.g. husky' "$LOG"

  printf '.githooks/pre-push "$@" || exit $?\n' >> "$spoke/.husky/pre-push"
  run_install_check "$spoke"; rc=$?
  assert "i16: chained foreign hooksPath passes --check" test "$rc" -eq 0
  assert "i16: … reported as chained" grep -qF '.husky/pre-push chains .githooks/pre-push' "$LOG"
}

# Setting core.hooksPath over live .git/hooks hooks silently disables them.
test_install_keeps_live_git_hooks() {
  local spoke="$WORK/i17-spoke" hooks rc
  make_installed_spoke "$spoke"
  hooks="$(cd "$spoke" && git rev-parse --git-path hooks)"
  printf '#!/bin/sh\ntouch "$(git rev-parse --show-toplevel)/pre-commit-ran"\n' > "$spoke/$hooks/pre-commit"
  chmod +x "$spoke/$hooks/pre-commit"

  LOG="$spoke.install.log"
  ( cd "$spoke" && env -i HOME="$WORK/nohome" PATH="$WORK/bin:$PATH" \
      bash scripts/review-install.sh ) > "$LOG" 2>&1; rc=$?
  assert     "i17: install fails the hook check" grep -qF 'pre-push hook not wired' "$LOG"
  assert     "i17: names the live hook" grep -qF 'live hooks (pre-commit)' "$LOG"
  assert_not "i17: core.hooksPath left unset" sh -c 'cd "$1" && git config --get core.hooksPath' _ "$spoke"
  ( cd "$spoke" && git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m probe ) >/dev/null 2>&1
  assert     "i17: the live hook still runs" test -f "$spoke/pre-commit-ran"

  # a hooks dir that cannot be listed may hold live hooks too
  if [ "$(id -u)" != 0 ]; then
    rm -f "$spoke/$hooks/pre-commit"; chmod 300 "$spoke/$hooks"
    ( cd "$spoke" && env -i HOME="$WORK/nohome" PATH="$WORK/bin:$PATH" \
        bash scripts/review-install.sh ) > "$LOG" 2>&1
    chmod 755 "$spoke/$hooks"
    assert     "i17: an unlistable hooks dir is reported" grep -qF 'cannot be listed' "$LOG"
    assert_not "i17: … and core.hooksPath left unset" sh -c 'cd "$1" && git config --get core.hooksPath' _ "$spoke"
  else
    skip_test "i17: unlistable hooks dir (running as root)"
  fi
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

# Verdicts are gitignored and overwritten each run, so /review-tune had no history
# to mine. Regression for #28: each run archives the verdicts it is about to
# supersede into the clone's git common dir, which every worktree shares and
# which outlives any one of them.
history_dir() { echo "$(cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd -P)/review-history"; }

test_review_archives_the_previous_verdicts() {
  local repo="$WORK/v1" stub="$WORK/v1-stub" hist
  make_repo "$repo"; mkdir -p "$stub"
  printf '# Review verdict — change — abc1234 — 2026-01-01\n\n## Rejected\nF2 — noise\n' > "$repo/.review/verdict.md"
  printf '# Spec verdict — change — def5678 — 2026-01-02\n\n## Rejected\nF1 — spec noise\n' > "$repo/.review/spec-verdict.md"
  run_review "$repo" "$stub" --lenses correctness
  hist="$(history_dir "$repo")"

  assert "v1: the code verdict is archived under the git common dir" \
    sh -c 'cmp -s "$1" "$2"/code-2026-01-01-abc1234-*.md' _ "$repo/.review/verdict.md" "$hist"
  assert "v1: the spec verdict is archived apart from it" \
    sh -c 'cmp -s "$1" "$2"/spec-2026-01-02-def5678-*.md' _ "$repo/.review/spec-verdict.md" "$hist"
  run_review "$repo" "$stub" --lenses correctness
  assert "v1: archiving the same verdicts again adds nothing" test "$(ls "$hist" | grep -c .)" -eq 2
  printf 're-adjudicated\n' >> "$repo/.review/verdict.md"
  run_review "$repo" "$stub" --lenses correctness
  assert "v1: a second verdict on the same commit is kept beside the first" \
    test "$(ls "$hist" | grep -c '^code-2026-01-01-abc1234-')" -eq 2
  printf '# Spec verdict — change — def5678 — 2026-01-02\n\n## Rejected\nF3 — other spec\n' > "$repo/.review/spec-verdict.md"
  run_review "$repo" "$stub" --lenses correctness
  assert "v1: a second spec reviewed on the same commit and day is kept too" \
    test "$(ls "$hist" | grep -c '^spec-2026-01-02-def5678-')" -eq 2

  printf 'no header\n' > "$repo/.review/verdict.md"
  run_review "$repo" "$stub" --lenses correctness
  assert "v1: a headerless verdict is still archived" sh -c 'ls "$1"/code-unparsed-*.md' _ "$hist"
  assert "v1: … with a warning" grep -qF 'has no standard verdict header' "$LOG"
  run_review "$repo" "$stub" --lenses correctness
  assert_not "v1: … only the first time" grep -qF 'has no standard verdict header' "$LOG"
  assert     "v1: … and the run that stayed quiet still reached the archive" \
    sh -c 'grep -qF "no changes to review" "$1" && [ "$(ls "$2" | grep -c "^code-unparsed-")" -eq 1 ]' _ "$LOG" "$hist"
}

test_verdict_archive_is_shared_across_worktrees() {
  local repo="$WORK/v2" stub="$WORK/v2-stub" wt="$WORK/v2-wt"
  make_repo "$repo"; mkdir -p "$stub"
  git -C "$repo" worktree add -q -b wt-branch "$wt" main
  printf '# Review verdict — wt-branch — 1234abc — 2026-01-03\n\nclean\n' > "$wt/.review/verdict.md"
  run_review "$wt" "$stub" --lenses correctness

  assert "v2: a verdict archived from worktree A is visible from worktree B" \
    sh -c 'test -f "$1"/code-2026-01-03-1234abc-*.md' _ "$(history_dir "$repo")"
  git -C "$repo" worktree remove --force "$wt"
  assert "v2: … and still there after A is removed" \
    sh -c 'test -f "$1"/code-2026-01-03-1234abc-*.md' _ "$(history_dir "$repo")"
}

test_verdict_archive_failure_warns_without_failing() {
  local repo="$WORK/v3" stub="$WORK/v3-stub" rc
  make_repo "$repo"; mkdir -p "$stub"
  printf '{"findings":[]}' > "$stub/correctness.json"
  ( cd "$repo" && printf 'change\n' >> src.txt && git add -A && git commit -qm change )
  printf '# Review verdict — change — abc1234 — 2026-01-01\n' > "$repo/.review/verdict.md"
  printf 'not a directory\n' > "$(history_dir "$repo")"
  run_review "$repo" "$stub" --lenses correctness; rc=$?

  assert "v3: an unwritable archive warns" grep -qF 'is not writable — rejection history' "$LOG"
  assert "v3: the run's exit code is unchanged" test "$rc" -eq 0
  assert "v3: … and so is complete" jq -e '.complete == true' "$repo/.review/findings.json"
}

# A worktree's final verdict is written after its last review run, so the run alone
# would never archive it before the worktree is removed. The push does.
test_prepush_archives_the_verdict() {
  local repo="$WORK/v4" stub="$WORK/v4-stub" remote="$WORK/v4-remote.git" short
  hook_repo "$repo" "$stub"
  git init -q --bare "$remote"
  short=$(git -C "$repo" rev-parse --short HEAD)
  printf '# Review verdict — change — %s — 2026-01-04\n\nclean\n' "$short" > "$repo/.review/verdict.md"
  ( cd "$repo" && git config core.hooksPath .githooks && git push -q "$remote" HEAD:refs/heads/change ) \
    > "$WORK/v4.push.log" 2>&1
  assert "v4: pushing archives the verdict" \
    sh -c 'test -f "$1"/code-2026-01-04-"$2"-*.md' _ "$(history_dir "$repo")" "$short"
}

# A hook that never runs looks exactly like one that ran and found the verdict
# current, so every review run says when this clone would not run it. A
# warning only: the run's exit code and `complete` must not move.
hook_repo() { # hook_repo <dir> <stubdir> — make_repo plus the kit hook and one change
  make_repo "$1"; mkdir -p "$2"
  printf '{"findings":[]}' > "$2/correctness.json"
  ( cd "$1" && mkdir -p .githooks && cp "$KIT/.githooks/pre-push" .githooks/ \
      && chmod +x .githooks/pre-push && printf 'change\n' >> src.txt \
      && git add -A && git commit -qm change )
}

assert_hook_quiet() { # assert_hook_quiet <id> <repo>
  assert     "$1: run completed" jq -e '.complete == true' "$2/.review/findings.json"
  assert_not "$1: no hook warning" grep -qF 'pre-push hook not wired' "$LOG"
  assert_not "$1: no hook line in findings.md" grep -qF 'Pre-push hook not wired' "$2/.review/findings.md"
}

test_review_warns_when_hook_unwired() {
  local repo="$WORK/h5" stub="$WORK/h5-stub" rc
  hook_repo "$repo" "$stub"

  run_review "$repo" "$stub" --lenses correctness; rc=$?
  assert "h5: unset hooksPath warns" grep -qF 'core.hooksPath is unset' "$LOG"
  assert "h5: … naming the fix" grep -qF 'fix: git config core.hooksPath .githooks' "$LOG"
  assert "h5: … and says so in findings.md" grep -qF 'Pre-push hook not wired' "$repo/.review/findings.md"
  assert "h5: exit code unchanged" test "$rc" -eq 0
  assert "h5: complete unchanged" jq -e '.complete == true' "$repo/.review/findings.json"

  ( cd "$repo" && git config core.hooksPath .githooks )
  run_review "$repo" "$stub" --lenses correctness
  assert_hook_quiet h5 "$repo"

  ( cd "$repo" && git config core.hooksPath "$repo/.githooks" )
  run_review "$repo" "$stub" --lenses correctness
  assert_hook_quiet "h5 (absolute path)" "$repo"

  ( cd "$repo" && chmod -x .githooks/pre-push )
  run_review "$repo" "$stub" --lenses correctness
  assert "h5: a non-executable hook warns" grep -qF 'chmod +x .githooks/pre-push' "$LOG"
}

test_review_warns_when_hooks_path_points_elsewhere() {
  local repo="$WORK/h6" stub="$WORK/h6-stub" rc
  hook_repo "$repo" "$stub"
  ( cd "$repo" && mkdir -p .husky && printf '#!/bin/sh\nnpm test\n' > .husky/pre-push \
      && chmod +x .husky/pre-push && git config core.hooksPath .husky )

  run_review "$repo" "$stub" --lenses correctness; rc=$?
  assert "h6: unchained foreign hooksPath warns" grep -qF "core.hooksPath is '.husky'" "$LOG"
  assert "h6: … naming the chain command" grep -qF '>> .husky/pre-push' "$LOG"
  assert "h6: exit code unchanged" test "$rc" -eq 0
  assert "h6: complete unchanged" jq -e '.complete == true' "$repo/.review/findings.json"

  # the fix the warning prints must be one the scanner accepts
  local fix
  fix="$(sed -n 's/.* — fix: //p' "$LOG" | head -n 1)"
  ( cd "$repo" && eval "$fix" )
  run_review "$repo" "$stub" --lenses correctness
  assert_hook_quiet "h6 (the printed fix)" "$repo"

  local form
  for form in '.githooks/pre-push' './.githooks/pre-push "$@"' 'bash .githooks/pre-push "$@"' \
      'sh ./.githooks/pre-push' 'exec .githooks/pre-push "$@"' \
      '"$(git rev-parse --show-toplevel)/.githooks/pre-push" "$@"'; do
    printf '#!/bin/sh\n%s\n' "$form" > "$repo/.husky/pre-push"
    run_review "$repo" "$stub" --lenses correctness
    assert_hook_quiet "h6 (chain form: $form)" "$repo"
  done

  for form in "echo '.githooks/pre-push'" 'MSG="run .githooks/pre-push first"' \
      '# .githooks/pre-push' 'true .githooks/pre-push'; do
    printf '#!/bin/sh\n%s\n' "$form" > "$repo/.husky/pre-push"
    run_review "$repo" "$stub" --lenses correctness
    assert "h6: not a chain: $form" grep -qF 'pre-push hook not wired' "$LOG"
  done

  ( cd "$repo" && printf '#!/bin/sh\nexec npm test\n.githooks/pre-push "$@" || exit $?\n' > .husky/pre-push )
  run_review "$repo" "$stub" --lenses correctness
  assert "h6: a chain after exec is not a chain" grep -qF 'above its first exec/exit' "$LOG"

  # any exec or exit before the chain, indented or not, means it may never run
  ( cd "$repo" && printf '#!/bin/sh\n  exit 0\n.githooks/pre-push "$@" || exit $?\n' > .husky/pre-push )
  run_review "$repo" "$stub" --lenses correctness
  assert "h6: a chain after an indented exit is not a chain" grep -qF 'can exec or exit before' "$LOG"

  ( cd "$repo" && printf '#!/bin/sh\nexec >/dev/null /bin/true\n.githooks/pre-push "$@" || exit $?\n' > .husky/pre-push )
  run_review "$repo" "$stub" --lenses correctness
  assert "h6: an exec that redirects and runs a command is not skipped" grep -qF 'can exec or exit before' "$LOG"

  # an exec that only redirects returns
  ( cd "$repo" && printf '#!/bin/sh\nexec 1>&2\nexec 2> /dev/null 3>&1\n.githooks/pre-push "$@" || exit $?\nif [ -n "$SKIP" ]; then\n  exit 0\nfi\n' > .husky/pre-push )
  run_review "$repo" "$stub" --lenses correctness
  assert_hook_quiet "h6 (chain after a redirect, before a guard)" "$repo"

  ( cd "$repo" && printf '#!/bin/sh\n.githooks/pre-push "$@" || exit $?\n' > .husky/pre-push && chmod 000 .husky/pre-push )
  run_review "$repo" "$stub" --lenses correctness
  chmod 755 "$repo/.husky/pre-push"
  if [ "$(id -u)" != 0 ]; then
    assert "h6: an unreadable hook says so" grep -qF 'cannot be read' "$LOG"
  else
    skip_test "h6: unreadable hook (running as root)"
  fi

  # past the pipe buffer, so an early-exiting match cannot SIGPIPE its writer
  ( cd "$repo" && { printf '#!/bin/sh\n.githooks/pre-push "$@" || exit $?\n'
      i=0; while [ $i -lt 10000 ]; do echo ": padding line $i"; i=$((i + 1)); done; } > .husky/pre-push )
  run_review "$repo" "$stub" --lenses correctness
  assert_hook_quiet "h6 (chained)" "$repo"


  # husky 9 points hooksPath at .husky/_, whose stubs run .husky/<hook>
  ( cd "$repo" && mkdir -p .husky/_ && : > .husky/_/h \
      && printf '#!/bin/sh\n. "$(dirname "$0")/h"\n' > .husky/_/pre-push \
      && chmod +x .husky/_/pre-push && git config core.hooksPath .husky/_ )
  run_review "$repo" "$stub" --lenses correctness
  assert_hook_quiet "h6 (husky 9, chained)" "$repo"
  ( cd "$repo" && git config core.hooksPath .husky/_/ )
  run_review "$repo" "$stub" --lenses correctness
  assert_hook_quiet "h6 (husky 9, trailing slash)" "$repo"
}

test_review_quiet_when_git_hooks_chain() {
  local repo="$WORK/h7" stub="$WORK/h7-stub" hooks
  hook_repo "$repo" "$stub"
  hooks="$(cd "$repo" && git rev-parse --git-path hooks)"
  printf '#!/bin/sh\n.githooks/pre-push "$@" || exit $?\n' > "$repo/$hooks/pre-push"
  chmod +x "$repo/$hooks/pre-push"
  run_review "$repo" "$stub" --lenses correctness
  assert_hook_quiet "h7 (chained from .git/hooks)" "$repo"
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

# A rebuild that fails on a missing input must not have already deleted the
# previous build: README.md and the marker would survive and pass for a plugin.
test_make_plugin_failed_rebuild_keeps_previous_build() {
  local hub="$WORK/m2-hub" dest="$WORK/m2-out/plugin" out="$WORK/m2.log" rc=0
  make_hub "$hub"
  mkdir -p "$WORK/m2-out"
  ( cd "$hub" && bash scripts/make-plugin.sh "$dest" ) > "$out" 2>&1
  rc=$?
  assert "m2: first build succeeds" test "$rc" -eq 0

  rm -rf "$hub/.claude/skills/pre-pr-review"
  ( cd "$hub" && bash scripts/make-plugin.sh "$dest" ) > "$out" 2>&1
  rc=$?
  assert "m2: rebuild with the skill missing fails" test "$rc" -ne 0
  assert "m2: failure names the missing skill" grep -qF 'kit skill missing' "$out"
  assert "m2: previous skill survives" test -f "$dest/skills/pre-pr-review/SKILL.md"
  assert "m2: previous runner survives" test -f "$dest/scripts/review.sh"
  assert "m2: previous review assets survive" test -f "$dest/review/schema.json"

  git -C "$hub" checkout -q -- .claude/skills
  rm "$hub/.review/adjudication.md"
  ( cd "$hub" && bash scripts/make-plugin.sh "$dest" ) > "$out" 2>&1
  rc=$?
  assert "m2: rebuild failing mid-copy fails" test "$rc" -ne 0
  assert "m2: mid-copy failure keeps the previous build" test -f "$dest/review/adjudication.md"
  assert "m2: failed builds leave no staging behind" \
    test "$(ls -A "$WORK/m2-out")" = plugin

  git -C "$hub" checkout -q -- .review
  printf 'v1\n' > "$dest/skills/pre-pr-review/old-only"
  mkdir -p "$WORK/m2-bin"
  printf '#!/bin/sh\ncase "$1" in */new/scripts) exit 1 ;; esac\nexec %s "$@"\n' \
    "$(command -v mv)" > "$WORK/m2-bin/mv"
  chmod +x "$WORK/m2-bin/mv"
  ( cd "$hub" && PATH="$WORK/m2-bin:$PATH" bash scripts/make-plugin.sh "$dest" ) > "$out" 2>&1
  rc=$?
  assert "m2: rebuild failing mid-swap fails" test "$rc" -ne 0
  assert "m2: mid-swap failure restores the previous skills" \
    test -f "$dest/skills/pre-pr-review/old-only"
  assert "m2: mid-swap failure restores the previous runner" test -f "$dest/scripts/review.sh"
  assert "m2: mid-swap failure restores README.md" test -f "$dest/README.md"
  assert "m2: rolled-back swap leaves no staging behind" \
    test "$(ls -A "$WORK/m2-out")" = plugin

  ( cd "$hub" && PATH="$WORK/m2-bin:$PATH" bash scripts/make-plugin.sh "$WORK/m2-out/fresh" ) > "$out" 2>&1
  rc=$?
  assert "m2: first build failing mid-swap fails" test "$rc" -ne 0
  assert "m2: first build cut short leaves no generated entries" \
    test "$(ls -A "$WORK/m2-out/fresh")" = .make-plugin-generated

  # A cross-filesystem mv that dies partway leaves a partial copy at the target.
  printf '#!/bin/sh\ncase "$1" in */plugin/skills) mkdir -p "$2/skills"; exit 1 ;; esac\nexec %s "$@"\n' \
    "$(command -v mv)" > "$WORK/m2-bin/mv"
  ( cd "$hub" && PATH="$WORK/m2-bin:$PATH" bash scripts/make-plugin.sh "$dest" ) > "$out" 2>&1
  rc=$?
  assert "m2: rebuild failing on a partial backup fails" test "$rc" -ne 0
  assert "m2: a partial backup never replaces the original" \
    test -f "$dest/skills/pre-pr-review/old-only"
  rm -rf "$WORK"/m2-out/.make-plugin-stage.*

  # Or the copy completes and only the delete of the source dies partway.
  printf '#!/bin/sh\ncase "$1" in */plugin/skills) cp -R "$1" "$2/" && rm -f "$1/pre-pr-review/old-only"; exit 1 ;; esac\nexec %s "$@"\n' \
    "$(command -v mv)" > "$WORK/m2-bin/mv"
  ( cd "$hub" && PATH="$WORK/m2-bin:$PATH" bash scripts/make-plugin.sh "$dest" ) > "$out" 2>&1
  rc=$?
  local kept
  kept=$(ls -d "$WORK"/m2-out/.make-plugin-stage.* 2>/dev/null)
  assert "m2: rebuild failing after a complete backup fails" test "$rc" -ne 0
  assert "m2: exactly one stage dir is kept" \
    sh -c '[ -n "$1" ] && [ "$(printf "%s\n" "$1" | wc -l)" -eq 1 ]' _ "$kept"
  assert "m2: the only complete backup is kept" \
    test -f "$kept/old/skills/pre-pr-review/old-only"
  assert "m2: the kept backup is named on stderr" \
    sh -c '[ -n "$1" ] && grep -qF "$1/old" "$2"' _ "$kept" "$out"
  assert "m2: other entries are still restored" test -f "$dest/README.md"
  rm -rf "$WORK"/m2-out/.make-plugin-stage.*
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
  test_missing_lens_prompt_is_failed \
  test_rubric_reaches_every_lens_prompt \
  test_unusual_filenames_reach_the_diff \
  test_deletions_are_not_unreadable \
  test_fail_on_gate_keeps_its_report \
  test_spec_selecting_nothing_fails \
  test_empty_base_ref_dies \
  test_spec_path_with_space \
  test_gitleaks_scans_branch_history \
  test_gitleaks_fatal_is_scan_failed \
  test_gitleaks_error_line_is_scan_failed \
  test_gitleaks_commit_count_checked \
  test_gitleaks_failed_line_count_is_scan_failed \
  test_gitleaks_leaks_reported \
  test_gitleaks_leak_on_a_nonempty_diff_is_critical \
  test_gitleaks_failure_on_a_nonempty_diff_is_incomplete \
  test_gitleaks_uncommitted_scans_diff_only \
  test_gitleaks_scans_history_of_an_empty_net_diff \
  test_gitleaks_failure_on_empty_net_diff_is_failed \
  test_gitleaks_missing_on_empty_net_diff_is_named \
  test_gitleaks_scans_merge_resolutions \
  test_zero_change_run_is_not_a_review \
  test_missing_gitleaks_and_semgrep_are_named \
  test_semgrep_gets_whole_paths \
  test_semgrep_failure_is_named \
  test_js_runner_follows_package_manager \
  test_js_unresolvable_tool_is_named \
  test_js_eslint_crash_is_failed \
  test_js_clean_run_and_tsc_build \
  test_js_eslint_warnings_keep_clean_line \
  test_js_tsc_findings_vs_failure \
  test_js_tsc_build_skipped_before_ts56 \
  test_js_without_package_json_is_named \
  test_update_reports_source_and_revision \
  test_update_marks_a_dirty_local_hub \
  test_update_marks_an_untracked_hub_file \
  test_update_leaves_a_clean_local_hub_unmarked \
  test_update_survives_replacing_itself \
  test_update_network_pins_to_latest_tag \
  test_update_network_honors_explicit_ref \
  test_update_network_refuses_a_branch_ref \
  test_update_network_honors_a_commit_sha \
  test_update_network_tells_unreachable_from_missing \
  test_update_network_refuses_without_pin \
  test_bootstrap_block_matches_in_both_docs \
  test_bootstrap_pins_and_refuses_a_branch \
  test_bootstrap_tells_unreachable_from_missing \
  test_update_warns_on_stale_local_clone \
  test_init_seeds_coderabbit_config \
  test_init_never_overwrites_existing_config \
  test_init_respects_other_config_spellings \
  test_install_check_reports_gate_state \
  test_install_check_fails_on_unwired_gate \
  test_install_check_foreign_hooks_path \
  test_install_keeps_live_git_hooks \
  test_prepush_judges_destination_ref \
  test_prepush_reads_the_verdict_header \
  test_prepush_rejects_a_spec_verdict \
  test_prepush_skips_a_sha256_deletion \
  test_review_archives_the_previous_verdicts \
  test_verdict_archive_is_shared_across_worktrees \
  test_verdict_archive_failure_warns_without_failing \
  test_prepush_archives_the_verdict \
  test_review_warns_when_hook_unwired \
  test_review_warns_when_hooks_path_points_elsewhere \
  test_review_quiet_when_git_hooks_chain \
  test_make_plugin_refuses_an_unlistable_destination \
  test_make_plugin_failed_rebuild_keeps_previous_build

echo
if [ "$FAILURES" -gt 0 ]; then
  printf '%d assertion(s) FAILED\n' "$FAILURES"; exit 1
fi
echo "all tests passed"
