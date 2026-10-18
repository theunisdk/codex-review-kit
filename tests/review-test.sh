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
# in $CODEX_STUB_DIR/<lens>.rc (default 0), and prints the token count in
# $CODEX_STUB_DIR/<lens>.tokens as codex does. `codex login status` succeeds.
# $CODEX_STUB_DIR/on-<lens>, when executable, runs first in the lens's directory.
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
[ ! -x "$CODEX_STUB_DIR/on-$lens" ] || "$CODEX_STUB_DIR/on-$lens"
[ -n "$out" ] && [ -f "$CODEX_STUB_DIR/$lens.json" ] && cp "$CODEX_STUB_DIR/$lens.json" "$out"
[ -f "$CODEX_STUB_DIR/$lens.tokens" ] && printf 'tokens used\n%s\n' "$(cat "$CODEX_STUB_DIR/$lens.tokens")"
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
    cp "$KIT/scripts/lib/common.sh" "$KIT/scripts/lib/analyzers.sh" "$KIT/scripts/lib/path-rules.sh" scripts/lib/
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

# Claude Code fills a command or skill body in before the model sees it: $<n>
# becomes argument n, counted from 0, and is left as written past the last one.
expand_positional() { # expand_positional [arg ...] — stdin, filled in as for `/<command> arg ...`
  awk -v args="$*" 'BEGIN { n = split(args, a, " ") }
    { s = $0; o = ""
      while (match(s, /\$[0-9]+/)) {
        i = substr(s, RSTART + 1, RLENGTH - 1) + 0
        o = o substr(s, 1, RSTART - 1) (i < n ? a[i + 1] : substr(s, RSTART, RLENGTH))
        s = substr(s, RSTART + RLENGTH)
      }
      print o s }'
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

# A house rule that lives only in the CodeRabbit config's path_instructions is
# graded by the gate; the lenses must see it for the files it covers. Every
# "nothing" (no config, no rules, no match) must read differently from every
# failure (unparseable, malformed, no parser, reader crash, unreadable file).
pr_status() { jq -r '.path_rules.status' "$1/.review/findings.json"; }
test_path_rules_reach_matching_lens_prompts() {
  local repo="$WORK/pr" stub="$WORK/pr-stub" prompt rc
  if ! have_yaml_parser; then
    if require_yaml_parser; then fail "pr: python3 yaml module required (REVIEW_TEST_REQUIRE_YAML=1) but missing"
    else skip_test "pr: python3 yaml module not installed"; fi
    return
  fi
  make_repo "$repo"; mkdir -p "$stub"
  printf '{"findings":[]}' > "$stub/correctness.json"
  printf '{"findings":[]}' > "$stub/security.json"
  prompt="$repo/.review/raw/prompt-correctness.md"
  (
    cd "$repo" || exit 1
    mkdir -p lib/store
    printf 'x\n' > lib/store/bucket.ts
    git add -A && git commit -qm 'source change'
  )
  cat > "$repo/.coderabbit.yaml" <<'EOF'
reviews:
  path_instructions:
    - path: "lib/**/*.ts"
      instructions: |
        PATHRULE-STORE-91c2: every bucket enables encryption at rest.
    - path: "docs/**"
      instructions: "PATHRULE-DOCS-4e7d: docs match the code."
EOF
  run_review "$repo" "$stub" --lenses correctness,security
  assert "pr: matching rule in correctness prompt" grep -qF 'PATHRULE-STORE-91c2' "$prompt"
  assert "pr: matching rule in security prompt" grep -qF 'PATHRULE-STORE-91c2' "$repo/.review/raw/prompt-security.md"
  assert "pr: prompt names the file the rule covers" grep -qF '`lib/store/bucket.ts`' "$prompt"
  assert_not "pr: non-matching rule kept out" grep -qF 'PATHRULE-DOCS-4e7d' "$prompt"
  assert "pr: status applied, 1 of 2" jq -e '.path_rules | .status == "applied" and .matched == 1 and .rules == 2 and .warning == null' "$repo/.review/findings.json"
  assert "pr: findings.md says the rule reached the lenses" grep -qF 'Path rules: 1 of the 2' "$repo/.review/findings.md"
  assert "pr: applied run is complete" jq -e '.complete == true' "$repo/.review/findings.json"
  assert_not "pr: no inheritance note without inheritance" grep -qF 'through `inheritance: true`' "$repo/.review/findings.md"

  # repo-local modules that shadow the reader's imports must never run
  local m
  for m in yaml json re; do
    printf 'open("%s/pr-shadow-%s", "w").write("ran")\n' "$WORK" "$m" > "$repo/$m.py"
  done
  printf 'inheritance: true\n' >> "$repo/.coderabbit.yaml"
  run_review "$repo" "$stub" --lenses correctness
  for m in yaml json re; do
    assert_not "pr: repo-local $m.py is not imported" test -e "$WORK/pr-shadow-$m"
    rm -f "$repo/$m.py"
  done
  assert "pr: rule still applied beside shadowing modules" test "$(pr_status "$repo")" = applied
  assert "pr: inherited rules are named as unread" grep -qF 'through `inheritance: true` are not read' "$repo/.review/findings.md"

  # an undotted name is not a documented gate config: named, not read, and it
  # never shadows the .ts config the gate does read
  mv "$repo/.coderabbit.yaml" "$repo/coderabbit.yml"
  run_review "$repo" "$stub" --lenses correctness
  assert "pr: undotted coderabbit.yml is not_inspected" test "$(pr_status "$repo")" = not_inspected
  assert "pr: undotted config named" jq -e '.path_rules.config == "coderabbit.yml"' "$repo/.review/findings.json"
  assert_not "pr: undotted config's rule kept out" grep -qF 'PATHRULE-STORE-91c2' "$prompt"
  printf 'export default {}\n' > "$repo/.coderabbit.config.ts"
  run_review "$repo" "$stub" --lenses correctness
  assert "pr: .ts config wins over an undotted one" jq -e '.path_rules.config == ".coderabbit.config.ts"' "$repo/.review/findings.json"
  rm "$repo/coderabbit.yml" "$repo/.coderabbit.config.ts"

  printf 'reviews:\n  path_instructions:\n    - path: "docs/**"\n      instructions: PATHRULE-DOCS-4e7d\n' > "$repo/.coderabbit.yaml"
  run_review "$repo" "$stub" --lenses correctness
  assert "pr: no glob matches is no_match" test "$(pr_status "$repo")" = no_match
  assert_not "pr: no_match puts no rule in the prompt" grep -qF 'PATHRULE-' "$prompt"
  assert_not "pr: no_match is not a warning" grep -qF 'Path rules NOT' "$repo/.review/findings.md"

  printf 'inheritance: true\nreviews:\n  profile: chill\n' > "$repo/.coderabbit.yaml"
  run_review "$repo" "$stub" --lenses correctness
  assert "pr: no path_instructions is no_rules" test "$(pr_status "$repo")" = no_rules
  assert "pr: no_rules is said in findings.md" grep -qF 'sets no path_instructions' "$repo/.review/findings.md"
  assert "pr: no_rules names unread inherited rules" grep -qF 'through `inheritance: true` are not read' "$repo/.review/findings.md"

  rm "$repo/.coderabbit.yaml"
  run_review "$repo" "$stub" --lenses correctness
  assert "pr: no config is no_config" test "$(pr_status "$repo")" = no_config
  assert "pr: no_config is said in findings.md" grep -qF 'Path rules: no CodeRabbit config.' "$repo/.review/findings.md"

  # each failure: a status that is none of the "nothing" ones, a warning in
  # findings.md and on stderr, and no rule section standing in for the real one
  pr_assert_warned() { # pr_assert_warned <label> <status>
    assert "pr: $1 is status $2" test "$(pr_status "$repo")" = "$2"
    assert "pr: $1 carries a warning" jq -e '.path_rules.warning | type == "string" and length > 0' "$repo/.review/findings.json"
    assert "pr: $1 warned in findings.md" grep -qF '> **Path rules NOT fully applied:**' "$repo/.review/findings.md"
    assert "pr: $1 warned on stderr" grep -qF 'warn: path rules:' "$LOG"
    assert_not "pr: $1 not reported as no rules" grep -qE 'Path rules: (no CodeRabbit config|.* sets no path_instructions|none of)' "$repo/.review/findings.md"
  }
  printf 'reviews:\n  path_instructions: [\n' > "$repo/.coderabbit.yaml"
  run_review "$repo" "$stub" --lenses correctness
  pr_assert_warned "unparseable yaml" unparseable
  assert "pr: unparseable yaml says CodeRabbit discards it" grep -qF 'CodeRabbit discards the whole file' "$repo/.review/findings.md"
  assert "pr: unparseable yaml leaves the lenses reviewed" jq -e '.complete == true' "$repo/.review/findings.json"

  printf 'reviews:\n  path_instructions: []\nreviews:\n  path_instructions:\n    - path: "lib/**"\n      instructions: PATHRULE-DUP\n' > "$repo/.coderabbit.yml"
  rm "$repo/.coderabbit.yaml"
  run_review "$repo" "$stub" --lenses correctness
  pr_assert_warned "duplicate key in .coderabbit.yml" unparseable

  rm "$repo/.coderabbit.yml"
  cat > "$repo/.coderabbit.yaml" <<'EOF'
reviews:
  path_instructions:
    - path: "lib/**"
      instructions: "PATHRULE-VALID-0b1f"
    - path: "lib/**"
    - instructions: "PATHRULE-NOPATH"
EOF
  run_review "$repo" "$stub" --lenses correctness
  pr_assert_warned "malformed entries" invalid
  assert "pr: malformed entries are named" grep -qF 'entries #2, #3' "$repo/.review/findings.md"
  assert "pr: the valid entry beside them still applies" grep -qF 'PATHRULE-VALID-0b1f' "$prompt"

  printf 'reviews:\n  path_instructions:\n    path: "lib/**"\n    instructions: x\n' > "$repo/.coderabbit.yaml"
  run_review "$repo" "$stub" --lenses correctness
  pr_assert_warned "path_instructions as a mapping" invalid

  printf 'reviews:\n  path_instructions:\n' > "$repo/.coderabbit.yaml"
  run_review "$repo" "$stub" --lenses correctness
  pr_assert_warned "an explicit null path_instructions" invalid

  printf 'inheritance: true\nreviews:\n' > "$repo/.coderabbit.yaml"
  run_review "$repo" "$stub" --lenses correctness
  pr_assert_warned "an explicit null reviews" invalid
  assert "pr: a warning still names unread inherited rules" grep -qF 'through `inheritance: true` are not read' "$repo/.review/findings.md"

  printf 'reviews:\n  path_instructions:\n    - path: "lib/**/@(store|cache)/*.ts"\n      instructions: PATHRULE-EXT\n' > "$repo/.coderabbit.yaml"
  run_review "$repo" "$stub" --lenses correctness
  pr_assert_warned "an extglob it cannot match" invalid

  # a yaml module that cannot be imported, shadowing the real one
  mkdir -p "$WORK/pr-noyaml"
  printf 'raise ImportError("stubbed out")\n' > "$WORK/pr-noyaml/yaml.py"
  printf 'reviews:\n  path_instructions:\n    - path: "lib/**"\n      instructions: PATHRULE-X\n' > "$repo/.coderabbit.yaml"
  ( export PYTHONPATH="$WORK/pr-noyaml"; run_review "$repo" "$stub" --lenses correctness ); LOG="$repo.log"
  pr_assert_warned "missing yaml module" no_parser

  mkdir -p "$WORK/pr-badpy"
  printf '#!/bin/sh\necho "python stub crashed" >&2\nexit 3\n' > "$WORK/pr-badpy/python3"
  chmod +x "$WORK/pr-badpy/python3"
  ( PATH="$WORK/pr-badpy:$PATH"; export PATH; run_review "$repo" "$stub" --lenses correctness ); LOG="$repo.log"
  pr_assert_warned "a crashing reader" failed
  assert "pr: the crash's stderr is quoted" grep -qF 'python stub crashed' "$repo/.review/findings.md"

  if [ "$(id -u)" != 0 ]; then
    chmod 000 "$repo/.coderabbit.yaml"
    run_review "$repo" "$stub" --lenses correctness
    chmod 644 "$repo/.coderabbit.yaml"
    pr_assert_warned "an unreadable config" failed
  fi

  rm "$repo/.coderabbit.yaml"
  printf 'export default {}\n' > "$repo/.coderabbit.config.ts"
  run_review "$repo" "$stub" --lenses correctness
  pr_assert_warned "a .ts config" not_inspected
  rm "$repo/.coderabbit.config.ts"

  # no python3 at all: only the tools collect_path_rules needs on PATH
  mkdir -p "$WORK/pr-nopy"
  ln -sf "$(command -v jq)" "$WORK/pr-nopy/jq"
  printf 'reviews: {}\n' > "$repo/.coderabbit.yaml"
  rc="$( cd "$repo" && . scripts/lib/path-rules.sh && PATH="$WORK/pr-nopy" && \
    collect_path_rules .review/raw/changed-files.txt "$WORK/pr-nopy.md" && printf '%s' "$PATH_RULES_STATUS|$PATH_RULES_WARNING" )"
  assert "pr: no python3 is no_parser" test "${rc%%|*}" = no_parser
  assert "pr: no python3 carries a warning" test -n "${rc#*|}"
  rm "$repo/.coderabbit.yaml"

  assert "pr: adjudication copies the warning into the verdict" \
    grep -qF '<path_rules.warning, when there is one>' "$KIT/.review/adjudication.md"
}

# The globs follow minimatch: `**` spans directories, `*` and `?` stay in one,
# braces expand, a slashless pattern is top-level only, a trailing slash means
# the whole directory, and dotfiles match.
# The installer's yaml probe and config check run from /, so a repo-local yaml.py
# neither runs nor stands in for PyYAML.
test_install_ignores_repo_local_yaml_module() {
  local spoke="$WORK/iy-spoke"
  if ! have_yaml_parser; then
    if require_yaml_parser; then fail "iy: python3 yaml module required (REVIEW_TEST_REQUIRE_YAML=1) but missing"
    else skip_test "iy: python3 yaml module not installed"; fi
    return
  fi
  make_installed_spoke "$spoke"
  printf 'open("%s/iy-shadow", "w").write("ran")\n' "$WORK" > "$spoke/yaml.py"
  run_install_check "$spoke"
  assert_not "iy: repo-local yaml.py is not imported" test -e "$WORK/iy-shadow"
  assert "iy: wired config still reported wired" grep -qF 'wires inheritance and both guideline mappings' "$LOG"
}

test_path_rule_globs() {
  local dir="$WORK/pg" out
  if ! have_yaml_parser; then
    if require_yaml_parser; then fail "pg: python3 yaml module required (REVIEW_TEST_REQUIRE_YAML=1) but missing"
    else skip_test "pg: python3 yaml module not installed"; fi
    return
  fi
  mkdir -p "$dir"
  cat > "$dir/.coderabbit.yaml" <<'EOF'
reviews:
  path_instructions:
    - { path: "src/**/*.ts", instructions: R-TS }
    - { path: "*.md", instructions: R-TOPMD }
    - { path: "**/*.{yml,yaml}", instructions: R-YAML }
    - { path: "infra/", instructions: R-INFRA }
    - { path: "./cfg/?.json", instructions: R-ONECHAR }
    - { path: "bin/[!x]*", instructions: R-CLASS }
    - { path: "nothing/**", instructions: R-NONE }
    - { path: "v{1..3}/**", instructions: R-RANGE }
    - { path: 'lit/\*.txt', instructions: R-ESCAPE }
    - { path: "rel/{01..03}/*", instructions: R-PAD }
    - { path: "odd/{1..5..2}/*", instructions: R-STEP }
    - { path: "big/{1..256}/*", instructions: R-BUDGET }
    - { path: "huge/{1..257}/*", instructions: R-OVER }
EOF
  printf '%s\n' src/a/b/c.ts src/top.ts README.md docs/guide.md .github/workflows/ci.yml \
    infra/net/main.tf cfg/a.json cfg/ab.json bin/run bin/xtool v2/x.go v4/x.go 'lit/*.txt' lit/a.txt \
    rel/02/f rel/2/f odd/3/f odd/4/f big/256/f huge/1/f > "$dir/changed.txt"
  out="$( cd "$dir" && . "$KIT/scripts/lib/path-rules.sh" && collect_path_rules changed.txt rules.md \
    && printf '%s' "$PATH_RULES_JSON" )"
  assert "pg: eleven of thirteen rules match, the oversized range is invalid" \
    jq -e '.status == "invalid" and .matched == 11 and .rules == 13 and (.warning | contains("#13 lacks"))' <<< "$out"
  assert "pg: numeric brace range expands" grep -qxF '### `v{1..3}/**` - applies to `v2/x.go`' "$dir/rules.md"
  assert "pg: zero-padded range keeps its padding" grep -qxF '### `rel/{01..03}/*` - applies to `rel/02/f`' "$dir/rules.md"
  assert "pg: stepped range steps" grep -qxF '### `odd/{1..5..2}/*` - applies to `odd/3/f`' "$dir/rules.md"
  assert "pg: a range at the budget expands" grep -qF 'R-BUDGET' "$dir/rules.md"
  assert "pg: an escaped star is literal" grep -qxF '### `lit/\*.txt` - applies to `lit/*.txt`' "$dir/rules.md"
  assert "pg: ** spans nested and zero directories" grep -qF '`src/a/b/c.ts`, `src/top.ts`' "$dir/rules.md"
  assert "pg: slashless pattern is top-level only" grep -qxF '### `*.md` - applies to `README.md`' "$dir/rules.md"
  assert "pg: braces expand and dotfiles match" grep -qF '`.github/workflows/ci.yml`' "$dir/rules.md"
  assert "pg: trailing slash is the whole directory" grep -qF '`infra/net/main.tf`' "$dir/rules.md"
  assert "pg: ? is one character" grep -qxF '### `./cfg/?.json` - applies to `cfg/a.json`' "$dir/rules.md"
  assert "pg: negated class excludes" grep -qxF '### `bin/[!x]*` - applies to `bin/run`' "$dir/rules.md"
  assert_not "pg: unmatched rule left out" grep -qF 'R-NONE' "$dir/rules.md"

  cat > "$dir/.coderabbit.yaml" <<'EOF'
reviews:
  path_instructions:
    - { path: "src/**/!(*.test).ts", instructions: R-EXT }
    - { path: "src/[[:alpha:]]*.ts", instructions: R-POSIX }
    - { path: "!src/**", instructions: R-NEG }
    - { path: "src/**", instructions: R-OK }
EOF
  out="$( cd "$dir" && . "$KIT/scripts/lib/path-rules.sh" && collect_path_rules changed.txt rules.md \
    && printf '%s' "$PATH_RULES_JSON" )"
  assert "pg: unsupported syntax is invalid, not no_match" jq -e '.status == "invalid" and .matched == 1' <<< "$out"
  assert "pg: each unsupported entry is named" jq -e '.warning | contains("#1, #2, #3")' <<< "$out"

  # a deep near-miss against many globstars must not backtrack for minutes
  local deep="" i start
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do deep="$deep**/b/"; done
  printf 'reviews:\n  path_instructions:\n    - { path: "a/%sc", instructions: R-DEEP }\n' "$deep" > "$dir/.coderabbit.yaml"
  printf 'a/%sx\n' "$(printf 'b/%.0s' $(seq 1 40))" > "$dir/changed.txt"
  start="$(date +%s)"
  out="$( cd "$dir" && . "$KIT/scripts/lib/path-rules.sh" && collect_path_rules changed.txt rules.md \
    && printf '%s' "$PATH_RULES_JSON" )"
  assert "pg: deep globstar near-miss is no_match" jq -e '.status == "no_match"' <<< "$out"
  assert "pg: deep globstar near-miss is fast" test "$(( $(date +%s) - start ))" -lt 5
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
  assert "uncommitted: findings.json names the mode and the commit the changes sit on" \
    jq -e --arg h "$(git -C "$repo" rev-parse --short HEAD)" '.mode == "uncommitted" and .head == $h' "$repo/.review/findings.json"

  ( cd "$repo" && git add -A && git commit -qm 'odd names' )
  run_review "$repo" "$stub" --lenses correctness; rc=$?
  assert "branch: run exits 0" test "$rc" -eq 0
  assert "branch: é.txt listed unquoted" grep -qxF 'é.txt' "$repo/.review/raw/changed-files.txt"
  assert "branch: back\\slash.txt listed unquoted" grep -qxF 'back\slash.txt' "$repo/.review/raw/changed-files.txt"
  assert "branch: complete" jq -e '.complete == true' "$repo/.review/findings.json"
  assert "branch: findings.json names the mode" jq -e '.mode == "branch"' "$repo/.review/findings.json"

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
    assert "g12: … and findings.md names it" grep -qF 'gitleaks found a secret' "$AREPO/.review/findings.md"
  fi
  chmod 644 "$AREPO/.review/rubric.md"

  analyzer_repo g12b
  ( cd "$AREPO" && printf 'change\n' >> src.txt )
  printf '1:00PM FTL unable to load gitleaks config\n' > "$ASTUB/gitleaks-pipe.out"
  printf '1\n' > "$ASTUB/gitleaks-pipe.rc"
  run_review_analyzers "$AREPO" "$ASTUB" --uncommitted
  assert "g12: a failed net-diff scan is complete:false too" jq -e '.complete == false' "$AREPO/.review/findings.json"

  rm -f "$ASTUB/correctness.json"
  run_review_analyzers "$AREPO" "$ASTUB" --uncommitted
  assert "g12: with every lens failed, the failed scan is still named" \
    sh -c 'jq -e ".secrets_scan == \"failed\" and .complete == false" "$1" && grep -qF "secret scan FAILED" "$2"' \
    _ "$AREPO/.review/findings.json" "$AREPO/.review/findings.md"
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

  # --remerge-diff skips octopus merges, so a range holding one uses -m.
  analyzer_repo g13c
  (
    cd "$AREPO" || exit 1
    printf 'x\n' > b.txt && git add b.txt && git commit -qm 'branch change'
    git checkout -qb t1 main && printf '1\n' > one.txt && git add one.txt && git commit -qm one
    git checkout -qb t2 main && printf '2\n' > two.txt && git add two.txt && git commit -qm two
    git checkout -q change && git merge -q --no-commit t1 t2 >/dev/null
    printf 'api_key = "%s"\n' "not-a-real-key-0123456789" > creds.txt
    git add creds.txt && git commit -qm octopus && git rm -q creds.txt && git commit -qm 'drop creds'
  )
  printf 'not-a-real-key\n' > "$ASTUB/gitleaks-history.git"
  run_review_analyzers "$AREPO" "$ASTUB" main
  assert "g13: an octopus merge in the range uses -m" grep -qF -- '--log-opts=-m ' "$ASTUB/gitleaks.calls"
  assert "g13: … and the secret it carried is found" jq -e '.secrets_scan == "leaks"' "$AREPO/.review/findings.json"

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
       "$KIT"/scripts/review-update.sh "$KIT"/scripts/review-sync.sh \
       "$KIT"/scripts/make-plugin.sh scripts/
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

run_update_local() { # run_update_local <spoke> [VAR=val ...] — --local run, output in $LOG
  local dir="$1"; shift
  LOG="$dir.log"
  mkdir -p "$WORK/nohome"
  ( cd "$dir" && env -i HOME="$WORK/nohome" PATH="$PATH" "$@" \
      bash "$KIT/scripts/review-update.sh" --local ) > "$LOG" 2>&1
}

run_update_init() { # run_update_init <spoke> [VAR=val ...] — --init --local run, output in $LOG
  local dir="$1"; shift
  LOG="$dir.log"
  mkdir -p "$WORK/nohome"
  ( cd "$dir" && env -i HOME="$WORK/nohome" PATH="$PATH" "$@" \
      bash "$KIT/scripts/review-update.sh" --init --local ) > "$LOG" 2>&1
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
  run_update_local "$spoke" REVIEW_KIT_DIR="$KIT"; local rc=$?

  assert "u1: run exits 0" test "$rc" -eq 0
  assert "u1: resolved source printed" grep -F "installing from $KIT" "$LOG"
  assert "u1: files synced" test -x "$spoke/scripts/review.sh"
  assert "u1: kit-version records a ref" grep -q '^ref: ..*' "$spoke/.review/kit-version"
  assert "u1: kit-version records the source" grep -qF "source: $KIT" "$spoke/.review/kit-version"
  assert "u1: kit-version marks a --local sync unreleased" \
    grep -qx 'release: unreleased' "$spoke/.review/kit-version"
}

# --local installs the hub's WORKING TREE, so uncommitted edits there are
# real content in the spoke — and a bare HEAD in kit-version would name a commit
# that cannot reproduce what was installed.
test_update_marks_a_dirty_local_hub() {
  local hub="$WORK/u9-hub" spoke="$WORK/u9-spoke"
  make_hub "$hub"; make_spoke "$spoke"
  printf '\n# uncommitted hub edit\n' >> "$hub/scripts/review.sh"
  run_update_local "$spoke" REVIEW_KIT_DIR="$hub"; local rc=$?

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
  run_update_local "$spoke" REVIEW_KIT_DIR="$hub"; local rc=$?

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
  run_update_local "$spoke" REVIEW_KIT_DIR="$hub"; local rc=$?

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
      bash scripts/review-update.sh --local ) > "$LOG" 2>&1; local rc=$?

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
  assert     "u2: kit-version records the release" grep -qx 'release: v0.10.0' "$spoke/.review/kit-version"
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
  assert     "u14: a SHA a release tag points at records that release" \
    grep -qx 'release: v0.9.0' "$spoke/.review/kit-version"

  local tip; tip="$(git -C "$hub" rev-parse HEAD)"
  rm -rf "$spoke"; make_spoke "$spoke"
  run_update "$spoke" REVIEW_KIT_URL="file://$hub" REVIEW_KIT_REF="$tip"; rc=$?
  assert     "u14: an untagged SHA exits 0" test "$rc" -eq 0
  assert     "u14: an untagged SHA is recorded unreleased" \
    grep -qx 'release: unreleased' "$spoke/.review/kit-version"

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

# The header's "synced (overwritten)" list is what a spoke maintainer reads to
# learn which files a sync clobbers; it must name everything the cp block copies,
# and nothing it does not. Regression for OPERATING.md missing from the list.
test_update_header_lists_what_it_copies() {
  local f="$KIT/scripts/review-update.sh" names paths n p hit missing="" extra=""
  names="$(awk '/^#   synced \(overwritten\):/ {on=1; sub(/^#   synced \(overwritten\):/, "")}
                on && /^#   [a-z-]+ \(/ && !/synced/ {exit}
                on {sub(/^#/, ""); print}' "$f" | tr ',' '\n' | tr -d ' ' | grep .)"
  paths="$(sed -n '/^# --- sync the shared half/,/^chmod/p' "$f" \
    | grep -o '"\$KIT"/[^ ]*' | sed 's|"\$KIT"/||')"
  set -f   # the lists hold globs; match them, never expand them
  for p in $paths; do
    hit=0
    for n in $names; do
      case "$p" in $n|"${n%/}"/*|*/"$n") hit=1 ;; esac
      case "$p/" in "$n") hit=1 ;; esac
    done
    [ "$hit" = 1 ] || missing="$missing $p"
  done
  for n in $names; do
    hit=0
    for p in $paths; do
      case "$p" in $n|"${n%/}"/*|*/"$n") hit=1 ;; esac
      case "$p/" in "$n") hit=1 ;; esac
    done
    [ "$hit" = 1 ] || extra="$extra $n"
  done
  set +f
  assert "u20: header list parsed" test -n "$names"
  assert "u20: cp block parsed" test -n "$paths"
  assert "u20: header names every copied path (missing:${missing:- none})" test -z "$missing"
  assert "u20: header names nothing uncopied (extra:${extra:- none})" test -z "$extra"
  assert "u20: header calls kit-version generated" \
    grep -q '^#   generated (rewritten): \.review/kit-version' "$f"
}

# --- no-clone bootstrap ----------------------------------------------------
bootstrap_block() { # bootstrap_block <md file> — the fenced block that runs ls-remote
  awk '/^```bash$/ {inb=1; b=""; next}
       /^```$/ && inb {inb=0; if (b ~ /ls-remote/) printf "%s", b; next}
       inb {b = b $0 "\n"}' "$1"
}

# Runs the onboard bootstrap against a local hub: curl is stubbed to read the
# hub at the commit in the URL, and less is a no-op.
run_bootstrap() { # run_bootstrap <spoke> <hub> [VAR=val ...] — output in $LOG; BOOT_ARGS: /review-onboard's arguments
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
  bootstrap_block "$KIT/.claude/commands/review-onboard.md" | expand_positional ${BOOT_ARGS:-} \
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
  BOOT_ARGS="notes about the repo" run_bootstrap "$spoke" "$hub"; rc=$?
  assert     "b2: … and the same when /review-onboard is given arguments" \
    sh -c '[ "$1" -eq 0 ] && grep -q "^ref: $2\$" "$3"' _ "$rc" "$sha" "$spoke/.review/kit-version"

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

# A tag lookup that fails is not a missing tag: an awk that exits non-zero
# leaves SHA empty, the same as a tag that does not exist.
test_bootstrap_tells_failed_lookup_from_missing() {
  local hub="$WORK/b4-hub" spoke="$WORK/b4-spoke" bin="$WORK/b4-bin"
  make_boot_hub "$hub"; make_spoke "$spoke"
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 2\n' > "$bin/awk"; chmod +x "$bin/awk"

  run_bootstrap "$spoke" "$hub" PATH="$bin:$WORK/bootbin:$PATH"; local rc=$?
  assert     "b4: failed lookup stops" test "$rc" -ne 0
  assert     "b4: failed lookup says so" grep -q 'cannot read the tag listing' "$LOG"
  assert_not "b4: failed lookup is not called a missing tag" grep -q 'neither a tag' "$LOG"
  assert_not "b4: nothing synced" test -f "$spoke/.review/kit-version"
}

# --local is the opt-in that installs a clone's working tree as-is, so a clone
# behind its origin still installs — with a warning, and recorded unreleased.
test_update_warns_on_stale_local_clone() {
  local origin="$WORK/u5-origin" clone="$WORK/u5-clone" spoke="$WORK/u5-spoke"
  make_hub "$origin"
  git clone -q "$origin" "$clone"
  make_spoke "$spoke"

  run_update_local "$spoke" REVIEW_KIT_DIR="$clone"; local rc=$?
  assert     "u5: fresh clone exits 0" test "$rc" -eq 0
  assert_not "u5: fresh clone does not warn" grep -q 'behind' "$LOG"

  ( cd "$origin" && printf 'MARKER: ahead\n' >> REVIEW.md && git commit -aqm ahead )
  run_update_local "$spoke" REVIEW_KIT_DIR="$clone"; rc=$?
  assert     "u5: stale clone installs under --local" test "$rc" -eq 0
  assert     "u5: stale clone warns it is behind" grep -q 'behind' "$LOG"
  assert_not "u5: the clone's tree, not origin's, was installed" grep -q 'MARKER: ahead' "$spoke/REVIEW.md"
  assert     "u5: recorded unreleased" grep -qx 'release: unreleased' "$spoke/.review/kit-version"
}

make_home_clone() { # make_home_clone <home> <hub> — a hub clone where the updater used to look for one
  mkdir -p "$1/dev/private"
  git clone -q "$2" "$1/dev/private/codex-review-kit"
  git -C "$1/dev/private/codex-review-kit" config user.email review-test@example.invalid
  git -C "$1/dev/private/codex-review-kit" config user.name review-test
}

# Without --local, a local hub clone never decides what installs: one AHEAD of
# the latest release (unreleased commits, uncommitted edits) and one BEHIND it
# both install the release tag. Regression for the clone that shipped as-is.
test_update_installs_the_release_over_a_local_clone() {
  local hub="$WORK/u16-hub" home="$WORK/u16-home" spoke="$WORK/u16-spoke" lc
  make_tagged_hub "$hub"; make_spoke "$spoke"
  make_home_clone "$home" "$hub"; lc="$home/dev/private/codex-review-kit"
  ( cd "$lc" && printf 'MARKER: clone-ahead\n' >> REVIEW.md && git commit -aqm ahead \
      && printf 'MARKER: clone-dirty\n' >> OPERATING.md )

  run_update "$spoke" REVIEW_KIT_URL="file://$hub" HOME="$home"; local rc=$?
  assert     "u16: ahead clone: exits 0" test "$rc" -eq 0
  assert     "u16: ahead clone: the release installed" grep -q 'MARKER: nine' "$spoke/REVIEW.md"
  assert_not "u16: ahead clone: its commits NOT installed" grep -q 'MARKER: clone-ahead' "$spoke/REVIEW.md"
  assert_not "u16: ahead clone: its edits NOT installed" grep -q 'MARKER: clone-dirty' "$spoke/OPERATING.md"
  assert_not "u16: ahead clone: hub tip NOT installed" grep -q 'MARKER: tip' "$spoke/REVIEW.md"
  assert     "u16: ahead clone: kit-version records the release" \
    grep -qx 'release: v0.9.0' "$spoke/.review/kit-version"
  assert     "u16: the unused clone is named" grep -qF "not using the hub clone at $lc" "$LOG"

  ( cd "$hub" && git -c tag.gpgSign=false tag -a -m ten v0.10.0 )
  git -C "$lc" checkout -q -- OPERATING.md && git -C "$lc" reset -q --hard v0.9.0
  run_update "$spoke" REVIEW_KIT_URL="file://$hub" HOME="$home"; rc=$?
  assert     "u16: behind clone: exits 0" test "$rc" -eq 0
  assert     "u16: behind clone: the newer release installed" grep -q 'MARKER: tip' "$spoke/REVIEW.md"
  assert     "u16: behind clone: kit-version records it" \
    grep -qx 'release: v0.10.0' "$spoke/.review/kit-version"
}

# A hub that cannot be listed fails the sync even when a local clone could have
# stood in — the clone's state is unverified, so installing it would be the
# stale-kit-under-a-success-message failure.
test_update_unreachable_hub_fails_despite_a_clone() {
  local hub="$WORK/u17-hub" home="$WORK/u17-home" spoke="$WORK/u17-spoke"
  make_tagged_hub "$hub"; make_spoke "$spoke"; make_home_clone "$home" "$hub"

  run_update "$spoke" REVIEW_KIT_URL="file://$WORK/u17-nowhere" HOME="$home"; local rc=$?
  assert     "u17: unreachable hub fails" test "$rc" -ne 0
  assert     "u17: says it cannot reach the hub" grep -q 'cannot reach' "$LOG"
  assert_not "u17: no success line" grep -q '^synced from' "$LOG"
  assert_not "u17: nothing synced" test -e "$spoke/REVIEW.md"
  assert_not "u17: no kit-version" test -e "$spoke/.review/kit-version"
}

# REVIEW_KIT_DIR used to mean "install this tree". Without --local it is refused
# rather than silently ignored or silently honoured; with REVIEW_KIT_REF it conflicts.
test_update_local_needs_the_flag() {
  local hub="$WORK/u18-hub" spoke="$WORK/u18-spoke"
  make_tagged_hub "$hub"; make_spoke "$spoke"

  run_update "$spoke" REVIEW_KIT_URL="file://$hub" REVIEW_KIT_DIR="$hub"; local rc=$?
  assert     "u18: REVIEW_KIT_DIR without --local refuses" test "$rc" -ne 0
  assert     "u18: refusal names --local" grep -q -- '--local' "$LOG"
  assert_not "u18: nothing synced" test -e "$spoke/.review/kit-version"

  run_update_local "$spoke" REVIEW_KIT_DIR="$hub" REVIEW_KIT_REF=v0.9.0; rc=$?
  assert     "u18: --local with REVIEW_KIT_REF refuses" test "$rc" -ne 0
  assert_not "u18: still nothing synced" test -e "$spoke/.review/kit-version"

  run_update_local "$spoke" REVIEW_KIT_DIR="$WORK/u18-nowhere"; rc=$?
  assert     "u18: --local with a missing dir refuses" test "$rc" -ne 0
  assert_not "u18: still nothing synced" test -e "$spoke/.review/kit-version"
}

# --latest-release is the lookup other tooling reuses: the tag on stdout, and an
# exit code that tells "unreachable" (1) from "reachable, no release" (2).
test_update_latest_release_lookup() {
  local hub="$WORK/u19-hub" bare="$WORK/u19-bare" out="$WORK/u19.out" rc
  make_hub "$hub"; make_hub "$bare"
  (
    cd "$hub" || exit 1
    git -c tag.gpgSign=false tag -a -m nine v0.9.0
    git tag v0.10.0 && git tag v0.11 && git tag v1.0.0-rc1 && git tag v2
  )
  ( cd "$WORK" && env -i HOME="$WORK/nohome" PATH="$PATH" REVIEW_KIT_URL="file://$hub" \
      bash "$KIT/scripts/review-update.sh" --latest-release ) > "$out" 2>"$out.err"; rc=$?
  assert "u19: lookup exits 0" test "$rc" -eq 0
  assert "u19: prints the highest strict vN.N.N" test "$(cat "$out")" = v0.10.0

  ( cd "$WORK" && env -i HOME="$WORK/nohome" PATH="$PATH" REVIEW_KIT_URL="file://$bare" \
      bash "$KIT/scripts/review-update.sh" --latest-release ) > "$out" 2>"$out.err"; rc=$?
  assert "u19: no release tag exits 2" test "$rc" -eq 2
  assert "u19: no release tag prints nothing" test ! -s "$out"
  assert "u19: no release tag says so" grep -q 'no release tag' "$out.err"

  ( cd "$WORK" && env -i HOME="$WORK/nohome" PATH="$PATH" REVIEW_KIT_URL="file://$WORK/u19-nowhere" \
      bash "$KIT/scripts/review-update.sh" --latest-release ) > "$out" 2>"$out.err"; rc=$?
  assert "u19: unreachable exits 1" test "$rc" -eq 1
  assert "u19: unreachable prints nothing" test ! -s "$out"
  assert "u19: unreachable says so" grep -q 'cannot reach' "$out.err"

  ( cd "$WORK" && env -i HOME="$WORK/nohome" PATH="$PATH" REVIEW_KIT_URL="file://$hub" \
      bash "$KIT/scripts/review-update.sh" --latest-release --init ) > "$out" 2>"$out.err"; rc=$?
  assert "u19: extra arguments are a usage error (64), not unreachable" test "$rc" -eq 64
  ( cd "$WORK" && env -i HOME="$WORK/nohome" PATH="$PATH" \
      bash "$KIT/scripts/review-update.sh" --bogus ) > "$out" 2>"$out.err"; rc=$?
  assert "u19: an unknown argument is a usage error (64)" test "$rc" -eq 64
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

  run_update_local "$spoke" REVIEW_KIT_DIR="$KIT"; local rc=$?
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

# --- kit-sync workflow seeding -----------------------------------------------
WF=.github/workflows/review-kit-sync.yml

# The cron --init must write for a repo slug: minute, hour and weekday from its cksum.
expected_cron() {
  local n; n="$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
  echo "$((n % 60)) $((n / 60 % 24)) * * $((n / 1440 % 7))"
}
wf_cron() { python3 -c 'import sys,yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get("on", d.get(True))
print(on["schedule"][0]["cron"])' "$1"; }

# --init seeds the workflow with a schedule spread by repo name, and it parses
# as the workflow it claims to be: weekly + manual, least privilege, never a merge.
test_init_seeds_the_sync_workflow() {
  local a="$WORK/w1-a" b="$WORK/w1-b" c="$WORK/w1-c" rc
  make_spoke "$a"; git -C "$a" remote add origin git@github.com:acme/widgets.git
  make_spoke "$b"; git -C "$b" remote add origin https://github.com/acme/widgets/
  make_spoke "$c"; git -C "$c" remote add origin https://github.com/acme/gadgets.git
  run_update_init "$a" REVIEW_KIT_DIR="$KIT"; rc=$?
  assert "w1: --init exits 0" test "$rc" -eq 0
  assert "w1: --init seeds the workflow" test -f "$a/$WF"
  assert "w1: the seed is announced with its opt-out" grep -q "seeded $WF.*KIT_SYNC_ACTION=0" "$LOG"
  assert_not "w1: no placeholder left" grep -q '@CRON@' "$a/$WF"
  run_update_init "$b" REVIEW_KIT_DIR="$KIT"
  run_update_init "$c" REVIEW_KIT_DIR="$KIT"
  make_spoke "$WORK/w1-plain"; run_update_local "$WORK/w1-plain" REVIEW_KIT_DIR="$KIT"
  assert_not "w1: a plain sync seeds no workflow" test -e "$WORK/w1-plain/$WF"
  assert "w1: the sync script is synced" test -x "$WORK/w1-plain/scripts/review-sync.sh"
  assert_not "w1: the sync script never merges, approves or auto-merges" \
    grep -Eq 'gh pr merge|gh pr review|--auto( |$)|--approve' "$KIT/scripts/review-sync.sh"

  if ! have_yaml_parser; then
    if require_yaml_parser; then fail "w1: python3 yaml module required (REVIEW_TEST_REQUIRE_YAML=1) but missing"
    else skip_test "w1: workflow YAML assertions (no python3 yaml module)"; fi
    return
  fi
  assert "w1: the template parses" yaml_parses "$KIT/templates/review-kit-sync.yml"
  assert "w1: the seeded workflow parses" yaml_parses "$a/$WF"
  local on='d.get("on", d.get(True))'
  assert "w1: triggers are schedule and workflow_dispatch only" \
    cfg_holds "$a/$WF" "sorted($on.keys()) == ['schedule', 'workflow_dispatch']"
  assert "w1: permissions are contents and pull-requests write, nothing else" \
    cfg_holds "$a/$WF" 'd["permissions"] == {"contents": "write", "pull-requests": "write"}'
  assert "w1: the job runs review-sync.sh" \
    cfg_holds "$a/$WF" 'any("scripts/review-sync.sh" in s.get("run", "") for s in d["jobs"]["sync"]["steps"])'
  assert "w1: cron derives from owner/repo" test "$(wf_cron "$a/$WF")" = "$(expected_cron acme/widgets)"
  assert "w1: ssh and https remotes give the same schedule" test "$(wf_cron "$b/$WF")" = "$(wf_cron "$a/$WF")"
  assert "w1: another repo gets another schedule" test "$(wf_cron "$c/$WF")" != "$(wf_cron "$a/$WF")"
  assert "w1: the schedule is weekly (one weekday, fixed minute and hour)" \
    sh -c 'printf "%s\n" "$1" | grep -Eqx "[0-9]+ [0-9]+ \* \* [0-6]"' _ "$(wf_cron "$a/$WF")"
}

# Re-seeding is idempotent, an edited copy is kept and named, a plain sync never
# touches it, and KIT_SYNC_ACTION=0 opts out.
test_init_reseeding_the_sync_workflow() {
  local s="$WORK/w2" o="$WORK/w2-optout" rc
  make_spoke "$s"
  run_update_init "$s" REVIEW_KIT_DIR="$KIT"
  cp "$s/$WF" "$WORK/w2.orig"
  run_update_init "$s" REVIEW_KIT_DIR="$KIT"; rc=$?
  assert "w2: re-running --init exits 0" test "$rc" -eq 0
  assert "w2: re-running --init leaves the workflow byte-identical" cmp -s "$s/$WF" "$WORK/w2.orig"
  assert_not "w2: an unchanged workflow is not re-announced" grep -q "$WF" "$LOG"

  printf '# local tweak\n' >> "$s/$WF"; cp "$s/$WF" "$WORK/w2.edited"
  run_update_init "$s" REVIEW_KIT_DIR="$KIT"; rc=$?
  assert "w2: --init over an edited copy exits 0" test "$rc" -eq 0
  assert "w2: the edited copy is kept" cmp -s "$s/$WF" "$WORK/w2.edited"
  assert "w2: keeping it is said out loud" grep -q "kept $WF" "$LOG"
  run_update_local "$s" REVIEW_KIT_DIR="$KIT"
  assert "w2: a plain sync leaves the workflow alone" cmp -s "$s/$WF" "$WORK/w2.edited"

  make_spoke "$o"; mkdir -p "$o/.review"; printf 'KIT_SYNC_ACTION=0\n' > "$o/.review/config.sh"
  run_update_init "$o" REVIEW_KIT_DIR="$KIT"; rc=$?
  assert "w2: an opted-out --init exits 0" test "$rc" -eq 0
  assert_not "w2: KIT_SYNC_ACTION=0 seeds no workflow" test -e "$o/$WF"
  assert "w2: the opt-out is named" grep -q 'KIT_SYNC_ACTION=0' "$LOG"

  local b="$WORK/w2-broken"
  make_spoke "$b"; mkdir -p "$b/.review"; printf 'if then\nKIT_SYNC_ACTION=0\n' > "$b/.review/config.sh"
  run_update_init "$b" REVIEW_KIT_DIR="$KIT"
  assert_not "w2: an unreadable config seeds no workflow" test -e "$b/$WF"
  assert "w2: and says it could not read the opt-out" grep -q 'could not be read to check KIT_SYNC_ACTION' "$LOG"

  local f="$WORK/w2-false"
  make_spoke "$f"; mkdir -p "$f/.review"; printf 'BASE=main\ncommand -v no-such-tool >/dev/null && SED=x\n' > "$f/.review/config.sh"
  run_update_init "$f" REVIEW_KIT_DIR="$KIT"
  assert "w2: a valid config ending in a false test still seeds" test -e "$f/$WF"
}

# review-install.sh reports whether new releases arrive on their own.
test_install_reports_the_sync_workflow() {
  local s="$WORK/w3" p="$WORK/w3-plain"
  make_installed_spoke "$s"; run_install_check "$s"
  assert "w3: install reports the seeded workflow" grep -q 'review-kit-sync workflow present' "$LOG"
  make_synced_spoke "$p"; run_install_check "$p"
  assert "w3: install says how to seed a missing workflow" grep -q 'no .github/workflows/review-kit-sync.yml' "$LOG"
  run_install_full "$s"; run_install_check "$s"; local rc=$?
  assert "w3: a fully installed spoke passes --check" test "$rc" -eq 0
  rm "$s/scripts/review-sync.sh"; run_install_check "$s"; rc=$?
  assert "w3: a workflow without its script fails --check" test "$rc" -ne 0
  assert "w3: and says every run fails" grep -q 'scripts/review-sync.sh is missing' "$LOG"
}

# --- review-sync.sh ------------------------------------------------------------
# gh stub: answers from $GH_STUB — open.json / closed.json for `pr list --state`,
# commits.json for `pr view`, notes/<tag>.md for `release view` (else
# release.err, else "release not found"), list.err / create.err / edit.err to
# fail `pr list` / `pr create` / `pr edit` with that text. --jq is applied
# with jq -r, as gh does. Every call is logged to calls; a body file is kept
# as body.md.
mkdir -p "$WORK/gh-bin"
cat > "$WORK/gh-bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB/calls"
jqx=""; body=""; state=""; prev=""
for a in "$@"; do
  case "$prev" in --jq) jqx="$a" ;; --body-file) body="$a" ;; --state) state="$a" ;; esac
  prev="$a"
done
[ -z "$body" ] || cp "$body" "$GH_STUB/body.md"
emit() { if [ -n "$jqx" ]; then jq -r "$jqx" "$1"; else cat "$1"; fi; }
case "$1 $2" in
  "pr list")
    [ ! -f "$GH_STUB/list.err" ] || { cat "$GH_STUB/list.err" >&2; exit 1; }
    f="$GH_STUB/$state.json"; [ -f "$f" ] || f="$GH_STUB/empty.json"
    emit "$f" ;;
  "pr view")
    [ ! -f "$GH_STUB/view.err" ] || { cat "$GH_STUB/view.err" >&2; exit 1; }
    emit "$GH_STUB/commits.json" ;;
  "repo view") echo '{"defaultBranchRef":{"name":"main"}}' > "$GH_STUB/repo.json"; emit "$GH_STUB/repo.json" ;;
  "pr edit") [ ! -f "$GH_STUB/edit.err" ] || { cat "$GH_STUB/edit.err" >&2; exit 1; } ;;
  "pr create")
    [ ! -f "$GH_STUB/create.err" ] || { cat "$GH_STUB/create.err" >&2; exit 1; }
    echo "https://github.com/acme/spoke/pull/12" ;;
  "release view")
    [ ! -f "$GH_STUB/release.err" ] || { cat "$GH_STUB/release.err" >&2; exit 1; }
    [ -f "$GH_STUB/notes/$3.md" ] || { echo "release not found" >&2; exit 1; }
    jq -n --rawfile b "$GH_STUB/notes/$3.md" '{body: $b}' > "$GH_STUB/release.json"
    emit "$GH_STUB/release.json" ;;
esac
exit 0
EOF
chmod +x "$WORK/gh-bin/gh"

hub_release() { # hub_release <hub> <tag> — a commit marking the tag, then the tag (annotated)
  ( cd "$1" && printf 'MARKER: %s\n' "$2" >> REVIEW.md && git commit -aqm "$2" \
      && git -c tag.gpgSign=false tag -a -m "$2" "$2" )
}

# sync_world <id> <installed tag> — $SHUB released v0.9.0..v0.11.0; $SPOKE on
# <installed>, pushed to the bare $SORIGIN, no git identity of its own; $GH_STUB.
sync_world() {
  SHUB="$WORK/$1-hub"; SORIGIN="$WORK/$1-origin.git"; SPOKE="$WORK/$1-spoke"; GH_STUB="$WORK/$1-gh"
  make_hub "$SHUB"
  hub_release "$SHUB" v0.9.0; hub_release "$SHUB" v0.10.0; hub_release "$SHUB" v0.11.0
  git init -q --bare "$SORIGIN"
  make_spoke "$SPOKE"
  run_update "$SPOKE" REVIEW_KIT_URL="file://$SHUB" REVIEW_KIT_REF="$2"
  (
    cd "$SPOKE" || exit 1
    git config user.email review-test@example.invalid; git config user.name review-test
    printf 'app\n' > app.txt
    git add -A && git commit -qm "kit $2" && git remote add origin "$SORIGIN" && git push -q origin main
    git config --unset user.email; git config --unset user.name
  )
  mkdir -p "$GH_STUB/notes"; echo '[]' > "$GH_STUB/empty.json"
  printf '## What changed\n\nten things\n\n## Upgrading\n\nNew `ten_key` in findings.json.\n\n## Still open\n\n#1\n' \
    > "$GH_STUB/notes/v0.10.0.md"
  printf '## What changed\n\neleven things\n' > "$GH_STUB/notes/v0.11.0.md"
}

run_sync() { # run_sync [VAR=val ...] — scripts/review-sync.sh in $SPOKE; output in $LOG
  LOG="$SPOKE.sync.log"
  mkdir -p "$WORK/nohome"
  ( cd "$SPOKE" && env -i HOME="$WORK/nohome" PATH="$WORK/gh-bin:$PATH" GH_STUB="$GH_STUB" GIT_CONFIG_NOSYSTEM=1 \
      REVIEW_KIT_REPO=theunisdk/codex-review-kit "$@" bash scripts/review-sync.sh ) > "$LOG" 2>&1
}
origin_has_branch() { git --git-dir="$SORIGIN" rev-parse -q --verify refs/heads/review-kit-sync >/dev/null; }
origin_release() { git --git-dir="$SORIGIN" show "$1:.review/kit-version" | sed -n 's/^release: //p'; }
gh_calls() { grep -c -- "$1" "$GH_STUB/calls" 2>/dev/null; }

# Already on the latest release: success naming it, and nothing opened or pushed.
test_sync_current_succeeds_quietly() {
  sync_world s1 v0.11.0
  local sum="$WORK/s1-summary"
  run_sync GITHUB_STEP_SUMMARY="$sum"; local rc=$?
  assert     "s1: current exits 0" test "$rc" -eq 0
  assert     "s1: one line names the version" grep -q 'review kit current: v0.11.0 is the latest release' "$LOG"
  assert     "s1: the job summary says so too" grep -q 'current: v0.11.0' "$sum"
  assert_not "s1: no gh call at all" test -s "$GH_STUB/calls"
  assert_not "s1: nothing pushed" origin_has_branch

  ( cd "$SPOKE" && sed 's/^release: .*/release: v0.99.0/' .review/kit-version > kv && mv kv .review/kit-version \
      && git -c user.email=t@example.invalid -c user.name=t commit -qam ahead )
  run_sync; rc=$?
  assert     "s1: a kit ahead of the hub exits 0" test "$rc" -eq 0
  assert     "s1: and says it is ahead" grep -q 'review kit ahead: v0.99.0 is newer' "$LOG"
  assert_not "s1: ahead pushes nothing" origin_has_branch
}

# Behind: exactly one PR, from a pushed branch, carrying the skipped releases'
# notes, their Upgrading sections, and the local edits the sync overwrote.
test_sync_behind_opens_one_pr() {
  sync_world s2 v0.9.0
  ( cd "$SPOKE" && printf 'LOCAL EDIT\n' >> REVIEW.md && git rm -q OPERATING.md \
      && git -c user.email=t@example.invalid -c user.name=t commit -qam 'local edit' && git push -q origin main )
  local main_before; main_before="$(git --git-dir="$SORIGIN" rev-parse main)"
  run_sync; local rc=$?
  local body="$GH_STUB/body.md"
  assert     "s2: behind exits 0" test "$rc" -eq 0
  assert     "s2: says it opened the PR" grep -q 'v0.9.0 is behind v0.11.0: opened sync PR https://github.com/acme/spoke/pull/12' "$LOG"
  assert     "s2: exactly one pr create" test "$(gh_calls 'pr create')" = 1
  assert     "s2: titled for the latest release" grep -q -- '--title sync review kit to v0.11.0' "$GH_STUB/calls"
  assert     "s2: from the sync branch onto main" grep -q -- '--base main --head review-kit-sync' "$GH_STUB/calls"
  assert_not "s2: never merged, approved or auto-merged" grep -Eq 'pr merge|pr review|--auto|--approve' "$GH_STUB/calls"
  assert     "s2: the branch is pushed" origin_has_branch
  assert     "s2: the branch carries the latest release" test "$(origin_release review-kit-sync)" = v0.11.0
  assert     "s2: main is untouched" test "$(git --git-dir="$SORIGIN" rev-parse main)" = "$main_before"
  assert     "s2: the commit carries the trailer" \
    sh -c 'git --git-dir="$1" log -1 --format=%B review-kit-sync | grep -qx "Review-Kit-Sync: v0.11.0"' _ "$SORIGIN"
  assert     "s2: committed as the Actions bot when git has no identity" \
    sh -c 'git --git-dir="$1" log -1 --format=%an review-kit-sync | grep -qx "github-actions\[bot\]"' _ "$SORIGIN"
  assert     "s2: the spoke is back on main" test "$(git -C "$SPOKE" symbolic-ref --short HEAD)" = main
  assert     "s2: body names the overwritten local edit" grep -qF '`REVIEW.md` — edited here since v0.9.0' "$body"
  assert     "s2: body names a deleted synced file the sync restores" \
    grep -qF '`OPERATING.md` — deleted here since v0.9.0; the sync restores it' "$body"
  assert_not "s2: an unchanged updater raises no callout" grep -q 'changes `scripts/review-update.sh`' "$body"
  assert_not "s2: body does not flag unedited synced files" grep -qF '`scripts/review.sh`' "$body"
  assert     "s2: body lifts v0.10.0's Upgrading section" grep -qF 'New `ten_key` in findings.json.' "$body"
  assert_not "s2: the lifted section stops at the next heading" \
    sh -c 'sed -n "/^## Release notes/q;p" "$1" | grep -q "^#1$"' _ "$body"
  assert     "s2: body flags v0.11.0's missing Upgrading section" grep -qF "v0.11.0's notes have no \`## Upgrading\` section" "$body"
  assert     "s2: body carries both skipped releases' notes" \
    sh -c 'grep -q "ten things" "$1" && grep -q "eleven things" "$1"' _ "$body"
  assert_not "s2: the installed release's notes are not asked for" grep -q 'release view v0.9.0' "$GH_STUB/calls"
  assert     "s2: body carries the review-update.sh output" grep -q 'synced from kit @ v0.11.0' "$body"
  assert     "s2: body says it never merges" grep -q 'It never merges' "$body"
}

# A sync PR already open: the same release leaves it alone; a newer release
# updates it in place; commits the sync did not make stop the update.
test_sync_updates_the_open_pr() {
  sync_world s3 v0.9.0
  run_sync
  local oid; oid="$(git --git-dir="$SORIGIN" rev-parse review-kit-sync)"
  printf '[{"number":12,"title":"sync review kit to v0.11.0","url":"https://github.com/acme/spoke/pull/12","isCrossRepository":false}]\n' > "$GH_STUB/open.json"
  run_sync; local rc=$?
  assert "s3: an open PR for the latest exits 0" test "$rc" -eq 0
  assert "s3: says the release is waiting in it" grep -q 'v0.11.0 is waiting in sync PR #12' "$LOG"
  assert "s3: no second PR" test "$(gh_calls 'pr create')" = 1
  assert "s3: the branch is not re-pushed" test "$(git --git-dir="$SORIGIN" rev-parse review-kit-sync)" = "$oid"

  hub_release "$SHUB" v0.12.0
  printf '{"headRefOid":"%s","commits":[{"oid":"%s","messageBody":"Review-Kit-Sync: v0.11.0"}]}\n' "$oid" "$oid" > "$GH_STUB/commits.json"
  run_sync; rc=$?
  assert "s3: a newer release exits 0" test "$rc" -eq 0
  assert "s3: the open PR is edited, base included" grep -q -- 'pr edit 12 --base main --title sync review kit to v0.12.0' "$GH_STUB/calls"
  assert "s3: still one PR" test "$(gh_calls 'pr create')" = 1
  assert "s3: says it updated the PR" grep -q 'updated sync PR #12' "$LOG"
  assert "s3: the branch now carries v0.12.0" test "$(origin_release review-kit-sync)" = v0.12.0
  assert "s3: the new body still counts from the installed release" grep -q 'ten things' "$GH_STUB/body.md"
  assert "s3: a tag with no GitHub release says so in the body" \
    grep -q 'v0.12.0 is a tag with no GitHub release' "$GH_STUB/body.md"

  hub_release "$SHUB" v0.13.0
  oid="$(git --git-dir="$SORIGIN" rev-parse review-kit-sync)"
  printf '[{"number":12,"title":"sync review kit to v0.12.0","url":"u","isCrossRepository":false}]\n' > "$GH_STUB/open.json"
  printf '{"headRefOid":"%s","commits":[{"oid":"a","messageBody":"Review-Kit-Sync: v0.12.0"},{"oid":"b","messageBody":""}]}\n' "$oid" > "$GH_STUB/commits.json"
  run_sync; rc=$?
  assert "s3: a human commit on the PR fails the run" test "$rc" -ne 0
  assert "s3: and says why" grep -q 'sync PR #12 carries 1 commit(s) this sync did not make' "$LOG"
  assert "s3: the human commit is not force-pushed away" test "$(git --git-dir="$SORIGIN" rev-parse review-kit-sync)" = "$oid"

  # gh vouched for an older head than origin now has: the lease refuses the push.
  local raced; raced="$(git --git-dir="$SORIGIN" rev-parse review-kit-sync)"
  ( cd "$SPOKE" && git fetch -q origin review-kit-sync && git checkout -q -b race FETCH_HEAD \
      && printf 'human\n' > human.txt && git add human.txt \
      && git -c user.email=t@example.invalid -c user.name=t commit -qm human \
      && git push -q origin HEAD:refs/heads/review-kit-sync && git checkout -q main && git branch -qD race )
  oid="$(git --git-dir="$SORIGIN" rev-parse review-kit-sync)"
  printf '{"headRefOid":"%s","commits":[{"oid":"a","messageBody":"Review-Kit-Sync: v0.12.0"}]}\n' "$raced" > "$GH_STUB/commits.json"
  run_sync; rc=$?
  assert "s3: a push racing the check fails the run" test "$rc" -ne 0
  assert "s3: and quotes the rejection, not the remote's URL" grep -qF '[rejected]' "$LOG"
  assert "s3: the racing commit survives" test "$(git --git-dir="$SORIGIN" rev-parse review-kit-sync)" = "$oid"

  git -C "$SPOKE" checkout -q -f main
  printf 'HTTP 422: Validation Failed\n' > "$GH_STUB/edit.err"
  printf '{"headRefOid":"%s","commits":[{"oid":"a","messageBody":"Review-Kit-Sync: v0.12.0"}]}\n' "$oid" > "$GH_STUB/commits.json"
  run_sync; rc=$?
  assert "s3: a failed PR edit fails the run" test "$rc" -ne 0
  assert "s3: and names the PR" grep -q 'cannot update sync PR #12: HTTP 422' "$LOG"
  assert_not "s3: no success line after a failed edit" grep -q 'updated sync PR' "$LOG"
}

# A sync PR closed unmerged for the latest release is a decision, not a gap.
test_sync_respects_a_declined_pr() {
  sync_world s4 v0.9.0
  printf '[{"number":10,"title":"sync review kit to v0.11.0","mergedAt":"2026-10-01T00:00:00Z"},{"number":9,"title":"sync review kit to v0.11.0","mergedAt":null},{"number":8,"title":"sync review kit to v0.10.0","mergedAt":null}]\n' \
    > "$GH_STUB/closed.json"
  run_sync; local rc=$?
  assert     "s4: declined exits 0" test "$rc" -eq 0
  assert     "s4: names the closed PR" grep -q 'sync PR #9 was closed unmerged' "$LOG"
  assert     "s4: opens nothing" test "$(gh_calls 'pr create')" = 0
  assert_not "s4: pushes nothing" origin_has_branch
}

# Every way the sync can fail must fail the job, and say which way.
test_sync_failures_fail_visibly() {
  local rc sum
  sync_world s5 v0.9.0

  run_sync REVIEW_KIT_URL="file://$WORK/s5-nowhere"; rc=$?
  assert "s5: hub unreachable fails" test "$rc" -ne 0
  assert "s5: unreachable is named" grep -q 'is unreachable' "$LOG"
  assert_not "s5: unreachable opens nothing" test -s "$GH_STUB/calls"

  make_hub "$WORK/s5-bare"
  run_sync REVIEW_KIT_URL="file://$WORK/s5-bare"; rc=$?
  assert "s5: no release tag fails" test "$rc" -ne 0
  assert "s5: no release is named" grep -q 'lists no vN.N.N release tag' "$LOG"

  printf 'HTTP 401: Bad credentials\n' > "$GH_STUB/list.err"
  run_sync; rc=$?
  assert "s5: a gh failure listing PRs fails" test "$rc" -ne 0
  assert "s5: an empty listing is not assumed" grep -q 'cannot list pull requests (gh pr list): HTTP 401' "$LOG"
  assert_not "s5: nothing pushed after a gh failure" origin_has_branch
  rm -f "$GH_STUB/list.err"

  printf 'pull request create failed: GraphQL: GitHub Actions is not permitted to create or approve pull requests (createPullRequest)\n' \
    > "$GH_STUB/create.err"
  sum="$WORK/s5-summary"
  run_sync GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$sum"; rc=$?
  assert "s5: forbidden PR creation fails" test "$rc" -ne 0
  assert "s5: names the exact setting" grep -q "Allow GitHub Actions to create and approve pull requests" "$LOG"
  assert "s5: annotates the run" grep -q '^::error title=review kit sync failed::GitHub Actions may not create pull requests' "$LOG"
  assert "s5: the job summary says it failed" grep -q 'failed' "$sum"

  printf 'pull request create failed: GraphQL: Resource not accessible by integration (createPullRequest)\n' \
    > "$GH_STUB/create.err"
  run_sync; rc=$?
  assert "s5: a token without pull-requests write fails" test "$rc" -ne 0
  assert "s5: names the permission" grep -q "the job needs 'permissions: pull-requests: write'" "$LOG"
  rm -f "$GH_STUB/create.err"

  git -C "$SPOKE" remote set-url origin "file://$WORK/s5-gone.git"
  run_sync; rc=$?
  assert "s5: an unreadable origin fails" test "$rc" -ne 0
  assert "s5: names the branch it could not read" grep -q 'cannot read branch review-kit-sync on origin' "$LOG"
  git -C "$SPOKE" remote set-url origin "$SORIGIN"

  git --git-dir="$SORIGIN" update-ref -d refs/heads/review-kit-sync
  printf '#!/bin/sh\necho "Permission to acme/spoke.git denied to github-actions[bot]." >&2\nexit 1\n' \
    > "$SORIGIN/hooks/pre-receive"
  chmod +x "$SORIGIN/hooks/pre-receive"
  git -C "$SPOKE" checkout -q -f main
  run_sync; rc=$?
  assert "s5: a refused push fails" test "$rc" -ne 0
  assert "s5: names the permission it needs" grep -q "push to review-kit-sync refused — the job needs 'permissions: contents: write'" "$LOG"
  assert "s5: no PR without a branch" test "$(gh_calls 'pr create')" = 2

  printf '#!/bin/sh\necho "refusing to allow a GitHub App to create or update workflow \\`.github/workflows/ci.yml\\` without \\`workflows\\` permission" >&2\nexit 1\n' \
    > "$SORIGIN/hooks/pre-receive"
  git -C "$SPOKE" checkout -q -f main
  run_sync; rc=$?
  assert "s5: a push refused for a workflow change fails" test "$rc" -ne 0
  assert "s5: names the workflows permission" grep -q 'give REVIEW_KIT_SYNC_TOKEN Workflows write' "$LOG"
}

# A sync that fails, or exits 0 without installing the release, fails the job.
test_sync_failed_or_empty_update_fails() {
  local rc
  sync_world s6 v0.9.0
  (
    cd "$SPOKE" || exit 1
    mv scripts/review-update.sh scripts/real-update.sh
    printf '#!/usr/bin/env bash\n[ "${1:-}" = --latest-release ] && exec bash scripts/real-update.sh "$@"\necho "stub sync"\nexit "${STUB_RC:-0}"\n' \
      > scripts/review-update.sh
    git add -A && git -c user.email=t@example.invalid -c user.name=t commit -qm 'stub updater'
  )
  run_sync; rc=$?
  assert "s6: a sync that installs nothing fails" test "$rc" -ne 0
  assert "s6: says kit-version is not at the release" grep -q "records release 'v0.9.0', not v0.11.0" "$LOG"
  assert_not "s6: nothing pushed" origin_has_branch
  git -C "$SPOKE" checkout -q -f main
  run_sync STUB_RC=3; rc=$?
  assert "s6: a failing sync fails" test "$rc" -ne 0
  assert "s6: names the exit" grep -q 'review-update.sh failed (exit 3)' "$LOG"
  assert "s6: shows its output" grep -q 'stub sync' "$LOG"

  git -C "$SPOKE" checkout -q -f main
  git -C "$SPOKE" rm -q .review/kit-version
  git -C "$SPOKE" -c user.email=t@example.invalid -c user.name=t commit -qm 'no kit-version'
  run_sync; rc=$?
  assert "s6: a missing kit-version fails" test "$rc" -ne 0
  assert "s6: says it was never synced" grep -q '^error: .review/kit-version is missing — this repo was never synced' "$LOG"
}

# The sync overwrites review-sync.sh while it runs. A release whose copy differs
# must not run a byte of it before the PR is reviewed.
test_sync_never_runs_the_incoming_script() {
  sync_world s7 v0.11.0
  (
    cd "$SHUB" || exit 1
    { echo '#!/usr/bin/env bash'
      i=0; while [ $i -lt 400 ]; do echo "touch '$WORK/s7-pwned'; exit 0 # padding padding"; i=$((i + 1)); done
    } > scripts/review-sync.sh
    echo "touch '$WORK/s7-pwned'" >> scripts/review-update.sh
    git commit -aqm payload && git -c tag.gpgSign=false tag -a -m v0.12.0 v0.12.0
  )
  run_sync; local rc=$?
  assert     "s7: the sync completes" test "$rc" -eq 0
  assert     "s7: and opens the PR" grep -q 'opened sync PR' "$LOG"
  assert_not "s7: the incoming script never ran" test -e "$WORK/s7-pwned"
  assert     "s7: the PR carries the incoming script for review" \
    sh -c 'git --git-dir="$1" show review-kit-sync:scripts/review-sync.sh | grep -q s7-pwned' _ "$SORIGIN"
  assert     "s7: the PR says the release changes the updater" \
    grep -qF '**v0.12.0 changes `scripts/review-update.sh`.**' "$GH_STUB/body.md"
}

# Only this repo's own review-kit-sync branch is the sync PR; a fork's is not.
test_sync_ignores_fork_prs() {
  sync_world s8 v0.9.0
  printf '[{"number":5,"title":"sync review kit to v0.11.0","url":"u","isCrossRepository":true}]\n' > "$GH_STUB/open.json"
  printf '[{"number":4,"title":"sync review kit to v0.11.0","mergedAt":null,"isCrossRepository":true}]\n' > "$GH_STUB/closed.json"
  run_sync; local rc=$?
  assert     "s8: a fork's same-named PR exits 0" test "$rc" -eq 0
  assert     "s8: opens the real sync PR" test "$(gh_calls 'pr create')" = 1
  assert_not "s8: never edits the fork's PR" grep -q 'pr edit 5' "$GH_STUB/calls"
  assert_not "s8: never reads the fork's PR" grep -q 'pr view 5' "$GH_STUB/calls"
}

# Lookups whose failure would leave a PR broken for good fail the run before
# anything is pushed; so does a run from the wrong branch or over a foreign branch.
test_sync_refuses_before_pushing() {
  local rc
  sync_world s9 v0.9.0
  printf 'x\n' > "$SPOKE/dirty.txt"
  run_sync; rc=$?
  assert     "s9: a dirty tree is refused" test "$rc" -ne 0
  assert     "s9: and says why" grep -q 'the working tree has changes' "$LOG"
  assert_not "s9: the dirty file is not committed anywhere" origin_has_branch
  rm -f "$SPOKE/dirty.txt"

  printf 'HTTP 403: API rate limit exceeded\n' > "$GH_STUB/release.err"
  run_sync; rc=$?
  assert     "s9: a failed release-notes lookup fails" test "$rc" -ne 0
  assert     "s9: names the release" grep -q 'cannot read the release notes for v0.11.0' "$LOG"
  assert_not "s9: nothing pushed" origin_has_branch
  rm -f "$GH_STUB/release.err"; git -C "$SPOKE" checkout -q -f main

  git -C "$SPOKE" checkout -q -b feature
  run_sync; rc=$?
  assert     "s9: a feature branch is refused" test "$rc" -ne 0
  assert     "s9: names the default branch" grep -q 'run from the default branch main, not feature' "$LOG"
  git -C "$SPOKE" checkout -q main

  ( cd "$SPOKE" && git checkout -q -b mine && printf 'x\n' > mine.txt && git add mine.txt \
      && git -c user.email=t@example.invalid -c user.name=t commit -qm mine \
      && git push -q origin HEAD:refs/heads/review-kit-sync && git checkout -q main )
  local oid; oid="$(git --git-dir="$SORIGIN" rev-parse review-kit-sync)"
  run_sync; rc=$?
  assert     "s9: a foreign branch of that name fails" test "$rc" -ne 0
  assert     "s9: says its tip is not a sync commit" grep -q 'its tip is not a sync commit' "$LOG"
  assert     "s9: the foreign branch is untouched" test "$(git --git-dir="$SORIGIN" rev-parse review-kit-sync)" = "$oid"

  git -C "$SPOKE" checkout -q -f main
  printf '[{"number":7,"title":"sync review kit to v0.10.0","url":"u","isCrossRepository":false}]\n' > "$GH_STUB/open.json"
  printf 'HTTP 502: Bad Gateway\n' > "$GH_STUB/view.err"
  run_sync; rc=$?
  assert     "s9: a failed read of the open PR fails" test "$rc" -ne 0
  assert     "s9: and is not taken as zero foreign commits" grep -q 'cannot read the commits of sync PR #7: HTTP 502' "$LOG"
  assert     "s9: the branch is untouched" test "$(git --git-dir="$SORIGIN" rev-parse review-kit-sync)" = "$oid"
}

# A pin to a release from before review-sync.sh existed still installs.
test_update_pins_a_release_without_the_sync_script() {
  local hub="$WORK/u21-hub" spoke="$WORK/u21-spoke"
  make_hub "$hub"
  ( cd "$hub" && git rm -q scripts/review-sync.sh && git commit -qm old && git tag v0.9.0 )
  make_spoke "$spoke"
  run_update "$spoke" REVIEW_KIT_URL="file://$hub" REVIEW_KIT_REF=v0.9.0; local rc=$?
  assert     "u21: the pin installs" test "$rc" -eq 0
  assert     "u21: kit-version records it" grep -qx 'release: v0.9.0' "$spoke/.review/kit-version"
  assert_not "u21: no sync script appears" test -e "$spoke/scripts/review-sync.sh"

  local old="$WORK/u21-old" ispoke="$WORK/u21-init"
  make_hub "$old"
  ( cd "$old" && cp -R "$KIT"/templates . && rm templates/review-kit-sync.yml && git rm -q scripts/review-sync.sh \
      && git add -A && git commit -qm old )
  make_spoke "$ispoke"
  run_update_init "$ispoke" REVIEW_KIT_DIR="$old"; rc=$?
  assert     "u21: --init from a kit without the template installs" test "$rc" -eq 0
  assert     "u21: and records the kit" test -f "$ispoke/.review/kit-version"
  assert_not "u21: no empty workflow is left behind" test -e "$ispoke/.github/workflows/review-kit-sync.yml"
  assert     "u21: and says why it seeded none" grep -q 'has no templates/review-kit-sync.yml' "$LOG"
}

# --- installer fixtures ----------------------------------------------------
make_installed_spoke() { # <dir> — a spoke with the kit synced and seeded
  local dir="$1"
  make_spoke "$dir"
  ( cd "$dir" && env -i HOME="$WORK/nohome" PATH="$PATH" REVIEW_KIT_DIR="$KIT" \
      bash "$KIT/scripts/review-update.sh" --init --local ) >/dev/null 2>&1
}

make_synced_spoke() { # <dir> — synced but NOT seeded, for bring-your-own configs
  local dir="$1"
  make_spoke "$dir"
  ( cd "$dir" && env -i HOME="$WORK/nohome" PATH="$PATH" REVIEW_KIT_DIR="$KIT" \
      bash "$KIT/scripts/review-update.sh" --local ) >/dev/null 2>&1
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

# An --uncommitted verdict is stamped with HEAD but reviewed only the working tree
# on top of it, so its header read as a review of HEAD and cleared the push (#53).
test_prepush_rejects_an_uncommitted_verdict() {
  local repo="$WORK/um1" stub="$WORK/um1-stub" remote="$WORK/um1-remote.git" out="$WORK/um1.push.log" rc short
  hook_repo "$repo" "$stub"
  git init -q --bare "$remote"
  git -C "$repo" config core.hooksPath .githooks
  short=$(git -C "$repo" rev-parse --short HEAD)

  printf '# Review verdict — change — %s+uncommitted — 2026-01-01\n\nclean\n' "$short" > "$repo/.review/verdict.md"
  ( cd "$repo" && REVIEW_STRICT=1 git push "$remote" 'HEAD:refs/heads/change' ) > "$out" 2>&1
  rc=$?
  assert "um1: an uncommitted verdict naming HEAD does not clear the gate" test "$rc" -ne 0
  assert "um1: … and the hook says why" \
    grep -qF "change — verdict reviewed uncommitted changes on $short, not a commit — commit them and run /review" "$out"
  ( cd "$repo" && git push "$remote" 'HEAD:refs/heads/change2' ) > "$out" 2>&1
  rc=$?
  assert "um1: without REVIEW_STRICT it warns and pushes" \
    sh -c '[ "$1" -eq 0 ] && grep -qF "change2 — verdict reviewed uncommitted changes" "$2"' _ "$rc" "$out"
  printf '# Review verdict — change — %s — 2026-01-01\n\nclean\n' "$short" > "$repo/.review/verdict.md"
  ( cd "$repo" && REVIEW_STRICT=1 git push "$remote" 'HEAD:refs/heads/change3' ) > "$out" 2>&1
  rc=$?
  assert "um1: the same header without the marker still clears it" test "$rc" -eq 0
}

# Adjudication reads the mode to mark the verdict, and may still write one from an
# incomplete run, so every findings.json writer carries it. HEAD is the one the
# change set was built on, not wherever HEAD is when the lenses finish.
test_findings_name_mode_and_head_on_every_path() {
  local repo="$WORK/um5" stub="$WORK/um5-stub" short
  make_repo "$repo"; mkdir -p "$stub"
  short=$(git -C "$repo" rev-parse --short HEAD)
  printf 'new\n' > "$repo/new.txt"
  printf '42\n' > "$stub/correctness.rc"
  run_review "$repo" "$stub" --uncommitted --lenses correctness
  assert "um5: every lens failed" grep -qF 'every lens failed' "$LOG"
  assert "um5: … and findings.json still names the mode and HEAD" \
    jq -e --arg h "$short" '.complete == false and .mode == "uncommitted" and .head == $h' "$repo/.review/findings.json"

  rm "$repo/new.txt"
  run_review "$repo" "$stub" --uncommitted --lenses correctness
  assert "um5: a zero-change run names them too" \
    sh -c 'grep -qF "no changes to review" "$1" && jq -e --arg h "$3" ".mode == \"uncommitted\" and .head == \$h" "$2"' \
    _ "$LOG" "$repo/.review/findings.json" "$short"

  ( cd "$repo" && PATH="$WORK/bin:$PATH" CODEX_STUB_DIR="$stub" REVIEW_SKIP_AUTH_CHECK=1 \
      bash scripts/review.sh --no-analyzers --lenses correctness no-such-ref ) > "$WORK/um5.log" 2>&1
  assert "um5: so does a run that dies before its report" \
    sh -c 'grep -qF "base ref not found" "$1" && jq -e --arg h "$3" ".complete == false and .mode == \"branch\" and .head == \$h" "$2"' \
    _ "$WORK/um5.log" "$repo/.review/findings.json" "$short"

  mkdir -p "$WORK/um5-bin"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = exec ] && git -C "%s" commit -q --allow-empty -m moved\nexec "%s" "$@"\n' \
    "$repo" "$WORK/bin/codex" > "$WORK/um5-bin/codex"
  chmod +x "$WORK/um5-bin/codex"
  rm "$stub/correctness.rc"; printf '{"findings":[]}' > "$stub/correctness.json"
  printf 'new\n' > "$repo/new.txt"
  ( cd "$repo" && PATH="$WORK/um5-bin:$WORK/bin:$PATH" CODEX_STUB_DIR="$stub" REVIEW_SKIP_AUTH_CHECK=1 \
      bash scripts/review.sh --no-analyzers --uncommitted --lenses correctness ) > "$WORK/um5.log" 2>&1
  assert "um5: HEAD moved during the run" test "$(git -C "$repo" rev-parse --short HEAD)" != "$short"
  assert "um5: … and head is still the commit the change set was built on" \
    jq -e --arg h "$short" '.complete == true and .head == $h' "$repo/.review/findings.json"
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

# A marked header failed the archive's SHA match and was filed as code-unparsed (#53).
test_verdict_archive_keys_an_uncommitted_verdict() {
  local repo="$WORK/um2" stub="$WORK/um2-stub" hist
  make_repo "$repo"; mkdir -p "$stub"
  printf '# Review verdict — change — abc1234+uncommitted — 2026-01-05\n\n## Rejected\nF1 — noise\n' > "$repo/.review/verdict.md"
  run_review "$repo" "$stub" --lenses correctness
  hist="$(history_dir "$repo")"
  assert "um2: an uncommitted verdict is archived under its commit and marker" \
    sh -c 'cmp -s "$1" "$2"/code-2026-01-05-abc1234+uncommitted-*.md' _ "$repo/.review/verdict.md" "$hist"
  assert_not "um2: … not as code-unparsed" sh -c 'ls "$1" | grep -q unparsed' _ "$hist"
  assert_not "um2: … and without the unparsed warning" grep -qF 'has no standard verdict header' "$LOG"
  printf '# Spec verdict — change — abc1234+uncommitted — 2026-01-05\n' > "$repo/.review/spec-verdict.md"
  run_review "$repo" "$stub" --lenses correctness
  assert "um2: a spec header never carries the marker, so one that does is unparsed" \
    sh -c 'ls "$1"/spec-unparsed-*.md' _ "$hist"
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

# Repos upgraded from v1.2.1 keep their pre-upgrade history in .review/archive/,
# so /review-tune must keep reading it beside the review history (#38).
test_review_tune_docs_name_legacy_archive() {
  local tune="$KIT/.claude/commands/review-tune.md"
  assert "v5: /review-tune reads the review history" \
    sh -c 'grep -qF "git rev-parse --path-format=absolute --git-common-dir" "$1" && grep -qF "<that dir>/review-history" "$1"' _ "$tune"
  assert "v5: … and the legacy .review/archive/" grep -qF 'find <worktree>/.review/archive -type f' "$tune"
  assert "v5: … with its committed history" grep -qF "git log --all --name-status --format=%H -- ':/.review/archive/'" "$tune"
  assert "v5: … in every worktree" grep -qF '`git worktree list --porcelain`' "$tune"
  assert "v5: … counting a verdict in several stores once" grep -qF 'Count each verdict once' "$tune"
  assert "v5: … with a state for a store it could not read" grep -qF 'history is unknown, not empty' "$tune"
  assert "v5: REVIEW.md names both stores" \
    sh -c 'grep -qF review-history "$1" && grep -qF "/review-tune\` also reads \`.review/archive/\`" "$1"' _ "$KIT/REVIEW.md"
}

# /review-postmortem scored against whatever .review/verdict.md held, so a later
# review made findings it caught read as missed (#42). It must find the verdict
# whose header names the first commit CodeRabbit reviewed, or an ancestor of it,
# in the live files and the review history, and tell a failed read from none.
postmortem_snippet() { # postmortem_snippet <first> <pr-commit-file> — the doc's verdict-locating block, filled in
  awk '/^   ```bash$/ { f = 1; next } f && /^   ```$/ { exit } f { sub(/^   /, ""); print }' \
    "$KIT/.claude/commands/review-postmortem.md" | sed "1s|^first=.*|first=$1|; 2s|^pr_commits=.*|pr_commits=$2|"
}

test_postmortem_finds_the_verdict_for_the_reviewed_commit() {
  local repo="$WORK/p1" wt="$WORK/p1-wt" out="$WORK/p1.out" prs="$WORK/p1.commits" hist snippet a b o p rc rc2
  make_repo "$repo"
  ( cd "$repo" && git checkout -qb prev main && printf 'p\n' > p.txt && git add p.txt && git commit -qm prev \
      && git checkout -q main && git merge -q --no-ff prev -m 'merge prev' \
      && git checkout -q change && git merge -q main -m 'sync main' \
      && printf 'a\n' >> src.txt && git commit -qam a && printf 'b\n' >> src.txt && git commit -qam b )
  p=$(git -C "$repo" rev-parse --short prev)
  git -C "$repo" rev-list main..change > "$prs"
  a=$(git -C "$repo" rev-parse --short HEAD~1); b=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" worktree add -q -b other "$wt" main
  ( cd "$wt" && printf 'o\n' > o.txt && git add o.txt && git commit -qm other )
  o=$(git -C "$wt" rev-parse --short HEAD)
  hist="$(history_dir "$repo")"
  snippet="$(postmortem_snippet "$b" "$prs")"
  assert "p1: the postmortem carries a verdict-locating block" grep -qF 'git merge-base --is-ancestor' <<< "$snippet"

  ( cd "$repo" && bash -c "$snippet" ) > "$out" 2>&1; rc=$?
  assert "p1: no verdict and no history is an empty result, not a failure" \
    sh -c '[ "$1" -eq 0 ] && [ ! -s "$2" ]' _ "$rc" "$out"

  mkdir -p "$hist"
  printf '# Review verdict — change — %s — 2026-01-01\n' "${b:0:7}" > "$repo/.review/verdict.md"
  printf '# Review verdict — change — %s — 2026-01-01\n' "$a" > "$hist/code-2026-01-01-$a-1.md"
  printf '# Review verdict — other — %s — 2026-01-01\n' "$o" > "$wt/.review/verdict.md"
  printf '# Review verdict — prev — %s — 2026-01-01\n' "$p" > "$hist/code-2026-01-01-$p-5.md"
  printf '# Review verdict — gone — deadbeef — 2026-01-01\n\nLenses: correctness\n\n# Review verdict — change — %s — 2026-01-02\n' "$a" \
    > "$hist/code-2026-01-01-deadbeef-2.md"
  printf '# Review verdict — change — %s — 2026-01-01\n\nLenses: spec-holes · Effort: high\n' "${b:0:7}" \
    > "$hist/code-2026-01-01-oldspec-4.md"
  printf '# Spec verdict — change — %s — 2026-01-01\n' "${b:0:7}" > "$hist/spec-2026-01-01-${b:0:7}-3.md"
  printf '<!-- review-postmortem:v1 -->\n# Review verdict — change — %s — 2026-01-01\n' "${b:0:7}" > "$hist/postmortem-pr1.md"
  ( cd "$repo" && bash -c "$snippet" ) > "$out" 2>&1; rc=$?
  ( cd "$repo" && bash -c "$(expand_positional 50 --record-only <<< "$snippet")" ) > "$WORK/p1.expanded" 2>&1; rc2=$?

  assert "p1: the listing succeeds" test "$rc" -eq 0
  assert "p1: … and lists the same for /review-postmortem 50 --record-only" \
    sh -c '[ "$1" -eq 0 ] && [ -s "$2" ] && cmp -s "$2" "$3"' _ "$rc2" "$out" "$WORK/p1.expanded"
  assert "p1: the live verdict for the reviewed commit is 'same'" grep -qE "^same ${b:0:7} 1 .*/p1/\.review/verdict\.md$" "$out"
  assert "p1: an archived verdict for an earlier commit is 'ancestor'" grep -qE "^ancestor $a 1 .*/code-2026-01-01-$a-1\.md$" "$out"
  assert "p1: … and so is a second verdict in one file, at its own line" grep -qE "^ancestor $a 5 .*/code-2026-01-01-deadbeef-2\.md$" "$out"
  assert "p1: another worktree's verdict for an unrelated commit is 'other'" grep -qE "^other $o 1 .*/p1-wt/\.review/verdict\.md$" "$out"
  assert "p1: a commit this clone cannot place is 'other'" grep -qE '^other deadbeef 1 ' "$out"
  assert "p1: another PR's verdict that reached the base is 'other', not 'ancestor'" grep -qE "^other $p 1 " "$out"
  git -C "$repo" checkout -q main && git -C "$repo" merge -q --no-ff change -m 'merge change'
  git -C "$repo" checkout -q change
  ( cd "$repo" && bash -c "$snippet" ) > "$WORK/p1.merged" 2>&1
  assert "p1: … but this PR's own verdict stays 'ancestor' once the PR is merged" grep -qE "^ancestor $a 1 " "$WORK/p1.merged"
  assert_not "p1: spec verdicts, old-header spec verdicts and postmortem records are not candidates" \
    grep -qE 'spec-2026|postmortem-pr1|code-2026-01-01-oldspec' "$out"
  assert "p1: … so exactly six candidates" test "$(grep -c . "$out")" -eq 6

  # #53: an --uncommitted run on the compared commit is listed as such, never 'same'.
  printf '# Review verdict — change — %s+uncommitted — 2026-01-03\n' "${b:0:7}" > "$hist/code-2026-01-03-${b:0:7}+uncommitted-6.md"
  printf '# Review verdict — change — %s+uncommitted — 2026-01-03\n' "$a" > "$hist/code-2026-01-03-$a+uncommitted-7.md"
  printf '# Review verdict — other — %s+uncommitted — 2026-01-03\n' "$o" > "$hist/code-2026-01-03-$o+uncommitted-8.md"
  ( cd "$repo" && bash -c "$snippet" ) > "$WORK/p1.unc" 2>&1; rc=$?
  assert "um3: the listing succeeds" test "$rc" -eq 0
  assert "um3: an uncommitted verdict on the compared commit is 'uncommitted'" \
    grep -qE "^uncommitted ${b:0:7} 1 .*/code-2026-01-03-${b:0:7}\+uncommitted-6\.md$" "$WORK/p1.unc"
  assert "um3: … and so is one on an ancestor" grep -qE "^uncommitted $a 1 .*\+uncommitted-7\.md$" "$WORK/p1.unc"
  assert "um3: one on an unrelated commit stays 'other'" grep -qE "^other $o 1 .*\+uncommitted-8\.md$" "$WORK/p1.unc"
  assert_not "um3: none is 'same' or 'ancestor'" grep -qE '^(same|ancestor) .*\+uncommitted' "$WORK/p1.unc"
  assert "um3: … and the six earlier candidates are unchanged" \
    bash -c 'cmp -s <(grep -v +uncommitted "$1" | sort) <(sort "$2")' _ "$WORK/p1.unc" "$out"
  rm -f "$hist"/code-2026-01-03-*+uncommitted-*.md

  ( cd "$repo" && bash -c "$(postmortem_snippet 0123456789abcdef0123456789abcdef01234567 "$prs")" ) > "$out" 2>&1; rc=$?
  assert "p1: a compared commit this clone lacks fails the listing" \
    sh -c '[ "$1" -ne 0 ] && grep -qF "failed: the compared commit is not in this clone" "$2"' _ "$rc" "$out"

  rm -rf "$wt"
  ( cd "$repo" && bash -c "$snippet" ) > "$out" 2>&1; rc=$?
  assert "p1: a worktree whose directory is gone is named as unread" \
    sh -c '[ "$1" -eq 0 ] && grep -qE "^unread .*/p1-wt: worktree directory is missing$" "$2"' _ "$rc" "$out"

  if [ "$(id -u)" != 0 ]; then
    chmod 000 "$hist"
    ( cd "$repo" && bash -c "$snippet" ) > "$out" 2>&1; rc=$?
    chmod 755 "$hist"
    assert "p1: an unreadable review history fails" test "$rc" -ne 0
    assert "p1: … and says so instead of listing nothing" grep -qF 'is not readable' "$out"
    chmod 444 "$hist"
    ( cd "$repo" && bash -c "$snippet" ) > "$out" 2>&1; rc=$?
    chmod 755 "$hist"
    assert "p1: a review history that can be listed but not entered fails too" \
      sh -c '[ "$1" -ne 0 ] && grep -qF "is not readable" "$2"' _ "$rc" "$out"
    chmod 000 "$repo/.review/verdict.md"
    ( cd "$repo" && bash -c "$snippet" ) > "$out" 2>&1; rc=$?
    chmod 644 "$repo/.review/verdict.md"
    assert "p1: an unreadable verdict fails instead of reading as no verdict" \
      sh -c '[ "$1" -ne 0 ] && grep -qF "failed: cannot read" "$2"' _ "$rc" "$out"
    chmod 000 "$repo/.review"
    ( cd "$repo" && bash -c "$snippet" ) > "$out" 2>&1; rc=$?
    chmod 755 "$repo/.review"
    assert "p1: … and so does a .review/ that cannot be entered" \
      sh -c '[ "$1" -ne 0 ] && grep -qF "/.review is not readable" "$2"' _ "$rc" "$out"
  else
    skip_test "p1: unreadable review history (running as root)"
  fi
}

# A finding raised on a later head was unscored whenever its *file* had changed since
# the verdict, which hid misses and catches on every multi-round PR (#59). The
# postmortem now blames the cited lines over the commits after the verdict.
postmortem_blame() { # postmortem_blame <verdict-sha> <finding-commit> <file> <start> <end> — the doc's per-finding compare, run
  local cmd words
  cmd="$(grep -o 'git blame [^`]*' "$KIT/.claude/commands/review-postmortem.md" | head -n1)"
  cmd="${cmd//<verdict-sha>/$1}"; cmd="${cmd//<finding-commit>/$2}"; cmd="${cmd//<file>/$3}"
  cmd="${cmd//<start>/$4}"; cmd="${cmd//<end>/$5}"
  read -ra words <<< "$cmd"
  "${words[@]}"
}

test_postmortem_scores_code_present_at_the_verdict() {
  local repo="$WORK/pp" out="$WORK/pp.out" v c1 c2 rc
  git init -q "$repo"
  git -C "$repo" config user.email review-test@example.invalid
  git -C "$repo" config user.name review-test
  for i in 1 2 3 4 5 6 7 8 9 10; do printf 'value = %s;\n' "$i"; done > "$repo/f.txt"
  git -C "$repo" add f.txt && git -C "$repo" commit -qm verdict
  v=$(git -C "$repo" rev-parse HEAD)
  { printf 'new a\nnew b\n'; sed 's/^value = 8;$/value = 80;/' "$repo/f.txt"; } > "$repo/f.tmp" && mv "$repo/f.tmp" "$repo/f.txt"
  git -C "$repo" commit -qam 'round 1'
  c1=$(git -C "$repo" rev-parse HEAD)
  printf 'tail\n' >> "$repo/f.txt" && git -C "$repo" commit -qam 'round 2'
  c2=$(git -C "$repo" rev-parse HEAD)
  assert "pp1: the postmortem names a per-finding blame" test -n "$(grep -o 'git blame [^`]*' "$KIT/.claude/commands/review-postmortem.md")"

  ( cd "$repo" && postmortem_blame "$v" "$c2" f.txt 3 9 ) > "$out" 2>&1; rc=$?
  assert "pp1: lines a later commit only moved existed at the verdict" \
    sh -c '[ "$1" -eq 0 ] && [ "$(grep -c . "$2")" -eq 7 ] && ! grep -q "^[0-9a-f]" "$2"' _ "$rc" "$out"
  ( cd "$repo" && postmortem_blame "$v" "$c2" f.txt 9 10 ) > "$out" 2>&1; rc=$?
  assert "pp1: a line a later commit rewrote is blamed on that commit" \
    sh -c '[ "$1" -eq 0 ] && grep -q "^$2 " "$3"' _ "$rc" "$c1" "$out"
  ( cd "$repo" && postmortem_blame "$v" "$c2" f.txt 13 13 ) > "$out" 2>&1; rc=$?
  assert "pp1: … and so is one it appended" sh -c '[ "$1" -eq 0 ] && grep -q "^$2 " "$3"' _ "$rc" "$c2" "$out"

  git -C "$repo" config blame.blankBoundary true
  printf '%s\n' "$c1" > "$repo/.ignore-revs"
  git -C "$repo" config blame.ignoreRevsFile .ignore-revs
  ( cd "$repo" && postmortem_blame "$v" "$c2" f.txt 10 10 ) > "$out" 2>&1; rc=$?
  assert "pp1: a configured ignore-revs file cannot hide an edit" \
    sh -c '[ "$1" -eq 0 ] && grep -q "^$2 " "$3"' _ "$rc" "$c1" "$out"
  ( cd "$repo" && postmortem_blame "$v" "$c2" f.txt 3 4 ) > "$out" 2>&1; rc=$?
  assert "pp1: with blankBoundary, a line at the verdict is blank, not a SHA" \
    sh -c '[ "$1" -eq 0 ] && [ "$(grep -c "^ " "$2")" -eq 2 ]' _ "$rc" "$out"

  ( cd "$repo" && postmortem_blame "$v" "$c2" f.txt 40 41 ) > "$out" 2>&1; rc=$?
  assert "pp1: lines past the end fail, not read as unchanged" test "$rc" -ne 0
  ( cd "$repo" && postmortem_blame "$v" "$c2" gone.txt 1 1 ) > "$out" 2>&1; rc=$?
  assert "pp1: … and so does a path the commit lacks" test "$rc" -ne 0
  ( cd "$repo" && postmortem_blame "$v" 0123456789abcdef0123456789abcdef01234567 f.txt 1 1 ) > "$out" 2>&1; rc=$?
  assert "pp1: … and a finding commit this clone lacks" test "$rc" -ne 0
}

# The lens logs are evidence only for the verdict adjudicated from the run that wrote
# them; a second run on the same commit has the same head, mode and finding IDs.
test_postmortem_lens_evidence_belongs_to_one_run() {
  local repo="$WORK/pe" stub="$WORK/pe-stub" hist cmd
  cmd="$(grep -o 'find \.review/verdict\.md -newer \.review/findings\.json' "$KIT/.claude/commands/review-postmortem.md" | head -n1)"
  assert "pe1: the postmortem names the run check" test -n "$cmd"
  make_repo "$repo"; mkdir -p "$stub"
  rm -f "$repo/.review/verdict.md"
  run_review "$repo" "$stub" --lenses correctness
  sleep 1
  printf '# Review verdict — change — %s — 2026-01-01\n' "$(git -C "$repo" rev-parse --short HEAD)" > "$repo/.review/verdict.md"
  assert "pe1: a verdict written after the run owns its logs" \
    sh -c 'cd "$1" && [ "$($2)" = .review/verdict.md ]' _ "$repo" "$cmd"
  sleep 1
  run_review "$repo" "$stub" --lenses correctness
  hist="$(history_dir "$repo")"
  assert "pe1: … and no longer does once another run replaced them" \
    sh -c 'cd "$1" && [ -z "$($2)" ]' _ "$repo" "$cmd"
  assert "pe1: … nor does its archived copy" \
    sh -c 'cd "$1" && ls "$2"/code-2026-01-01-*.md && [ -z "$(find "$2" -name "code-2026-01-01-*.md" -newer .review/findings.json)" ]' _ "$repo" "$hist"
}

test_postmortem_docs_score_per_finding_and_cite_lens_evidence() {
  local pm="$KIT/.claude/commands/review-postmortem.md"
  assert_not "pp2: no whole-file compare decides a finding" grep -qF 'git diff --quiet <verdict-sha>' "$pm"
  assert "pp2: presence is decided per finding, never per file" grep -qF 'Decide that per finding, never per file' "$pm"
  assert "pp2: … reading the verdict's code where the lines were rewritten" grep -qF 'flaw_at_compared: <file>:<line>' "$pm"
  assert "pp2: … and naming the commit that brought a defect in" grep -qF 'added_after: <short sha>' "$pm"
  assert "pp2: a failed or denied compare is never a guessed class" grep -qF 'A class comes only from a compare that ran' "$pm"
  assert "pp2: the status line counts failed compares" grep -qF 'unscored U (compare_failed F)`' "$pm"
  assert "pp2: a denied command is unknown, not empty" grep -qF 'Its result is unknown, not' "$pm"
  assert "pp2: replay mode allows only one plain command per call" grep -qF '**One plain command per Bash call.**' "$pm"
  assert "pp2: … and a denied compare says so" grep -qF '`compare_failed: denied: <command>`' "$pm"
  assert "pp2: causes come from the lens logs" grep -qF '`log-<lens>.txt` holds what it ran and read' "$pm"
  assert "pp2: … only when they belong to the verdict's run" grep -qF "jq -r '.head, .mode' .review/findings.json" "$pm"
  assert "pp2: … and to the run that wrote it, not another on that commit" grep -qF 'find .review/verdict.md -newer .review/findings.json' "$pm"
  assert "pp2: … searched with the Grep tool, not a shell command" grep -qF "with the Grep tool, not a shell command" "$pm"
  assert "pp2: an unchanged anchor line is not proof the defect was there" grep -qF "rest on code a later commit changed elsewhere" "$pm"
  assert "pp2: a PR path is quoted in every command" grep -qF "put it in single quotes in every" "$pm"
  assert "pp2: … and one holding a quote is never run" grep -qF "compare_failed: unsafe path" "$pm"
  assert "pp2: a defect resting on another file is compared there too" grep -qF "other file the defect rests on" "$pm"
  assert "pp2: … and a file added after the verdict is added_after, not a failure" grep -qF "for \`added_after\`, not a failed compare" "$pm"
  assert "pp2: … once a rename is ruled out" grep -qF 'git diff -M --name-status <verdict-sha> <finding-commit>' "$pm"
  assert "pp2: a rejection is judged by the adjudication REJECT rules" grep -qF "Judge it by the REJECT rules of" "$pm"
  assert "pp2: … and are cited in the record" grep -qF '"cause_evidence": null' "$pm"
  assert "pp2: without them the cause is unverified" grep -qF 'is `unverified`, and `cause_evidence` says which file' "$pm"
  assert "pp2: … counted apart from the four causes" grep -qF '/ structural d / unverified e)' "$pm"
  assert "pp2: replay mode names its lens evidence" grep -qF '`<record>/raw/log-<lens>.txt`' "$pm"
}

# Claude writes the verdict header, so the marker lives in the procedure it follows (#53).
test_uncommitted_marker_docs() {
  local pm="$KIT/.claude/commands/review-postmortem.md"
  assert "um4: adjudication marks an --uncommitted verdict's header" \
    grep -qF '`<head>+uncommitted`, with `<head>` copied from `findings.json`' "$KIT/.review/adjudication.md"
  assert "um4: the postmortem never scores it, and names each one it skips" \
    sh -c 'grep -qF "never a pre-PR catch" "$1" && grep -qF "skipped uncommitted-run verdict <file>" "$1"' _ "$pm"
  assert "um4: /review-tune still reads it as a code verdict" \
    grep -qF 'it is a code verdict, so read its rejections like any' "$KIT/.claude/commands/review-tune.md"
  assert "um4: REVIEW.md documents mode and head" \
    sh -c 'grep -qF "| \`mode\` |" "$1" && grep -qF "| \`head\` |" "$1"' _ "$KIT/REVIEW.md"
}

# Every $<n> is rewritten, prose included ("$5 per run"). Codex does not fill
# skill bodies in, but its model reads a $<n> there as an argument.
test_expanded_files_hold_no_positional_refs() {
  local f files=() hits rc
  for f in "$KIT"/.claude/commands/*.md "$KIT"/.claude/skills/*/SKILL.md "$KIT"/.codex/skills/*/SKILL.md; do
    [ -f "$f" ] && files+=("$f")
  done
  assert "c1: the command and skill files are found" test "${#files[@]}" -ge 7
  assert "c1: the filler rewrites \$<n> from 0 and leaves the rest" \
    test "$(printf 'x $0 $1 $3 $NF ${1}\n' | expand_positional 50 --record-only)" = 'x 50 --record-only $3 $NF ${1}'
  [ "${#files[@]}" -gt 0 ] || return
  hits="$(grep -nE '\$[0-9]' "${files[@]}")"; rc=$?
  assert "c1: the files can be read" test "$rc" -le 1
  if [ -z "$hits" ]; then pass "c1: no \$<n> in a file Claude Code fills in"
  else fail "c1: no \$<n> in a file Claude Code fills in"; printf '%s\n' "$hits" | sed "s|^$KIT/|       |"; fi
}

test_postmortem_docs_record_and_route() {
  local pm="$KIT/.claude/commands/review-postmortem.md" tune="$KIT/.claude/commands/review-tune.md"
  assert "p2: compares against the first head CodeRabbit reviewed" grep -qF '**first head CodeRabbit reviewed**' "$pm"
  assert "p2: … handles a verdict for an ancestor of it" grep -qF '**No `same`, but an `ancestor`**' "$pm"
  assert "p2: … and leaves code brought in after the verdict unscored" grep -qF '`unscored_reason` `changed`' "$pm"
  assert "p2: no local verdict is its own status" grep -qF 'review-postmortem: no-local-verdict' "$pm"
  assert "p2: … recorded with null counts, never zeros" grep -qF '`missed_by_cause` to `null`, never zeros' "$pm"
  assert "p2: a failed read is not an empty one" grep -qF 'read is never reported as an empty result' "$pm"
  assert "p2: the scorecard comment has a stable marker" grep -qF '<!-- review-postmortem:v1 -->' "$pm"
  assert "p2: … and a machine-readable record" grep -qF '"schema": "review-postmortem/v1"' "$pm"
  assert "p2: … updated in place on a re-run" grep -qF 'gh api -X PATCH repos/{owner}/{repo}/issues/comments/<id>' "$pm"
  assert "p2: … never duplicated when a lookup fails" grep -qF 'do not create a comment, because it could duplicate one' "$pm"
  assert "p2: … and so is the step-6 update of it" grep -qF 'review-postmortem: lessons — comment <updated|NOT updated' "$pm"
  assert "p2: proposals are kept in the record" grep -qF '"proposals": [{"route": "repo | hub"' "$pm"
  assert "p2: an unscored finding says whether git could compare" grep -qF '"unscored_reason": "changed | compare_failed: <error> | no_local_verdict | null"' "$pm"
  assert "p2: the record's outcome is part of the status contract" grep -qF 'review-postmortem: record — comment <posted|updated|NOT posted' "$pm"
  assert "p2: an unattended caller never waits for approval" grep -qF '`--record-only` is for unattended callers' "$pm"
  assert "p2: a failed fetch is a failure, not a missing verdict" grep -qF 'fetch fails, stop with `failed — fetch`' "$pm"
  assert "p2: a shallow clone is deepened before ancestry is judged" grep -qF '`git fetch --unshallow`: a missing ancestor would read as `other`' "$pm"
  assert "p2: a failed hub check files nothing" grep -qF 'If either check' "$pm"
  assert "p2: … with a local copy in the review history" grep -qF '<git common dir>/review-history/postmortem-pr<n>.md' "$pm"
  assert "p2: … recording findings the author rejected in a thread" grep -qF '`rejected` (a reply that' "$pm"
  assert "p2: hub lessons are filed as issues" grep -qF 'gh issue create -R theunisdk/codex-review-kit --label lesson' "$pm"
  assert "p2: … creating the label, or saying it filed without one" \
    sh -c 'grep -qF "gh label create lesson" "$1" && grep -qF "file the issue without a label and say so" "$1"' _ "$pm"
  assert "p2: … and the fallback drops the label from the command" grep -qF 'run the same command with no `--label lesson`' "$pm"
  assert "p2: … and a failed label check is not a missing label" grep -qF 'that is a failed label lookup, not a missing label' "$pm"
  assert_not "p2: no lesson is committed in a local hub clone" grep -qE 'Commit there|commit it in the hub' "$pm" "$tune"
}

test_review_tune_docs_read_postmortem_records() {
  local tune="$KIT/.claude/commands/review-tune.md"
  assert "p3: /review-tune reads postmortem records" grep -qF '`postmortem-pr<n>.md`' "$tune"
  assert "p3: … and the PR comments other clones wrote" grep -qF 'comment marked `<!-- review-postmortem:v1 -->`' "$tune"
  assert "p3: … with a state for comments it could not read" grep -qF 'report the PR comments as unread' "$tune"
  assert "p3: … but only records by its own login" grep -qF 'Accept only comments by your own login' "$tune"
  assert "p3: … and CodeRabbit findings the author rejected" grep -qF 'finding whose `author` is `rejected`' "$tune"
  assert "p3: … reading an unscored postmortem as unscored" grep -qF '`counts` are `null`, not zero' "$tune"
  assert "p3: … and never suppressing a class CodeRabbit proved real" grep -qF 'classed `missed` or `rejected-wrongly`' "$tune"
  assert "p3: hub lessons are issues, not hub commits" grep -qF 'never as a commit in a local hub clone' "$tune"
  assert "p3: REVIEW.md says the postmortem reads and writes the review history" \
    grep -qF '`/review-postmortem` reads it to find the verdict' "$KIT/REVIEW.md"
}

# A plateau in `missed` was read as proof of value the pipeline cannot reproduce,
# before anyone had classified the misses by cause (#43).
test_postmortem_plateau_is_a_hypothesis() {
  local f
  for f in OPERATING.md REVIEW.md .claude/commands/review-postmortem.md; do
    assert "p4: $f frames a plateau as a hypothesis" grep -qF 'hypothesis' "$KIT/$f"
  done
  assert_not "p4: OPERATING.md no longer reads a plateau as proof" grep -qF 'that residue is the part' "$KIT/OPERATING.md"
  assert_not "p4: … nor does REVIEW.md" grep -qF 'If it plateaus, the honest read' "$KIT/REVIEW.md"
  assert "p4: OPERATING.md says the postmortem leaves a record" grep -qF 'chat output alone is not a record' "$KIT/OPERATING.md"
}

# --- replay fixtures -------------------------------------------------------
# A hub holding this checkout's kit (tracked and new files), a spoke cloned from
# a bare remote that serves refs/pull/<n>/head, and stubs for gh and claude that
# log every call. The claude stub answers from per-call fixtures, with the
# checkout's HEAD substituted for @SHA@ / @SHORT@, and reports no cost when
# $CLAUDE_STUB_DIR/no-cost exists. $CLAUDE_STUB_DIR/on-<kind>-<PR> runs first.
# Asked for stream-json, it streams a tool call before its result, which reports
# the denials in $CLAUDE_STUB_DIR/<kind>.denials (default none), or no list at all
# when that file holds "absent", and no result when $CLAUDE_STUB_DIR/<kind>.no-result
# exists; asked for json, it prints the result alone.
mkdir -p "$WORK/bin-replay"
cat > "$WORK/bin-replay/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB_DIR/calls.log"
key=""
case "$1 ${2:-}" in
  "pr view")        key="pr-view-$3" ;;
  "pr list")        key="pr-list" ;;
  "api --paginate") key="api-$(printf '%s' "$3" | tr '/' '_')" ;;
  "api "*)          key="api-$(printf '%s' "$2" | tr '/' '_')" ;;
esac
[ -n "$key" ] && [ -f "$GH_STUB_DIR/$key.json" ] || { echo "HTTP 404: Not Found ($*)" >&2; exit 1; }
cat "$GH_STUB_DIR/$key.json"
EOF
cat > "$WORK/bin-replay/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${*:3}" >> "$CLAUDE_STUB_DIR/calls.log"
i=0; for a in "$@"; do i=$((i + 1)); [ "$i" -le 2 ] || printf '[%s]' "$a"; done >> "$CLAUDE_STUB_DIR/argv.log"; echo >> "$CLAUDE_STUB_DIR/argv.log"
case "$2" in
  "Replay adjudication"*) kind=adjudicate ;;
  "Replay postmortem"*)   kind=postmortem ;;
  *) echo "unexpected prompt" >&2; exit 1 ;;
esac
[ ! -e .review/replay ] || touch "$CLAUDE_STUB_DIR/$kind.saw-github-data"
[ -z "${CLAUDE_STUB_SLEEP:-}" ] || { pwd -P > "$CLAUDE_STUB_DIR/cwd"; echo "$$" > "$CLAUDE_STUB_DIR/started"; sleep "$CLAUDE_STUB_SLEEP"; }
pr="$(printf '%s\n' "$2" | sed -n '1s/.* PR #\([0-9]*\).*/\1/p')"
[ ! -x "$CLAUDE_STUB_DIR/on-$kind-$pr" ] || "$CLAUDE_STUB_DIR/on-$kind-$pr"
sed -e "s/@SHA@/$(git rev-parse HEAD)/g" -e "s/@SHORT@/$(git rev-parse --short HEAD)/g" -e "s/@PR@/$pr/g" \
  "$CLAUDE_STUB_DIR/$kind.txt" > "$CLAUDE_STUB_DIR/$kind.reply"
denials='[]'; [ ! -e "$CLAUDE_STUB_DIR/$kind.denials" ] || denials="$(cat "$CLAUDE_STUB_DIR/$kind.denials")"
format=""; prev=""; for a in "$@"; do [ "$prev" != --output-format ] || format="$a"; prev="$a"; done
if [ "$format" = stream-json ]; then
  printf '{"type":"system","subtype":"init","cwd":"%s"}\n' "$PWD"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git log --all"}}]}}\n'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"stub %s history"}]}}\n' "$kind"
fi
[ ! -e "$CLAUDE_STUB_DIR/$kind.no-result" ] || exit 0
jq -cn --rawfile r "$CLAUDE_STUB_DIR/$kind.reply" --argjson cost "$([ -e "$CLAUDE_STUB_DIR/no-cost" ] && echo null || echo 0.25)" \
  --arg d "$denials" '{type: "result", subtype: "success", is_error: false, result: $r} + (if $cost then {total_cost_usd: $cost} else {} end)
    + (if $d == "absent" then {} else {permission_denials: ($d | fromjson)} end)'
EOF
chmod +x "$WORK/bin-replay/gh" "$WORK/bin-replay/claude"

replay_hub() { # replay_hub <dir> — this checkout's kit as one commit on main
  git init -q -b main "$1"
  ( cd "$KIT" && git ls-files -co --exclude-standard -z | xargs -0 tar -cf - ) | tar -xf - -C "$1"
  ( cd "$1" && git config user.email review-test@example.invalid && git config user.name review-test \
      && git add -A && git commit -qm kit )
}

gh_json() { # gh_json <stubdir> <key> <json>
  printf '%s\n' "$3" > "$1/$2.json"
}

gh_pr_fixture() { # gh_pr_fixture <stubdir> <n> <first-reviewed sha> <head sha> <base tip>
  local d="$1" n="$2" a="$3" b="$4" m="$5" cr='{"login":"coderabbitai[bot]"}'
  gh_json "$d" "pr-view-$n" "{\"number\":$n,\"url\":\"https://example.invalid/pull/$n\",\"author\":{\"login\":\"dev\"},\"state\":\"MERGED\",\"baseRefName\":\"main\",\"headRefName\":\"feat-$n\",\"headRefOid\":\"$b\",\"commits\":[{\"oid\":\"$a\"},{\"oid\":\"$b\"}]}"
  gh_json "$d" "api-repos_o_r_pulls_$n" "{\"number\":$n,\"base\":{\"sha\":\"$m\"},\"merge_commit_sha\":\"$m\"}"
  # an empty-bodied review (a thread reply) and a rate-limited status come earlier, and neither is a review
  gh_json "$d" "api-repos_o_r_pulls_${n}_reviews" "[{\"user\":$cr,\"body\":\"\",\"commit_id\":\"$b\",\"submitted_at\":\"2026-01-01T09:00:00Z\"},{\"user\":$cr,\"body\":\"**Actionable comments posted: 1**\",\"commit_id\":\"$a\",\"submitted_at\":\"2026-01-01T10:00:00Z\"}]"
  gh_json "$d" "api-repos_o_r_pulls_${n}_comments" "[{\"id\":7,\"user\":$cr,\"path\":\"src.txt\",\"original_commit_id\":\"$a\",\"body\":\"off by one\"}]"
  gh_json "$d" "api-repos_o_r_issues_${n}_comments" "[]"
  gh_json "$d" "api-repos_o_r_commits_${a}_statuses" "[]"
  gh_json "$d" "api-repos_o_r_commits_${b}_statuses" "[{\"creator\":$cr,\"context\":\"CodeRabbit\",\"state\":\"success\",\"description\":\"Review rate limited\",\"created_at\":\"2026-01-01T08:00:00Z\"}]"
}

# $RS: spoke · $RREMOTE: its origin · $RHUB: the hub · $RGH / $RCL / $RCX: gh, claude, codex stub dirs
# PR 1: A (first reviewed) then B, squash-merged as S · PR 2: a pre-hub kit
# PR 3: PR 1's commits again · PR 4: a GitHub read fails · PR 5: CodeRabbit never reviewed it
# PR 6: merged with a merge commit, reviewed only by a status · PR 7: still open · PR 8: a symlinked REVIEW.md
# PR 9: its reviewed commit has a .review/config.sh that never merged
replay_fixture() { # replay_fixture <id> — the spoke in $REPLAY_OBJECT_FORMAT when set
  local id="$1" m a b s p c6 m6 l8 c9
  RS="$WORK/$id-spoke"; RREMOTE="$WORK/$id-remote.git"; RHUB="$WORK/$id-hub"
  RGH="$WORK/$id-gh"; RCL="$WORK/$id-claude"; RCX="$WORK/$id-codex"
  mkdir -p "$RGH" "$RCL" "$RCX"
  replay_hub "$RHUB"
  local src="$WORK/$id-src"
  git init -q -b main ${REPLAY_OBJECT_FORMAT:+--object-format="$REPLAY_OBJECT_FORMAT"} "$src"
  (
    cd "$src" || exit 1
    git config user.email review-test@example.invalid; git config user.name review-test
    mkdir -p .review
    printf 'kit: https://github.com/theunisdk/codex-review-kit 1234567\nrelease: v1.2.0\n' > .review/kit-version
    printf 'house rules\n' > .review/rubric.md
    printf 'LENSES="correctness"\n' > .review/config.sh
    printf 'seed\n' > src.txt
    git add -A && git commit -qm base
    git checkout -qb feat
    printf 'a\n' >> src.txt && git commit -qam a
    printf 'b\n' >> src.txt && git commit -qam b
    git checkout -q main
    printf 'learned\n' > .review/learnings.md
    cp src.txt src.txt.keep && git show feat:src.txt > src.txt && rm src.txt.keep
    git add -A && git commit -qm 'squash of feat'
    git checkout -qb prehub main~1
    printf 'kit: https://github.com/theunisdk/ai-dev 7654321\n' > .review/kit-version
    git commit -qam 'pre-hub change'
    git checkout -qb merged6 main~1
    printf 'six\n' > six.txt && git add six.txt && git commit -qm six
    git checkout -qb link8 main~1
    ln -s ../../../outside.txt REVIEW.md && git add REVIEW.md && git commit -qm link
    git checkout -qb config9 main~1
    printf 'LENSES="correctness"\ntouch /tmp/never\n' > .review/config.sh && git commit -qam config
    git checkout -q main
    git merge -q --no-ff merged6 -m 'merge six'
  )
  m=$(git -C "$src" rev-parse main); a=$(git -C "$src" rev-parse feat~1); b=$(git -C "$src" rev-parse feat)
  p=$(git -C "$src" rev-parse prehub); c6=$(git -C "$src" rev-parse merged6); l8=$(git -C "$src" rev-parse link8); c9=$(git -C "$src" rev-parse config9)
  git clone -q --bare "$src" "$RREMOTE"
  git -C "$RREMOTE" config uploadpack.allowAnySHA1InWant true
  git -C "$RREMOTE" update-ref refs/pull/1/head "$b"
  git -C "$RREMOTE" update-ref refs/pull/2/head "$p"
  git -C "$RREMOTE" update-ref refs/pull/3/head "$b"
  git -C "$RREMOTE" update-ref refs/pull/4/head "$b"
  git -C "$RREMOTE" update-ref refs/pull/5/head "$b"
  git -C "$RREMOTE" update-ref refs/pull/6/head "$c6"
  git -C "$RREMOTE" update-ref refs/pull/7/head "$b"
  git -C "$RREMOTE" update-ref refs/pull/8/head "$l8"
  git -C "$RREMOTE" update-ref refs/pull/9/head "$c9"
  git -C "$RREMOTE" for-each-ref --format='delete %(refname)' refs/heads/feat refs/heads/prehub refs/heads/merged6 refs/heads/link8 refs/heads/config9 \
    | git -C "$RREMOTE" update-ref --stdin
  git clone -q "$RREMOTE" "$RS"
  printf '.claude/worktrees/\n' >> "$RS/.git/info/exclude"
  gh_pr_fixture "$RGH" 1 "$a" "$b" "$m"
  gh_pr_fixture "$RGH" 2 "$p" "$p" "$m"
  gh_pr_fixture "$RGH" 3 "$a" "$b" "$m"
  gh_pr_fixture "$RGH" 4 "$a" "$b" "$m"; rm "$RGH/api-repos_o_r_pulls_4_comments.json"
  gh_pr_fixture "$RGH" 5 "$a" "$b" "$m"
  gh_json "$RGH" api-repos_o_r_pulls_5_reviews '[]'
  gh_pr_fixture "$RGH" 6 "$c6" "$c6" "$m"
  gh_json "$RGH" api-repos_o_r_pulls_6 "{\"number\":6,\"base\":{\"sha\":\"$m\"},\"merge_commit_sha\":\"$m\"}"
  gh_json "$RGH" api-repos_o_r_pulls_6_reviews '[]'
  gh_json "$RGH" "api-repos_o_r_commits_${c6}_statuses" '[{"creator":{"login":"coderabbitai[bot]"},"context":"CodeRabbit","state":"success","description":"Review completed","created_at":"2026-01-02T08:00:00Z"}]'
  gh_pr_fixture "$RGH" 7 "$a" "$b" "$m"
  sed 's/"MERGED"/"OPEN"/' "$RGH/pr-view-7.json" > "$RGH/pr-view-7.tmp" && mv "$RGH/pr-view-7.tmp" "$RGH/pr-view-7.json"
  gh_pr_fixture "$RGH" 8 "$l8" "$l8" "$m"
  gh_pr_fixture "$RGH" 9 "$c9" "$c9" "$m"
  gh_json "$RGH" pr-list '[{"number":5,"mergedAt":"2026-01-05T00:00:00Z"},{"number":1,"mergedAt":"2026-01-04T00:00:00Z"},{"number":3,"mergedAt":"2026-01-01T00:00:00Z"}]'
  RA="$a"
  finding 'replayed finding' > "$RCX/correctness.json"; printf '1,234\n' > "$RCX/correctness.tokens"
  cat > "$RCL/adjudicate.txt" <<'EOF'
Here is the verdict.

```markdown
# Review verdict — feat-1 — @SHORT@ — 2026-01-01

1 findings · 1 fixed · 0 logged · 0 rejected · 0 escalated
Lenses: correctness · Effort: high · Secrets: not_scanned
```
EOF
  cat > "$RCL/postmortem.txt" <<'EOF'
review-postmortem: scored — PR #@PR@: caught 1 / missed 1 / rejected-wrongly 0 / noise 0 / unscored 0
review-postmortem: record — replay: comment not posted; local copy written by the caller

<!-- review-postmortem:v1 -->
## Review postmortem — PR #@PR@

<details><summary>Machine-readable record</summary>

```json
{"schema": "review-postmortem/v1", "pr": @PR@, "status": "scored", "compared_commit": "@SHA@",
 "counts": {"caught": 1, "missed": 1, "rejected_wrongly": 0, "noise": 0, "unscored": 0},
 "missed_by_cause": {"wrong_lens": 1, "tracing": 0, "threshold": 0, "structural": 0},
 "findings": [{"file": "src.txt", "summary": "replayed finding", "class": "caught", "cause": null},
              {"file": "src.txt", "summary": "off by one", "class": "missed", "cause": "wrong_lens"}],
 "proposals": [{"route": "hub", "file": ".review/prompts/correctness.md", "lines": "hunt for off-by-one", "cause": "wrong_lens"}],
 "lessons": []}
```
</details>
EOF
}

run_replay() { # run_replay <args...> — output in $LOG
  LOG="$RS.replay.log"
  PATH="$WORK/bin-replay:$WORK/bin:$PATH" GH_STUB_DIR="$RGH" CLAUDE_STUB_DIR="$RCL" CODEX_STUB_DIR="$RCX" \
    REVIEW_SKIP_AUTH_CHECK=1 bash "$RHUB/scripts/review-replay.sh" "$RS" --repo o/r --no-analyzers "$@" > "$LOG" 2>&1
}

last_run() { sed -n 's/^review-replay: run record — //p' "$LOG"; } # the run dir of the last run_replay

no_replay_worktrees() { # the spoke has only its own checkout, and no replay directory
  [ "$(git -C "$1" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] && [ -z "$(ls -A "$1/.claude/worktrees" 2>/dev/null)" ]
}

# --- replay tests ----------------------------------------------------------
test_replay_scores_reports_and_writes_nothing_else() {
  local rc rec refs_before common short kit runs run
  replay_fixture r1
  # a fetch refspec for pull refs would let a fetch update refs/remotes/origin/pr/*
  git -C "$RS" config --add remote.origin.fetch '+refs/pull/*/head:refs/remotes/origin/pr/*'
  refs_before="$(git -C "$RS" for-each-ref)"
  run_replay --limit 10 1 2 4 5 6 7 8 9; rc=$?
  common="$(cd "$RS" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  short="$(git -C "$RS" rev-parse --short "$RA")"; kit="$(git -C "$RHUB" rev-parse --short main)"
  rec="$common/review-replay/pr1-$kit"
  assert "r1: a failed PR fails the run" test "$rc" -eq 1
  assert "r1: PR 1 is replayed against the first commit CodeRabbit reviewed" \
    grep -qF "review-replay: replayed — PR #1 ($short, kit $kit): caught 1 / missed 1 (wrong lens 1 / tracing 0 / threshold 0 / structural 0 / unverified 0) / rejected-wrongly 0 / noise 0 / unscored 0 (compare_failed 0)" "$LOG"
  assert "r1: a pre-hub kit is skipped with its reason" \
    grep -qE '^review-replay: skipped — PR #2: pre-hub review kit at [0-9a-f]{7} \(https://github.com/theunisdk/ai-dev\)' "$LOG"
  assert "r1: a failed GitHub read is a failure, not a skip" \
    grep -qE '^review-replay: failed — PR #4: github: gh api --paginate repos/o/r/pulls/4/comments exited 1: HTTP 404' "$LOG"
  assert "r1: a PR CodeRabbit never reviewed is skipped" \
    grep -qxF 'review-replay: skipped — PR #5: CodeRabbit has not reviewed PR #5' "$LOG"
  assert "r1: a merge-commit PR reviewed only by a status is replayed from the merge's first parent" \
    sh -c 'grep -qE "^review-replay: replayed — PR #6 " "$1" && jq -e --arg b "$2" ".replay.base == \$b" "$3"' \
    _ "$LOG" "$(git -C "$RS" rev-parse "$RA~1")" "$common/review-replay/pr6-$kit/record.json"
  assert "r1: an open PR is skipped, because a replay runs its config" \
    grep -qE '^review-replay: skipped — PR #7: PR #7 is OPEN, not merged' "$LOG"
  assert "r1: a symlink in the kit's paths is skipped" \
    grep -qE "^review-replay: skipped — PR #8: symlink in the kit's paths at [0-9a-f]{7} \(REVIEW.md\)" "$LOG"
  assert "r1: … and nothing is written through it" test ! -e "$RS/outside.txt"
  assert "r1: a reviewed commit whose config.sh never merged is skipped" \
    grep -qE '^review-replay: skipped — PR #9: .review/config.sh at [0-9a-f]{7} differs from the merged one' "$LOG"
  assert "r1: the aggregate sums the scorecards" \
    grep -qxF 'review-replay: aggregate — replayed 2 / incomplete 0 / skipped 5 / failed 1 — caught 2 / missed 2 (wrong lens 2 / tracing 0 / threshold 0 / structural 0 / unverified 0) / rejected-wrongly 0 / noise 0 / unscored 0 (compare_failed 0)' "$LOG"
  assert "r1: … and groups lessons by cause" \
    sh -c 'grep -qxF "lessons — wrong_lens (2 missed):" "$1" && grep -qF "PR #1 propose (hub) .review/prompts/correctness.md" "$1"' _ "$LOG"
  assert "r1: … and the cost line covers every PR" grep -qxF 'review-replay: cost — claude $1.00, codex 2468 tokens, failed and skipped PRs included' "$LOG"
  runs="$common/review-replay/runs"
  assert "r1: the run keeps its own record, named for its kit" \
    sh -c '[ "$(ls "$1" | wc -l)" -eq 1 ] && ls "$1" | grep -qE "^[0-9]{8}T[0-9]{6}Z-$2\$"' _ "$runs" "$kit"
  run="$runs/$(ls "$runs")"
  assert "r1: … says where it is" grep -qxF "review-replay: run record — $run" "$LOG"
  assert "r1: … and opens with the kit and how its freshness was checked" \
    sh -c 'head -n1 "$1" | grep -qE "^review-replay: run — spoke .* \(o/r\) · kit .*\($2, unchecked: tracks no remote branch\)\$"' _ "$run/summary.txt" "$kit"
  assert "r1: … with every line the run printed" \
    sh -c 'grep -qE "^review-replay: replayed — PR #1 " "$1" && grep -qE "^review-replay: failed — PR #4: " "$1" && grep -qF "review-replay: aggregate — replayed 2 / incomplete 0 / skipped 5 / failed 1 — " "$1" \
      && grep -qxF "lessons — wrong_lens (2 missed):" "$1" && grep -qF "review-replay: cost — claude \$1.00, codex 2468 tokens" "$1" && ! grep -q "^review-replay: incomplete" "$1"' _ "$run/summary.txt"
  assert "r1: … and the aggregate, which the run used to delete" \
    jq -e --arg k "$(git -C "$RHUB" rev-parse main)" '.schema == "review-replay-run/v2" and .kit.sha == $k and .kit.check == "unchecked: tracks no remote branch"
      and .prs == {replayed: 2, incomplete: 0, skipped: 5, failed: 1, unreviewed_passed_over: 0} and .counts.compare_failed == 0
      and .denials == {commands: 0, prs_with_denials: 0, prs_of_unknown_denials: 0}
      and (.records | length) == 2 and .counts.missed == 2 and .missed_by_cause.wrong_lens == 2
      and .cost == {claude_usd: 1, claude_calls_of_unknown_cost: 0, codex_tokens: 2468, prs_of_unknown_codex_tokens: 0}
      and (.summary | any(startswith("review-replay: aggregate — replayed 2 ")))' "$run/aggregate.json"
  assert "r1: each lens's raw output is kept beside the record" \
    jq -e '.findings == [.findings[0]] and .findings[0].title == "replayed finding" and .findings[0].lens == "correctness"' "$rec/raw/out-correctness.json"
  assert "r1: … with its log" grep -qxF 'tokens used' "$rec/raw/log-correctness.txt"
  assert "r1: the record counts the codex tokens" jq -e '.replay.cost == {claude_usd: 0.5, codex_tokens: 1234}' "$rec/record.json"
  assert "r1: the record is written, marked as a replay" grep -qxF '<!-- review-replay:v1 -->' "$rec/postmortem.md"
  assert "r1: … with the kit ref and the source of each repo-owned file" \
    jq -e --arg k "$(git -C "$RHUB" rev-parse main)" '.replay.kit_sha == $k and .replay.repo_owned[".review/rubric.md"] == "pr"
      and (.replay.repo_owned[".review/learnings.md"] | startswith("default@")) and .replay.repo_owned[".review/prompts.local"] == "absent"' "$rec/record.json"
  assert "r1: … and the JSON inside the record carries the same facts" \
    sh -c 'awk "/^\`\`\`json/{on=1;next} on&&/^\`\`\`/{exit} on" "$1" | jq -e ".replay.kit_sha and .counts.missed == 1"' _ "$rec/postmortem.md"
  assert "r1: the verdict names the replayed commit" grep -qE "^# Review verdict — feat-1 — $short — " "$rec/verdict.md"
  assert "r1: … and the fence around it is gone" sh -c '! grep -q "^\`\`\`" "$1"' _ "$rec/verdict.md"
  assert "r1: the adjudicator never saw CodeRabbit's findings" test ! -e "$RCL/adjudicate.saw-github-data"
  assert "r1: … and the postmortem read them from the worktree" test -e "$RCL/postmortem.saw-github-data"
  assert "r1: no replay worktree is left behind" no_replay_worktrees "$RS"
  assert "r1: … nor the .claude/ directory a worktree used to need" test ! -e "$RS/.claude"
  assert_not "r1: nothing is commented, filed or written on GitHub" \
    grep -qE '^(pr comment|pr review|issue create|issue comment|label create)|(^| )(-X|--method|-f|-F|--field|--raw-field|--input)( |$)' "$RGH/calls.log"
  assert "r1: claude never gets gh, Edit or Write" \
    sh -c '[ "$(grep -c . "$1")" -eq 4 ] && ! grep -vF -- "--disallowedTools Bash(gh:*)" "$1" | grep -q . && ! grep -vF -- "--tools Read,Grep,Glob,Bash" "$1" | grep -q .' _ "$RCL/calls.log"
  assert "r1: … nor any settings file, whose allow rules would apply" \
    sh -c '[ "$(grep -c . "$1")" -eq 4 ] && ! grep -vF -- "[--setting-sources][][--output-format]" "$1" | grep -q .' _ "$RCL/argv.log"
  assert "r1: … nor a git option that writes a file or runs a command" \
    sh -c '! grep -vF -- "[Bash(git * --output*)][Bash(git * --ext-diff*)][Bash(git * --textconv*)]" "$1" | grep -q . && ! grep -qF "[Bash(git grep" "$1"' _ "$RCL/argv.log"
  assert "r1: the spoke's refs are untouched" test "$(git -C "$RS" for-each-ref)" = "$refs_before"
  assert "r1: … and no FETCH_HEAD is written" test ! -e "$common/FETCH_HEAD"
  assert "r1: … and its checkout is clean" test -z "$(git -C "$RS" status --porcelain)"
  assert_not "r1: the replay verdict stays out of the review history" sh -c 'ls "$1"/review-history/code-* 2>/dev/null | grep -q .' _ "$common"

  printf '1\n' > "$RCX/correctness.rc"; rm "$RCX/correctness.json"
  run_replay 1
  assert "r1: a failed re-run keeps the scored record" grep -qxF '<!-- review-replay:v1 -->' "$rec/postmortem.md"
  assert "r1: … and keeps its own logs beside it" \
    sh -c 'test -s "$1.last-unscored/review.log" && grep -qF "(logs: $1.last-unscored)" "$2"' _ "$rec" "$LOG"
  assert "r1: a second run keeps a record of its own" test "$(ls "$runs" | wc -l)" -eq 2
}

test_replay_failure_is_reported_and_cleaned_up() {
  local rc common kit
  replay_fixture r2
  printf '1\n' > "$RCX/correctness.rc"; rm "$RCX/correctness.json"
  run_replay 3; rc=$?
  common="$(cd "$RS" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"; kit="$(git -C "$RHUB" rev-parse --short main)"
  assert "r2: a failed review fails the run" test "$rc" -eq 1
  assert "r2: … reported as failed at its step" grep -qE '^review-replay: failed — PR #3: review: review.sh exited 1: .*every lens failed' "$LOG"
  assert_not "r2: … never as a skip or a scorecard" grep -qE 'PR #3.*(skipped|missed 0)' "$LOG"
  assert "r2: … with its logs kept" test -s "$common/review-replay/pr3-$kit/review.log"
  assert "r2: the worktree is removed on failure" no_replay_worktrees "$RS"
  assert "r2: claude is never called" test ! -e "$RCL/calls.log"
  assert "r2: the aggregate counts the failure, with nothing scored" \
    grep -qF 'review-replay: aggregate — replayed 0 / incomplete 0 / skipped 0 / failed 1 — caught 0 / missed 0' "$LOG"

  finding 'salvaged' > "$RCX/correctness.json"; printf '3\n' > "$RCX/correctness.rc"
  run_replay 3
  assert "r2: a review that exits 0 but is incomplete is a failure" \
    grep -qE '^review-replay: failed — PR #3: review: incomplete run: .*"lenses_failed":\["correctness"\]' "$LOG"
  assert "r2: … and its worktree is removed" no_replay_worktrees "$RS"

  rm "$RCX/correctness.rc"
  cp "$RCL/postmortem.txt" "$RCL/postmortem.good"
  sed 's/"counts": {"caught": 1, /"counts": {"caught": 2, /' "$RCL/postmortem.good" > "$RCL/postmortem.txt"
  run_replay 3
  assert "r2: a record whose counts do not tally its findings is a failure" \
    grep -qE "^review-replay: failed — PR #3: postmortem: the record's counts or missed_by_cause do not tally its findings" "$LOG"
  cp "$RCL/postmortem.good" "$RCL/postmortem.txt"
  sed 's/"counts": {"caught": 1, /"counts": {/' "$RCL/postmortem.txt" > "$RCL/postmortem.bad" && mv "$RCL/postmortem.bad" "$RCL/postmortem.txt"
  run_replay 3
  assert "r2: a scored record without its counts is a failure" \
    grep -qE "^review-replay: failed — PR #3: postmortem: the record's JSON is missing, unparseable, or not a scored record of PR #3" "$LOG"
  assert "r2: … that still reports what it cost" grep -qF '· cost so far claude $0.50, codex 1234 tokens' "$LOG"
  assert "r2: … and no record replaces the logs" test ! -e "$common/review-replay/pr3-$kit/postmortem.md"
  assert "r2: … and its worktree is removed" no_replay_worktrees "$RS"
}

test_replay_interrupt_removes_the_worktree() {
  local pid i rc tmp="$WORK/r3-tmp"
  replay_fixture r3
  LOG="$RS.replay.log"; mkdir -p "$tmp"
  TMPDIR="$tmp" PATH="$WORK/bin-replay:$WORK/bin:$PATH" GH_STUB_DIR="$RGH" CLAUDE_STUB_DIR="$RCL" CODEX_STUB_DIR="$RCX" \
    CLAUDE_STUB_SLEEP=60 REVIEW_SKIP_AUTH_CHECK=1 bash "$RHUB/scripts/review-replay.sh" "$RS" --repo o/r --no-analyzers 1 \
    > "$LOG" 2>&1 &
  pid=$!
  for i in $(seq 1 60); do [ -e "$RCL/started" ] && break; sleep 1; done
  assert "r3: the replay reached adjudication" test -e "$RCL/started"
  assert "r3: … in its checkout, outside the spoke" \
    sh -c 'd="$(cat "$1")" && test "$(git -C "$d" rev-parse HEAD)" = "$2" && case "$d" in "$3"/*) exit 1 ;; esac' _ "$RCL/cwd" "$RA" "$(cd "$RS" && pwd -P)"
  kill -TERM "$pid"; wait "$pid"; rc=$?
  assert "r3: an interrupted replay exits 143" test "$rc" -eq 143
  assert "r3: … and removes its worktree" no_replay_worktrees "$RS"
  assert "r3: … and its checkout and temp files" sh -c '! test -e "$(cat "$1")" && test -z "$(ls -A "$2")"' _ "$RCL/cwd" "$tmp"
  assert "r3: … and says the PR was interrupted" grep -qxF 'review-replay: failed — PR #1: interrupted: rc=143, nothing was recorded for it' "$LOG"
  assert "r3: … and stops what it started" sh -c 'test -s "$1" && ! kill -0 "$(cat "$1")" 2>/dev/null' _ "$RCL/started"
  assert "r3: the run's record says it was interrupted, with no scorecard" \
    sh -c 'cd "$1"/.git/review-replay/runs/*/ && grep -qxF "review-replay: failed — PR #1: interrupted: rc=143, nothing was recorded for it" summary.txt \
      && grep -qxF "review-replay: incomplete — the run exited 143 before it finished, so it has no scorecard" summary.txt && test ! -e aggregate.json' _ "$RS"
}

test_replay_recent_and_limit() {
  local rc
  replay_fixture r4
  run_replay --limit 00 1; rc=$?
  assert "r4: --limit 00 is not a positive number" test "$rc" -eq 64
  run_replay --limit 18446744073709551617 1; rc=$?
  assert "r4: … nor is one too large for shell arithmetic, which would wrap it to 1" test "$rc" -eq 64
  run_replay --recent 03 --limit 01
  assert "r4: --recent passes over a PR CodeRabbit never reviewed" grep -qF '(1 merged PR(s) CodeRabbit never reviewed passed over)' "$LOG"
  assert "r4: … replays the most recent reviewed one" grep -qE '^review-replay: replayed — PR #1 ' "$LOG"
  assert "r4: … and skips the rest past --limit" grep -qxF 'review-replay: skipped — PR #3: --limit 1 reached' "$LOG"
  assert "r4: a short scan is noted in the run's record" \
    sh -c 'grep -qxF "review-replay: note — found 2 CodeRabbit-reviewed PR(s) among the 100 most recent merged PRs, not 3" "$1"/.git/review-replay/runs/*/summary.txt \
      && jq -e ".recent == {asked: 3, found: 2, scanned: 100}" "$1"/.git/review-replay/runs/*/aggregate.json' _ "$RS"
  gh_json "$RGH" pr-list '{"message":"Bad credentials"}'
  run_replay --recent 2
  assert "r4: a PR list that is not a list is an error, not an empty run" \
    sh -c 'grep -qF "gh pr list returned no PR list" "$1" && ! grep -q aggregate "$1"' _ "$LOG"
  gh_json "$RGH" pr-list '["not a PR"]'
  run_replay --recent 2; rc=$?
  assert "r4: a PR list that cannot be read is an error, not an empty run" \
    sh -c '[ "$2" -ne 0 ] && grep -qF "cannot read the merged PR list" "$1" && ! grep -q "aggregate —" "$1"' _ "$LOG" "$rc"
  assert "r4: … and the run's record says so, with no scorecard" \
    sh -c 'f="$(grep -lF "review-replay: failed — run: cannot read the merged PR list" "$1"/.git/review-replay/runs/*/summary.txt)" \
      && [ "$(printf "%s\n" "$f" | wc -l)" -eq 1 ] && grep -qF "review-replay: incomplete — " "$f" && test ! -e "${f%/summary.txt}/aggregate.json"' _ "$RS"
}

# Each of these once read as a PR with nothing to score, or a cost of nothing.
test_replay_silent_failures_are_failures() {
  local rc common kit rec dead=dddddddddddddddddddddddddddddddddddddddd
  replay_fixture r6
  common="$RS/.git"; kit="$(git -C "$RHUB" rev-parse --short main)"; rec="$common/review-replay/pr1-$kit"
  cp "$RGH/api-repos_o_r_pulls_1_comments.json" "$RGH/comments.good"
  gh_json "$RGH" api-repos_o_r_pulls_1_comments '["not a comment"]'
  run_replay 1; rc=$?
  assert "r6: comments whose commits cannot be listed fail the PR" \
    sh -c '[ "$2" -eq 1 ] && grep -qE "^review-replay: failed — PR #1: github: cannot list the commits CodeRabbit commented on: .*jq" "$1"' _ "$LOG" "$rc"
  jq --arg d "$dead" '. + [.[0] + {id: 8, original_commit_id: $d}]' "$RGH/comments.good" > "$RGH/api-repos_o_r_pulls_1_comments.json"
  run_replay 1; rc=$?
  assert "r6: a commented commit that cannot be fetched fails the PR, not leaves its findings unscored" \
    sh -c '[ "$2" -eq 1 ] && grep -qE "^review-replay: failed — PR #1: fetch: cannot fetch ddddddd, which CodeRabbit commented on" "$1"' _ "$LOG" "$rc"
  assert "r6: … and is never scored" sh -c '! grep -q "aggregate — replayed 1" "$1" && test ! -e "$2/record.json"' _ "$LOG" "$rec"
  cp "$RGH/comments.good" "$RGH/api-repos_o_r_pulls_1_comments.json"
  gh_json "$RGH" api-repos_o_r_issues_1_comments '{"message": "Not Found"}'
  run_replay 1; rc=$?
  assert "r6: a GitHub page that is not a list fails the PR" \
    sh -c '[ "$2" -eq 1 ] && grep -qE "^review-replay: failed — PR #1: github: gh api repos/o/r/issues/1/comments: unparseable response: .*not a list" "$1"' _ "$LOG" "$rc"
  : > "$RGH/api-repos_o_r_issues_1_comments.json"
  run_replay 1; rc=$?
  assert "r6: a GitHub reply with nothing in it fails the PR, not reads as an empty list" \
    sh -c '[ "$2" -eq 1 ] && grep -qE "^review-replay: failed — PR #1: github: gh api repos/o/r/issues/1/comments: unparseable response: .*no reply" "$1"' _ "$LOG" "$rc"
  gh_json "$RGH" api-repos_o_r_issues_1_comments '[]'
  rm "$RCX/correctness.tokens"; : > "$RCL/no-cost"
  run_replay 1; rc=$?
  assert "r6: a cost that cannot be read is unknown, not 0" \
    sh -c '[ "$2" -eq 0 ] && grep -qE "^review-replay: replayed — PR #1 .* · cost claude \\\$0.00 \+ unknown for 2 call\(s\), codex tokens unknown · " "$1" \
      && grep -qxF "review-replay: cost — claude \$0.00 + unknown for 2 call(s), codex 0 tokens + unknown for 1 PR(s), failed and skipped PRs included" "$1"' _ "$LOG" "$rc"
  assert "r6: … in the record too" jq -e '.replay.cost == {claude_usd: null, codex_tokens: null}' "$rec/record.json"
  assert "r6: … and in the run's aggregate" \
    sh -c 'f="$(grep -lF "unknown for 2 call(s)" "$1"/review-replay/runs/*/summary.txt)" && jq -e ".cost == {claude_usd: 0, claude_calls_of_unknown_cost: 2, codex_tokens: 0, prs_of_unknown_codex_tokens: 1}" "${f%/summary.txt}/aggregate.json"' _ "$common"
  # another run replaces PR 1's record while this one replays PR 3
  printf '#!/bin/sh\njq ".counts.caught = 99" "%s/record.json" > "%s/r.tmp" && mv "%s/r.tmp" "%s/record.json"\n' "$rec" "$rec" "$rec" "$rec" > "$RCL/on-postmortem-3"
  chmod +x "$RCL/on-postmortem-3"
  run_replay 1 3; rc=$?
  assert "r6: the run's scorecard counts the records it scored, not what replaced them since" \
    sh -c '[ "$2" -eq 0 ] && jq -e ".counts.caught == 99" "$3/record.json" && grep -qF "aggregate — replayed 2 / incomplete 0 / skipped 0 / failed 0 — caught 2 / " "$1"' _ "$LOG" "$rc" "$rec"
}

# A hub clone behind its remote must not replay its old kit as today's.
# The pilot's lenses ran git log --all and git diff HEAD origin/main, and one saw the PR's
# merged fix. A lens and the adjudicator reach the reviewed commit's history and nothing past it.
test_replay_lenses_cannot_reach_later_history() {
  local b m probe expect
  replay_fixture r11
  b="$(jq -r .headRefOid "$RGH/pr-view-1.json")"; m="$(git -C "$RS" rev-parse origin/main)"
  probe() { # probe <out> — a stub hook that records what history its directory reaches
    printf '#!/bin/sh\n{ git rev-parse HEAD; git for-each-ref; git remote; echo --; git log --all --format=%%H; echo --
  for c in %s %s %s; do git cat-file -e "$c^{commit}" 2>/dev/null && echo "reach $c"; done; } > "%s" 2>&1\n' "$b" "$(git -C "$RS" rev-parse "$m^1")" "$m" "$1"
  }
  probe "$WORK/r11.lens" > "$RCX/on-correctness"; probe "$WORK/r11.adjudicate" > "$RCL/on-adjudicate-1"
  probe "$WORK/r11.postmortem" > "$RCL/on-postmortem-1"; chmod +x "$RCX/on-correctness" "$RCL/on-adjudicate-1" "$RCL/on-postmortem-1"
  run_replay 1
  expect="$(git -C "$RS" rev-parse "$RA"; echo --; git -C "$RS" rev-list "$RA"; echo --)"
  assert "r11: the PR is replayed" grep -qE '^review-replay: replayed — PR #1 ' "$LOG"
  assert "r11: a lens sees the reviewed commit's history and no ref, no later head and no later main" \
    test "$(cat "$WORK/r11.lens")" = "$expect"
  assert "r11: … and so does the adjudicator" test "$(cat "$WORK/r11.adjudicate")" = "$expect"
  assert "r11: the postmortem can compare later heads, still without the spoke's refs" \
    test "$(cat "$WORK/r11.postmortem")" = "$expect
reach $b
reach $(git -C "$RS" rev-parse "$m^1")
reach $m"
  assert "r11: the spoke's refs are untouched" test "$(git -C "$RS" rev-parse origin/main)" = "$m"

  # the clone has no LFS config or storage, so a reviewed commit that sets a filter is skipped
  git -C "$RS" worktree add -q --detach "$WORK/r11-lfs" "$RA"
  ( cd "$WORK/r11-lfs" && printf '# keep this out of filter=lfs\n*.txt text\n' > .gitattributes \
      && git add .gitattributes && git -c user.email=t@example.invalid -c user.name=t commit -qm attrs \
      && git push -q "$RREMOTE" HEAD:refs/pull/11/head \
      && mkdir -p sub && printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > sub/.gitattributes \
      && git add sub && git -c user.email=t@example.invalid -c user.name=t commit -qm lfs \
      && git push -q "$RREMOTE" HEAD:refs/pull/10/head )
  gh_pr_fixture "$RGH" 11 "$(git -C "$WORK/r11-lfs" rev-parse HEAD~1)" "$(git -C "$WORK/r11-lfs" rev-parse HEAD~1)" "$m"
  gh_pr_fixture "$RGH" 10 "$(git -C "$WORK/r11-lfs" rev-parse HEAD)" "$(git -C "$WORK/r11-lfs" rev-parse HEAD)" "$m"
  git -C "$RS" worktree remove --force "$WORK/r11-lfs"
  run_replay 10 11
  assert "r11: a reviewed commit that sets a git filter is skipped, not reviewed as pointers" \
    grep -qE "^review-replay: skipped — PR #10: sub/.gitattributes at [0-9a-f]{7} sets a git filter" "$LOG"
  assert "r11: … but a filter named only in a comment is no filter" grep -qE "^review-replay: replayed — PR #11 " "$LOG"
  git -C "$RS" config remote.origin.promisor true; git -C "$RS" config remote.origin.partialclonefilter blob:none
  run_replay 1
  assert "r11: a partial clone is refused, since the checkout fetches from it" \
    sh -c 'grep -qF "is a partial clone, so it lacks objects a replay reads" "$1" && ! grep -q "^review-replay: replayed" "$1"' _ "$LOG"
  git -C "$RS" config --unset remote.origin.promisor; git -C "$RS" config --unset remote.origin.partialclonefilter
  git -C "$RS" config remote.origin.promisor false
  run_replay 1
  assert "r11: … but a remote marked promisor=false is no partial clone" grep -qE '^review-replay: replayed — PR #1 ' "$LOG"
  git -C "$RS" config --unset remote.origin.promisor

  REPLAY_OBJECT_FORMAT=sha256 replay_fixture r15
  run_replay 1
  assert "r15: a SHA-256 spoke is replayed in a checkout of its own format" \
    sh -c 'grep -qE "^review-replay: replayed — PR #1 " "$1" && [ "$(git -C "$2" rev-parse --show-object-format)" = sha256 ]' _ "$LOG" "$RS"
}

# The claude calls kept only their last message, so nobody could check what the adjudicator
# read; a denied command and a compare that failed read the same as a clean run.
test_replay_keeps_transcripts_and_denials() {
  local rc common kit rec run
  replay_fixture r12
  common="$RS/.git"; kit="$(git -C "$RHUB" rev-parse --short main)"; rec="$common/review-replay/pr1-$kit"
  printf '[{"tool_name":"Bash","tool_use_id":"t9","tool_input":{"command":"cd src && git diff"}}]' > "$RCL/postmortem.denials"
  run_replay 1; rc=$?
  assert "r12: a PR with a denied command is still replayed" test "$rc" -eq 0
  assert "r12: … and its line says what was denied" \
    grep -qE '^review-replay: replayed — PR #1 .* / unscored 0 \(compare_failed 0\) · commands denied: postmortem 1 · cost ' "$LOG"
  assert "r12: each claude call keeps its whole transcript, tool calls and results included" \
    sh -c 'for k in adjudicate postmortem; do f="$1/transcript-$k.jsonl"
      jq -e "select(.type == \"user\") | .message.content[0].content == \"stub $k history\"" "$f" > /dev/null \
        && tail -n1 "$f" | jq -e ".type == \"result\"" > /dev/null || exit 1; done' _ "$rec"
  assert "r12: the record copies every call's denials" \
    jq -e '.replay.permission_denials == {adjudicate: [], postmortem: [{tool_name: "Bash", tool_use_id: "t9", tool_input: {command: "cd src && git diff"}}]}' "$rec/record.json"
  run="$(last_run)"
  assert "r12: the run counts the denials" \
    sh -c 'grep -qxF "review-replay: denials — 1 command(s) denied in 1 PR(s), failed PRs included" "$1/summary.txt" \
      && jq -e ".denials == {commands: 1, prs_with_denials: 1, prs_of_unknown_denials: 0}" "$1/aggregate.json"' _ "$run"

  printf 'absent' > "$RCL/adjudicate.denials"
  run_replay 1
  assert "r12: a call that gives no denial list is unknown, not none" \
    sh -c 'grep -qE "^review-replay: replayed — PR #1 .* · commands denied: adjudicate unknown, postmortem 1 · cost " "$1" \
      && grep -qxF "review-replay: denials — 1 command(s) denied in 1 PR(s) + unknown for 1 PR(s), failed PRs included" "$1" \
      && jq -e ".replay.permission_denials.adjudicate == null" "$2/record.json"' _ "$LOG" "$rec"
  rm "$RCL/adjudicate.denials" "$RCL/postmortem.denials"

  : > "$RCL/postmortem.no-result"
  run_replay 1; rc=$?
  assert "r12: a transcript with no result fails the PR, its denials unknown" \
    sh -c '[ "$2" -eq 1 ] && grep -qE "^review-replay: failed — PR #1: postmortem: claude exited 0, with no result in its transcript(: .*)? · commands denied: postmortem unknown" "$1"' _ "$LOG" "$rc"
  assert "r12: … and keeps that transcript with its logs" \
    sh -c 'grep -qF "stub postmortem history" "$1.last-unscored/transcript-postmortem.jsonl"' _ "$rec"
  rm "$RCL/postmortem.no-result"

  # #65: a compare that failed and a miss no lens evidence could diagnose
  cat > "$RCL/postmortem.txt" <<'EOP'
review-postmortem: scored — PR #@PR@: caught 1 / missed 1 (wrong lens 0 / tracing 0 / threshold 0 / structural 0 / unverified 1) / rejected-wrongly 0 / noise 0 / unscored 1 (compare_failed 1)
review-postmortem: record — replay: comment not posted; local copy written by the caller

<!-- review-postmortem:v1 -->
## Review postmortem — PR #@PR@

```json
{"schema": "review-postmortem/v1", "pr": @PR@, "status": "scored", "compared_commit": "@SHA@",
 "counts": {"caught": 1, "missed": 1, "rejected_wrongly": 0, "noise": 0, "unscored": 1},
 "missed_by_cause": {"wrong_lens": 0, "tracing": 0, "threshold": 0, "structural": 0},
 "findings": [{"file": "src.txt", "summary": "replayed finding", "class": "caught", "cause": null},
              {"file": "src.txt", "summary": "off by one", "class": "missed", "cause": "unverified", "cause_evidence": "raw/log-correctness.txt missing"},
              {"file": "src.txt", "summary": "later head", "class": "unscored", "cause": null, "unscored_reason": "compare_failed: denied: git diff a b"}],
 "proposals": [], "lessons": []}
```
EOP
  run_replay 1; rc=$?
  run="$(last_run)"
  assert "r12: a finding the postmortem could not compare makes the PR incomplete, not replayed" \
    sh -c '[ "$2" -eq 1 ] && grep -qE "^review-replay: incomplete — PR #1 \([0-9a-f]{7}, kit [0-9a-f]+\): caught 1 / missed 1 \(wrong lens 0 / tracing 0 / threshold 0 / structural 0 / unverified 1\) / rejected-wrongly 0 / noise 0 / unscored 1 \(compare_failed 1\) · 1 finding\(s\) unscored because a compare failed \(compare_failed: denied: git diff a b\) · cost " "$1" \
      && ! grep -q "review-replay: replayed — PR #1" "$1"' _ "$LOG" "$rc"
  assert "r12: … counted as incomplete in the run's scorecard" \
    sh -c 'grep -qxF "review-replay: aggregate — replayed 0 / incomplete 1 / skipped 0 / failed 0 — caught 1 / missed 1 (wrong lens 0 / tracing 0 / threshold 0 / structural 0 / unverified 1) / rejected-wrongly 0 / noise 0 / unscored 1 (compare_failed 1)" "$1/summary.txt" \
      && jq -e ".prs.incomplete == 1 and .prs.replayed == 0 and .counts.compare_failed == 1 and .missed_by_cause.unverified == 1 and .missed_by_cause.unattributed == 0 and (.records | length) == 1" "$1/aggregate.json"' _ "$run"
  assert "r12: … with its record kept" \
    sh -c 'grep -q "^review-replay: incomplete — PR #1" "$1/outcome.txt" && grep -qxF "<!-- review-replay:v1 -->" "$1/postmortem.md"' _ "$rec"
  sed -e 's/"cause": "unverified"/"cause": "guessed"/' "$RCL/postmortem.txt" > "$RCL/postmortem.nc" && mv "$RCL/postmortem.nc" "$RCL/postmortem.txt"
  run_replay 1
  assert "r12: a miss of no known cause shows as a gap in the causes" \
    grep -qE "^review-replay: incomplete — PR #1 .*: caught 1 / missed 1 \(wrong lens 0 / tracing 0 / threshold 0 / structural 0 / unverified 0 / no cause 1\) / " "$LOG"
}

# One invocation takes one spoke, so the pilot's totals were summed by hand.
test_replay_sum_across_spokes() {
  local rc a b out
  replay_fixture r13; run_replay 1; a="$(last_run)"
  local hub="$RHUB"
  replay_fixture r14; RHUB="$hub"; run_replay 6; b="$(last_run)"
  # two spokes can share a run's name: one kit, the same second
  mkdir -p "$WORK/r13-runs/twin"; jq --arg r "$(jq -r .run "$a/aggregate.json")" '.run = $r' "$b/aggregate.json" > "$WORK/r13-runs/twin/aggregate.json"
  bash "$hub/scripts/review-replay-sum.sh" "$a" "$WORK/r13-runs/twin" > "$WORK/r13.twin" 2>&1
  assert "r13: two spokes' runs of the same name are two runs" grep -qF "review-replay-sum: aggregate — replayed 2 " "$WORK/r13.twin"
  out="$WORK/r13.sum"
  bash "$hub/scripts/review-replay-sum.sh" "$a" "$b/aggregate.json" > "$out" 2>&1; rc=$?
  assert "r13: two runs sum to one scorecard" \
    sh -c '[ "$2" -eq 0 ] && grep -qxF "review-replay-sum: aggregate — replayed 2 / incomplete 0 / skipped 0 / failed 0 — caught 2 / missed 2 (wrong lens 2 / tracing 0 / threshold 0 / structural 0 / unverified 0) / rejected-wrongly 0 / noise 0 / unscored 0 (compare_failed 0)" "$1"' _ "$out" "$rc"
  assert "r13: … naming each run, and each lesson by repo and PR" \
    sh -c 'grep -qE "^review-replay-sum: runs — 2 run\(s\) of kit .* across 1 repo\(s\)$" "$1" && [ "$(grep -c "^  o/r .*: replayed 1 / " "$1")" -eq 2 ] \
      && grep -qxF "lessons — wrong_lens (2 missed):" "$1" && grep -qF "  o/r#1 missed: src.txt" "$1" && grep -qF "  o/r#6 missed: src.txt" "$1"' _ "$out"
  assert "r13: … with the cost and the denials of both" \
    sh -c 'grep -qxF "review-replay-sum: cost — claude \$1.00, codex 2468 tokens, failed and skipped PRs included" "$1" \
      && grep -qxF "review-replay-sum: denials — 0 command(s) denied in 0 PR(s), failed PRs included" "$1"' _ "$out"
  assert "r13: --json gives the same scorecard with every record" \
    sh -c 'bash "$1/scripts/review-replay-sum.sh" --json "$2" "$3" | jq -e ".schema == \"review-replay-sum/v1\" and .prs.replayed == 2 and .counts.caught == 2
      and (.records | map(\"\(.repo)#\(.pr)\") | sort) == [\"o/r#1\", \"o/r#6\"] and (.runs | length) == 2"' _ "$hub" "$a" "$b"
  bash "$hub/scripts/review-replay-sum.sh" > "$out" 2>&1; rc=$?
  assert "r13: no run is a usage error, not an empty scorecard" test "$rc" -eq 64
  bash "$hub/scripts/review-replay-sum.sh" "$a" "$a/aggregate.json" > "$out" 2>&1; rc=$?
  assert "r13: the same run twice is refused" sh -c '[ "$2" -eq 1 ] && grep -qF "the same run twice" "$1" && ! grep -q "aggregate —" "$1"' _ "$out" "$rc"
  mkdir -p "$WORK/r13-runs/upper"; jq '.repo = "O/R" | .records = []' "$a/aggregate.json" > "$WORK/r13-runs/upper/aggregate.json"
  jq '.records = []' "$a/aggregate.json" > "$WORK/r13-runs/lower.json"
  bash "$hub/scripts/review-replay-sum.sh" "$WORK/r13-runs/lower.json" "$WORK/r13-runs/upper" > "$out" 2>&1; rc=$?
  assert "r13: … also when its copy names the repo in another case" sh -c '[ "$2" -eq 1 ] && grep -qF "the same run twice" "$1"' _ "$out" "$rc"
  mkdir -p "$WORK/r13-runs/stopped" "$WORK/r13-runs/v1" "$WORK/r13-runs/kit"
  printf 'review-replay: incomplete — the run exited 130 before it finished, so it has no scorecard\n' > "$WORK/r13-runs/stopped/summary.txt"
  bash "$hub/scripts/review-replay-sum.sh" "$a" "$WORK/r13-runs/stopped" > "$out" 2>&1; rc=$?
  assert "r13: a run that stopped before its scorecard is refused, not read as nothing" \
    sh -c '[ "$2" -eq 1 ] && grep -qF "has no aggregate.json: the run stopped before its scorecard" "$1"' _ "$out" "$rc"
  jq '.schema = "review-replay-run/v1"' "$b/aggregate.json" > "$WORK/r13-runs/v1/aggregate.json"
  bash "$hub/scripts/review-replay-sum.sh" "$a" "$WORK/r13-runs/v1" > "$out" 2>&1; rc=$?
  assert "r13: an older run's aggregate is refused, since it has no incomplete or denial counts" \
    sh -c '[ "$2" -eq 1 ] && grep -qF "is review-replay-run/v1, not review-replay-run/v2" "$1"' _ "$out" "$rc"
  mkdir -p "$WORK/r13-runs/nospoke"; jq 'del(.spoke)' "$b/aggregate.json" > "$WORK/r13-runs/nospoke/aggregate.json"
  bash "$hub/scripts/review-replay-sum.sh" "$a" "$WORK/r13-runs/nospoke" > "$out" 2>&1; rc=$?
  assert "r13: a run that names no spoke is refused, not merged with another" \
    sh -c '[ "$2" -eq 1 ] && grep -qF "names no spoke or run" "$1"' _ "$out" "$rc"
  jq '.kit.sha = "0000000000000000000000000000000000000000"' "$b/aggregate.json" > "$WORK/r13-runs/kit/aggregate.json"
  bash "$hub/scripts/review-replay-sum.sh" "$a" "$WORK/r13-runs/kit" > "$out" 2>&1; rc=$?
  assert "r13: runs of different kits are refused" sh -c '[ "$2" -eq 1 ] && grep -qF "runs of different kits" "$1"' _ "$out" "$rc"
  run_replay 6
  bash "$hub/scripts/review-replay-sum.sh" "$b" "$(last_run)" > "$out" 2>&1; rc=$?
  assert "r13: a PR scored in two runs is refused, not counted twice" \
    sh -c '[ "$2" -eq 1 ] && grep -qF "o/r#6 is scored in more than one run" "$1"' _ "$out" "$rc"

  # another repo's PR #1, with a failure, skips, an incomplete PR, unknown costs and denials
  mkdir -p "$WORK/r13-runs/other" "$WORK/r13-runs/case"
  jq '.repo = "x/y" | .run = "other-run" | .records[0].pr = 1
      | .prs = {replayed: 0, incomplete: 1, skipped: 2, failed: 1, unreviewed_passed_over: 3}
      | .cost = {claude_usd: 0.25, claude_calls_of_unknown_cost: 1, codex_tokens: 10, prs_of_unknown_codex_tokens: 1}
      | .denials = {commands: 3, prs_with_denials: 1, prs_of_unknown_denials: 1}' "$b/aggregate.json" > "$WORK/r13-runs/other/aggregate.json"
  bash "$hub/scripts/review-replay-sum.sh" "$a" "$WORK/r13-runs/other" > "$out" 2>&1; rc=$?
  assert "r13: two repos' PR #1 both count" \
    sh -c '[ "$2" -eq 0 ] && grep -qE "across 2 repo\(s\)$" "$1" && grep -qF "  o/r#1 missed: " "$1" && grep -qF "  x/y#1 missed: " "$1"' _ "$out" "$rc"
  assert "r13: … and every counter, not only the scored ones, is summed" \
    sh -c 'grep -qF "review-replay-sum: aggregate — replayed 1 / incomplete 1 / skipped 2 / failed 1 (3 merged PR(s) CodeRabbit never reviewed passed over) — " "$1" \
      && grep -qxF "review-replay-sum: cost — claude \$0.75 + unknown for 1 call(s), codex 1244 tokens + unknown for 1 PR(s), failed and skipped PRs included" "$1" \
      && grep -qxF "review-replay-sum: denials — 3 command(s) denied in 1 PR(s) + unknown for 1 PR(s), failed PRs included" "$1"' _ "$out"
  jq '.repo = "O/R" | .run = "case-run"' "$b/aggregate.json" | jq '.records[0].pr = 1' > "$WORK/r13-runs/case/aggregate.json"
  bash "$hub/scripts/review-replay-sum.sh" "$a" "$WORK/r13-runs/case" > "$out" 2>&1; rc=$?
  assert "r13: a repo named in another case is the same repo" \
    sh -c '[ "$2" -eq 1 ] && grep -qF "#1 is scored in more than one run" "$1"' _ "$out" "$rc"
}

test_replay_refuses_a_stale_kit() {
  local rc up="$WORK/r7-hub-remote.git" tmp="$WORK/r7-hub-push"
  replay_fixture r7
  git clone -q --bare "$RHUB" "$up"
  git -C "$RHUB" remote add origin "$up" && git -C "$RHUB" fetch -q origin && git -C "$RHUB" branch -q -u origin/main main
  git clone -q "$up" "$tmp"
  ( cd "$tmp" && git config user.email review-test@example.invalid && git config user.name review-test \
      && printf 'newer\n' > newer.txt && git add newer.txt && git commit -qm newer && git push -q origin main )
  run_replay 1; rc=$?
  assert "r7: a main behind origin is refused" \
    sh -c '[ "$2" -ne 0 ] && grep -qE "error:.* --kit-ref main \([0-9a-f]+\) is behind refs/heads/main on origin" "$1"' _ "$LOG" "$rc"
  assert "r7: … before anything is replayed or recorded" \
    sh -c 'test ! -e "$1/calls.log" && test ! -e "$2/.git/review-replay/runs"' _ "$RCL" "$RS"
  run_replay --kit-ref origin/main 1; rc=$?
  assert "r7: … and so is a remote-tracking ref that was never fetched" \
    sh -c '[ "$2" -ne 0 ] && grep -qF -- "--kit-ref origin/main" "$1" && grep -qF "is behind refs/heads/main on origin" "$1"' _ "$LOG" "$rc"
  git -C "$RHUB" update-ref refs/remotes/gone/main main
  run_replay --kit-ref gone/main 1; rc=$?
  assert "r7: a tracking ref whose remote is gone is refused" \
    sh -c '[ "$2" -ne 0 ] && grep -qF "is a tracking ref of no remote the hub still has" "$1"' _ "$LOG" "$rc"
  git -C "$RHUB" remote add team/hub "$up" && git -C "$RHUB" update-ref refs/remotes/team/hub/main main
  run_replay --kit-ref team/hub/main 1; rc=$?
  assert "r7: … but one of a remote whose name has a slash is checked against it" \
    sh -c '[ "$2" -ne 0 ] && grep -qF "is behind refs/heads/main on team/hub" "$1"' _ "$LOG" "$rc"
  git -C "$RHUB" remote set-url origin "$WORK/r7-nowhere.git"
  run_replay 1; rc=$?
  assert "r7: a remote that cannot be read is refused, not taken as current" \
    sh -c '[ "$2" -ne 0 ] && grep -qF "cannot read refs/heads/main from the hub" "$1" && test ! -e "$3/calls.log"' _ "$LOG" "$rc" "$RCL"
  git -C "$RHUB" remote set-url origin "$up" && git -C "$RHUB" pull -q --ff-only
  run_replay 1; rc=$?
  assert "r7: a current main replays" \
    sh -c '[ "$2" -eq 0 ] && grep -qE "^review-replay: replayed — PR #1 " "$1"' _ "$LOG" "$rc"
  assert "r7: … and its record says the kit was checked" \
    sh -c 'jq -e ".kit.check == \"current with refs/heads/main on origin\"" "$1"/.git/review-replay/runs/*/aggregate.json' _ "$RS"
}

test_replay_docs_post_nothing() {
  local pm="$KIT/.claude/commands/review-postmortem.md"
  assert "r5: the postmortem has a replay mode" grep -qF '`--replay <dir>` is only for' "$pm"
  assert "r5: … that calls no gh and saves nothing" sh -c 'grep -qF "**Call no \`gh\`.**" "$1" && grep -qF "**Save nothing.**" "$1"' _ "$pm"
  assert "r5: … and keeps the status contract" grep -qF 'review-postmortem: record — replay: comment not posted; local copy written by the caller' "$pm"
  assert "r5: adjudication has replay deltas" grep -qF '## Replay mode' "$KIT/.review/adjudication.md"
  assert "r5: REVIEW.md says what a replay measures" grep -qF 'scripts/review-replay.sh' "$KIT/REVIEW.md"
  assert "r5: … and so does OPERATING.md" grep -qF 'scripts/review-replay.sh' "$KIT/OPERATING.md"
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

# --- kit staleness ---------------------------------------------------------
kit_repo() { # kit_repo <dir> <stubdir> <hub url> <release line> — make_repo plus the updater, a kit-version, one change
  make_repo "$1"; mkdir -p "$2"
  printf '{"findings":[]}' > "$2/correctness.json"
  ( cd "$1" && cp "$KIT/scripts/review-update.sh" scripts/ \
      && printf 'kit: %s abc1234\nref: %s\n%ssource: %s\nsynced: 2026-01-01\n' \
           "$3" "${4#release: }" "${4:+$4
}" "$3" > .review/kit-version \
      && printf 'change\n' >> src.txt && git add -A && git commit -qm change )
}

kit_hub() { # kit_hub <dir> — a hub listing v0.9.0 (annotated) and v0.10.0
  make_hub "$1"
  ( cd "$1" && git -c tag.gpgSign=false tag -a -m nine v0.9.0 && git tag v0.10.0 )
}

# review.sh compares kit-version's release with the hub's latest: behind warns,
# current does not, and a failed lookup says "unknown" — never "latest".
test_review_warns_when_kit_is_behind() {
  local hub="$WORK/k1-hub" repo="$WORK/k1" stub="$WORK/k1-stub" rc
  kit_hub "$hub"

  kit_repo "$repo" "$stub" "file://$hub" "release: v0.9.0"
  run_review "$repo" "$stub" --lenses correctness; rc=$?
  assert     "k1: behind: review still exits 0" test "$rc" -eq 0
  assert     "k1: behind: warns with both versions" \
    grep -qF 'warn: review kit v0.9.0 is behind the latest release v0.10.0' "$LOG"

  rm -rf "$repo"; kit_repo "$repo" "$stub" "file://$hub" "release: v0.10.0"
  run_review "$repo" "$stub" --lenses correctness; rc=$?
  assert     "k1: current: exits 0" test "$rc" -eq 0
  assert     "k1: current: says so" grep -qF 'review kit v0.10.0 is the latest release' "$LOG"
  assert_not "k1: current: no behind warning" grep -qF 'behind' "$LOG"
  assert_not "k1: current: no unknown" grep -qF 'unknown' "$LOG"

  rm -rf "$repo"; kit_repo "$repo" "$stub" "file://$hub" ""
  sed -i.bak 's/^ref: .*/ref: v0.9.0/' "$repo/.review/kit-version" && rm -f "$repo/.review/kit-version.bak"
  run_review "$repo" "$stub" --lenses correctness
  assert     "k1: a kit-version without release: falls back to a vN.N.N ref" \
    grep -qF 'review kit v0.9.0 is behind the latest release v0.10.0' "$LOG"
}

test_review_kit_staleness_unknown() {
  local hub="$WORK/k2-hub" bare="$WORK/k2-bare" repo="$WORK/k2" stub="$WORK/k2-stub" rc
  kit_hub "$hub"; make_hub "$bare"

  kit_repo "$repo" "$stub" "file://$WORK/k2-nowhere" "release: v0.9.0"
  run_review "$repo" "$stub" --lenses correctness; rc=$?
  assert     "k2: unreachable: review still exits 0" test "$rc" -eq 0
  assert     "k2: unreachable: warns unknown" grep -qF 'staleness unknown: could not reach' "$LOG"
  assert_not "k2: unreachable: never claims latest" grep -qF 'latest release' "$LOG"
  assert     "k2: unreachable: report still complete" jq -e '.complete == true' "$repo/.review/findings.json"
  run_review "$repo" "$stub" --lenses correctness
  assert     "k2: the failed lookup is cached" grep -qF 'could not reach file://'"$WORK"'/k2-nowhere (checked 0h ago)' "$LOG"
  local cache; cache="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)/review-kit-latest"
  awk 'BEGIN{FS=OFS="\t"} {$1 = $1 - 4000; print}' "$cache" > "$cache.new" && mv "$cache.new" "$cache"
  kit_hub "$WORK/k2-nowhere"
  run_review "$repo" "$stub" --lenses correctness
  assert     "k2: a failure is cached for an hour, not a day" grep -qF 'behind the latest release v0.10.0' "$LOG"

  rm -rf "$repo"; kit_repo "$repo" "$stub" "file://$bare" "release: v0.9.0"
  run_review "$repo" "$stub" --lenses correctness
  assert     "k2: no release tag: warns unknown" grep -qF 'staleness unknown: file://'"$bare"' lists no release tag' "$LOG"

  rm -rf "$repo"; kit_repo "$repo" "$stub" "file://$hub" "release: unreleased"
  run_review "$repo" "$stub" --lenses correctness
  assert     "k2: unreleased sync is named, not called current" grep -qF 'unreleased sync' "$LOG"
  assert_not "k2: unreleased: never claims latest" grep -qF 'latest release' "$LOG"

  rm -rf "$repo"; kit_repo "$repo" "$stub" "file://$hub" ""
  run_review "$repo" "$stub" --lenses correctness
  assert     "k2: a kit-version naming no release is unknown" grep -qF 'names no release' "$LOG"

  rm -rf "$repo"; make_repo "$repo"
  run_review "$repo" "$stub" --lenses correctness
  assert     "k2: no kit-version is named" grep -qF 'no .review/kit-version' "$LOG"
  assert_not "k2: no kit-version: never claims latest" grep -qF 'latest release' "$LOG"
}

# An updater from before --latest-release ignores the flag and runs a full sync;
# review.sh must not call it.
test_review_kit_check_skips_an_old_updater() {
  local hub="$WORK/k3-hub" repo="$WORK/k3" stub="$WORK/k3-stub"
  kit_hub "$hub"
  kit_repo "$repo" "$stub" "file://$hub" "release: v0.9.0"
  ( cd "$repo" && printf '#!/usr/bin/env bash\ntouch OLD-UPDATER-RAN\n' > scripts/review-update.sh )
  run_review "$repo" "$stub" --lenses correctness
  assert     "k3: old updater: unknown" grep -qF 'predates --latest-release' "$LOG"
  assert_not "k3: old updater never ran" test -e "$repo/OLD-UPDATER-RAN"
}

# A day-long cache: a release published after a lookup is not seen until it
# expires — so a lookup happens at most once a day, not on every review.
test_review_kit_lookup_is_cached() {
  local hub="$WORK/k4-hub" repo="$WORK/k4" stub="$WORK/k4-stub" cache
  kit_hub "$hub"
  kit_repo "$repo" "$stub" "file://$hub" "release: v0.10.0"
  run_review "$repo" "$stub" --lenses correctness
  assert "k4: first run: current" grep -qF 'v0.10.0 is the latest release' "$LOG"
  ( cd "$hub" && git tag v0.11.0 )
  run_review "$repo" "$stub" --lenses correctness
  assert "k4: within the day: cached answer" grep -qF 'v0.10.0 is the latest release' "$LOG"
  cache="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)/review-kit-latest"
  assert "k4: cache lives under the git common dir" test -f "$cache"
  awk 'BEGIN{FS=OFS="\t"} {$1 = $1 - 90000; print}' "$cache" > "$cache.new" && mv "$cache.new" "$cache"
  run_review "$repo" "$stub" --lenses correctness
  assert "k4: expired cache: looks again" grep -qF 'v0.10.0 is behind the latest release v0.11.0' "$LOG"

  ( cd "$hub" && git tag v0.12.0 )
  sed -i.bak 's/^release: .*/release: v0.12.0/' "$repo/.review/kit-version" && rm -f "$repo/.review/kit-version.bak"
  run_review "$repo" "$stub" --lenses correctness
  assert     "k4: a sync past the cached answer looks again" grep -qF 'v0.12.0 is the latest release' "$LOG"
  assert_not "k4: … and is not called newer" grep -qF 'newer than' "$LOG"

  local other="$WORK/k4-other"; kit_hub "$other"
  sed -i.bak "s|^kit: [^ ]*|kit: file://$other|" "$repo/.review/kit-version" && rm -f "$repo/.review/kit-version.bak"
  run_review "$repo" "$stub" --lenses correctness
  assert     "k4: the cache is keyed by hub URL" grep -qF 'v0.12.0 is newer than file://'"$other""'s latest release v0.10.0" "$LOG"
  ( cd "$other" && git tag v0.11.0 )
  run_review "$repo" "$stub" --lenses correctness
  assert     "k4: newer than the hub: answered from cache, not looked up every run" \
    grep -qF "latest release v0.10.0 (checked 0h ago)" "$LOG"
}

# The cache never makes a lookup fail or speak: an absurd stamp is a miss, an
# unwritable cache dir stays quiet, and no git dir at all just skips caching.
test_review_kit_cache_edge_cases() {
  local hub="$WORK/k6-hub" repo="$WORK/k6" stub="$WORK/k6-stub" cache err="$WORK/k6.err" nogit="$WORK/k6-nogit"
  kit_hub "$hub"
  kit_repo "$repo" "$stub" "file://$hub" "release: v0.9.0"
  cache="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)/review-kit-latest"

  printf '%s\tok\tfile://%s\tv9.9.9\n' 99999999999999999999 "$hub" > "$cache"
  ( cd "$repo" && . scripts/lib/common.sh && kit_staleness && echo "$KIT_NOTE" ) > "$WORK/k6.out" 2>"$err"
  assert "k6: a 20-digit stamp is a miss, not an answer" grep -qF 'behind the latest release v0.10.0' "$WORK/k6.out"
  assert "k6: … and prints no shell error" test ! -s "$err"

  rm -f "$cache"; chmod a-w "$(dirname "$cache")"
  ( cd "$repo" && . scripts/lib/common.sh && kit_staleness && echo "$KIT_NOTE" ) > "$WORK/k6.out" 2>"$err"
  chmod u+w "$(dirname "$cache")"
  assert "k6: an unwritable cache dir still answers" grep -qF 'behind the latest release v0.10.0' "$WORK/k6.out"
  assert "k6: … quietly" test ! -s "$err"

  mkdir -p "$nogit/scripts/lib" "$nogit/.review"
  cp "$repo/scripts/review-update.sh" "$nogit/scripts/"; cp "$repo/scripts/lib/common.sh" "$nogit/scripts/lib/"
  cp "$repo/.review/kit-version" "$nogit/.review/"
  ( cd "$nogit" && GIT_CEILING_DIRECTORIES="$WORK" && export GIT_CEILING_DIRECTORIES \
      && . scripts/lib/common.sh && kit_staleness && echo "$KIT_NOTE" ) > "$WORK/k6.out" 2>"$err"
  assert "k6: no git dir: still answers" grep -qF 'behind the latest release v0.10.0' "$WORK/k6.out"
  assert "k6: no git dir: quietly" test ! -s "$err"
}

# A hub that hangs costs a few seconds, then reads as unknown.
test_review_kit_lookup_times_out() {
  local hub="$WORK/k5-hub" repo="$WORK/k5" stub="$WORK/k5-stub" bin="$WORK/k5-bin" t0 t1 real
  kit_hub "$hub"
  kit_repo "$repo" "$stub" "file://$hub" "release: v0.9.0"
  real="$(command -v git)"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\n[ "$1" = ls-remote ] && exec sleep 20\nexec "%s" "$@"\n' "$real" > "$bin/git"
  chmod +x "$bin/git"
  t0="$(date +%s)"
  LOG="$repo.log"
  ( cd "$repo" && PATH="$bin:$WORK/bin:$PATH" CODEX_STUB_DIR="$stub" REVIEW_SKIP_AUTH_CHECK=1 \
      bash scripts/review.sh --no-analyzers --lenses correctness main ) > "$LOG" 2>&1
  t1="$(date +%s)"
  assert     "k5: hung hub: unknown" grep -qF 'did not answer within' "$LOG"
  assert_not "k5: hung hub: never claims latest" grep -qF 'latest release' "$LOG"
  assert     "k5: hung hub costs under 15s" test $((t1 - t0)) -lt 15
}

# A signal can land between any two steps of the swap, or during the rollback.
# The mv stub signals the script right after the move whose "src>dst" matches
# $M3_TRIP (or $M3_TRIP2), so each window is hit every time, not by timing.
test_make_plugin_interrupted_swap_keeps_previous_build() {
  local hub="$WORK/m3-hub" dest="$WORK/m3-out/plugin" out="$WORK/m3.log" rc=0 trip
  make_hub "$hub"
  mkdir -p "$WORK/m3-out" "$WORK/m3-bin"
  printf '#!/bin/sh\n%s "$@" || exit\ncase "$1>$2" in $M3_TRIP|${M3_TRIP2:-$M3_TRIP}) kill -TERM "$PPID" ;; esac\n' \
    "$(command -v mv)" > "$WORK/m3-bin/mv"
  chmod +x "$WORK/m3-bin/mv"

  for trip in '*/plugin/skills>*/old/' '*/new/skills>*' '*/new/skills>*|*/old/skills>*'; do
    rm -rf "$dest"
    ( cd "$hub" && bash scripts/make-plugin.sh "$dest" ) > "$out" 2>&1
    assert "m3 [$trip]: first build succeeds" test "$?" -eq 0
    printf 'v1\n' > "$dest/skills/pre-pr-review/old-only"
    ( cd "$hub" && PATH="$WORK/m3-bin:$PATH" M3_TRIP="${trip%%|*}" M3_TRIP2="${trip#*|}" \
        bash scripts/make-plugin.sh "$dest" ) > "$out" 2>&1
    rc=$?
    assert "m3 [$trip]: interrupted rebuild fails" test "$rc" -ne 0
    assert "m3 [$trip]: previous skills survive" test -f "$dest/skills/pre-pr-review/old-only"
    assert "m3 [$trip]: previous runner survives" test -f "$dest/scripts/review.sh"
    assert "m3 [$trip]: previous review assets survive" test -f "$dest/review/schema.json"
    assert "m3 [$trip]: README.md is restored" test -f "$dest/README.md"
    assert "m3 [$trip]: restored build leaves no staging behind" \
      test "$(ls -A "$WORK/m3-out")" = plugin
    rm -rf "$WORK"/m3-out/.make-plugin-stage.*
  done

  # A cross-filesystem install killed after its copy leaves the entry on both sides.
  printf '#!/bin/sh\ncase "$1" in */new/skills) cp -R "$1" "$2"; kill -TERM "$PPID"; exit 1 ;; esac\nexec %s "$@"\n' \
    "$(command -v mv)" > "$WORK/m3-bin/mv"
  ( cd "$hub" && PATH="$WORK/m3-bin:$PATH" bash scripts/make-plugin.sh "$WORK/m3-out/fresh" ) > "$out" 2>&1
  rc=$?
  assert "m3: first build killed mid-install fails" test "$rc" -ne 0
  assert "m3: first build killed mid-install leaves no generated entries" \
    test "$(ls -A "$WORK/m3-out/fresh")" = .make-plugin-generated
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
  test_path_rules_reach_matching_lens_prompts \
  test_path_rule_globs \
  test_install_ignores_repo_local_yaml_module \
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
  test_update_header_lists_what_it_copies \
  test_bootstrap_block_matches_in_both_docs \
  test_bootstrap_pins_and_refuses_a_branch \
  test_bootstrap_tells_unreachable_from_missing \
  test_bootstrap_tells_failed_lookup_from_missing \
  test_update_warns_on_stale_local_clone \
  test_update_installs_the_release_over_a_local_clone \
  test_update_unreachable_hub_fails_despite_a_clone \
  test_update_local_needs_the_flag \
  test_update_latest_release_lookup \
  test_init_seeds_coderabbit_config \
  test_init_never_overwrites_existing_config \
  test_init_respects_other_config_spellings \
  test_init_seeds_the_sync_workflow \
  test_init_reseeding_the_sync_workflow \
  test_install_reports_the_sync_workflow \
  test_sync_current_succeeds_quietly \
  test_sync_behind_opens_one_pr \
  test_sync_updates_the_open_pr \
  test_sync_respects_a_declined_pr \
  test_sync_failures_fail_visibly \
  test_sync_failed_or_empty_update_fails \
  test_sync_never_runs_the_incoming_script \
  test_sync_ignores_fork_prs \
  test_sync_refuses_before_pushing \
  test_update_pins_a_release_without_the_sync_script \
  test_install_check_reports_gate_state \
  test_install_check_fails_on_unwired_gate \
  test_install_check_foreign_hooks_path \
  test_install_keeps_live_git_hooks \
  test_prepush_judges_destination_ref \
  test_prepush_reads_the_verdict_header \
  test_prepush_rejects_a_spec_verdict \
  test_prepush_skips_a_sha256_deletion \
  test_prepush_rejects_an_uncommitted_verdict \
  test_findings_name_mode_and_head_on_every_path \
  test_review_archives_the_previous_verdicts \
  test_verdict_archive_is_shared_across_worktrees \
  test_verdict_archive_failure_warns_without_failing \
  test_verdict_archive_keys_an_uncommitted_verdict \
  test_prepush_archives_the_verdict \
  test_review_tune_docs_name_legacy_archive \
  test_postmortem_finds_the_verdict_for_the_reviewed_commit \
  test_postmortem_scores_code_present_at_the_verdict \
  test_postmortem_lens_evidence_belongs_to_one_run \
  test_postmortem_docs_score_per_finding_and_cite_lens_evidence \
  test_uncommitted_marker_docs \
  test_expanded_files_hold_no_positional_refs \
  test_postmortem_docs_record_and_route \
  test_review_tune_docs_read_postmortem_records \
  test_postmortem_plateau_is_a_hypothesis \
  test_replay_scores_reports_and_writes_nothing_else \
  test_replay_failure_is_reported_and_cleaned_up \
  test_replay_interrupt_removes_the_worktree \
  test_replay_recent_and_limit \
  test_replay_silent_failures_are_failures \
  test_replay_lenses_cannot_reach_later_history \
  test_replay_keeps_transcripts_and_denials \
  test_replay_sum_across_spokes \
  test_replay_refuses_a_stale_kit \
  test_replay_docs_post_nothing \
  test_review_warns_when_hook_unwired \
  test_review_warns_when_hooks_path_points_elsewhere \
  test_review_quiet_when_git_hooks_chain \
  test_review_warns_when_kit_is_behind \
  test_review_kit_staleness_unknown \
  test_review_kit_check_skips_an_old_updater \
  test_review_kit_lookup_is_cached \
  test_review_kit_cache_edge_cases \
  test_review_kit_lookup_times_out \
  test_make_plugin_interrupted_swap_keeps_previous_build \
  test_make_plugin_refuses_an_unlistable_destination \
  test_make_plugin_failed_rebuild_keeps_previous_build

echo
if [ "$FAILURES" -gt 0 ]; then
  printf '%d assertion(s) FAILED\n' "$FAILURES"; exit 1
fi
echo "all tests passed"
