#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# review.sh — multi-lens pre-PR code review via OpenAI Codex CLI.
#
# Runs N narrow, parallel review passes over the current branch's diff, each
# with its own focus, then merges the structured findings into a single
# JSON + Markdown report for Claude Code to adjudicate.
#
# Usage:
#   ./scripts/review.sh                     # diff vs auto-detected base branch
#   ./scripts/review.sh origin/develop      # diff vs explicit base
#   ./scripts/review.sh --uncommitted       # staged + unstaged + untracked
#   ./scripts/review.sh --spec docs/specs/foo.md   # review a spec, not code
#   ./scripts/review.sh --lenses security,contracts
#   ./scripts/review.sh --effort medium --confidence 0.7
#
# Exit codes: 0 ok · 1 setup/runtime error · 2 findings at/above --fail-on
# ---------------------------------------------------------------------------
set -uo pipefail

# --- locate repo root ------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

# shellcheck source=lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"

# --- defaults (override in .review/config.sh or via flags) -----------------
LENSES="correctness,security,contracts,resources,tests,scope"
EFFORT="high"
MODEL=""                 # empty = whatever the deep-review profile pins
PROFILE="deep-review"
CONFIDENCE_MIN="0.5"
MAX_PARALLEL="6"
LENS_TIMEOUT="900"       # seconds per lens
FAIL_ON="none"           # none | critical | high | medium | low
RUN_ANALYZERS="1"
BASE=""
MODE="branch"            # branch | uncommitted | spec
SPEC_PATHS=""
LENSES_FLAG=0

[ -f "$REPO_ROOT/.review/config.sh" ] && . "$REPO_ROOT/.review/config.sh"

# Any failed exit before a report is written must not leave the previous run's
# report — and its complete:true — standing in for this one.
STARTED=0; REPORT_WRITTEN=0; HOOK_WARNING=""
finish_report() {
  local rc=$?
  [ "$STARTED" = 1 ] || return
  if [ "$REPORT_WRITTEN" = 0 ]; then
    printf '{"findings":[],"lenses_failed":[],"complete":false}\n' > .review/findings.json
    printf '# Codex pre-PR review\n\n> **INCOMPLETE — the run stopped (rc=%s) before producing a report.** Nothing was reviewed.\n' \
      "$rc" > .review/findings.md
  fi
  [ -z "$HOOK_WARNING" ] || printf '\n> %s\n' "$HOOK_WARNING" >> .review/findings.md
}
trap finish_report EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- args ------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --uncommitted)  MODE="uncommitted" ;;
    --spec)         MODE="spec"; SPEC_PATHS="$SPEC_PATHS$2
"; shift ;;
    --lenses)       LENSES="$2"; LENSES_FLAG=1; shift ;;
    --effort)       EFFORT="$2"; shift ;;
    --model)        MODEL="$2"; shift ;;
    --profile)      PROFILE="$2"; shift ;;
    --confidence)   CONFIDENCE_MIN="$2"; shift ;;
    --timeout)      LENS_TIMEOUT="$2"; shift ;;
    --fail-on)      FAIL_ON="$2"; shift ;;
    --no-analyzers) RUN_ANALYZERS="0" ;;
    --parallel)     MAX_PARALLEL="$2"; shift ;;
    -h|--help)      sed -n '2,18p' "$0"; exit 0 ;;
    -*)             die "unknown flag: $1" ;;
    *)              [ -n "$1" ] || die "empty base ref — name a branch or commit, or omit it to diff against the default base"
                    BASE="$1" ;;
  esac
  shift
done

if ! hook_wiring; then
  warn "pre-push hook not wired in this clone: $HOOK_NOTE${HOOK_FIX:+ — fix: $HOOK_FIX}"
  HOOK_WARNING="**Pre-push hook not wired in this clone:** $HOOK_NOTE."
  [ -z "$HOOK_FIX" ] || HOOK_WARNING="$HOOK_WARNING Fix: \`$HOOK_FIX\`"
fi

# The previous verdicts, before this run's adjudication overwrites them.
archive_verdicts

OUT=".review/raw"
rm -rf "$OUT"; mkdir -p "$OUT"
rm -f .review/findings.json .review/findings.md
STARTED=1

# --- preflight -------------------------------------------------------------
need_cmd git
need_cmd jq
need_cmd codex
[ -f .review/schema.json ] || die "missing .review/schema.json — run scripts/review-install.sh"

# Fail closed. Every lens would fail identically on an expired login, and six
# empty lens outputs render as a clean review — the exact shape of "nothing"
# and "failed" being indistinguishable that this pipeline exists to catch.
if [ "${REVIEW_SKIP_AUTH_CHECK:-0}" != "1" ] && ! codex login status >/dev/null 2>&1; then
  die "not authenticated to Codex — run 'codex login' (REVIEW_SKIP_AUTH_CHECK=1 overrides, for when 'codex login status' is broken but exec works)"
fi

# A lens runs `codex exec`, which loads AGENTS.md — and AGENTS.md tells agents to
# run this script. Without this guard a lens can re-enter the pipeline instead of
# returning its findings.
[ -z "${REVIEW_LENS_SESSION:-}" ] || die "refusing to run inside a review lens session (REVIEW_LENS_SESSION is set)"

# --- spec mode: its own lens set, no diff, no analyzers --------------------
if [ "$MODE" = "spec" ]; then
  [ "$LENSES_FLAG" = 1 ] || LENSES="spec-assumptions,spec-holes,spec-conflicts,spec-ambiguity"
  RUN_ANALYZERS="0"
fi

# --- resolve the change set ------------------------------------------------
# NUL-delimited at the git boundary: without -z git C-quotes non-ASCII, tab, quote and
# backslash names, and a quoted name matches no file on disk.
nul_to_lines() { local f; while IFS= read -r -d '' f; do printf '%s\n' "$f"; done; }

# A gitleaks leak as a one-finding JSON array, or [] when there is none. The lenses
# are told not to re-report analyzer output, so no lens reports it.
secret_findings() { # secret_findings <leaked 0|1> <why_it_matters>
  [ "$1" = 1 ] || { echo '[]'; return 0; }
  local title fix
  if [ "$MODE" = "branch" ]; then
    title="Secret in branch commit history"
    fix="Rotate the secret, then drop the commits that carry it (squash or rebase the branch)."
  else
    title="Secret in the change set"
    fix="Rotate the secret, and remove it from the change before committing it."
  fi
  jq -n --arg title "$title" --arg why "$2" --arg fix "$fix" \
    --arg evidence "$(awk '$0 == "### gitleaks (secrets)" { on = 1; next } /^### / { on = 0 } on' \
      "$OUT/analyzers.txt" 2>/dev/null | head -40)" '
    [{ id: "F1", file: ".review/raw/analyzers.txt", line_start: 1, line_end: 1,
       severity: "critical", category: "security", lens: "gitleaks", agreement: 1, confidence: 1,
       title: $title, why_it_matters: $why, evidence: $evidence, suggested_fix: $fix }]'
}

if [ "$MODE" = "spec" ]; then
  : > "$OUT/changed-files.txt"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -d "$p" ]; then
      find "$p" -name '*.md' -type f > "$OUT/spec-found.tmp" || die "cannot read spec directory: $p"
      [ -s "$OUT/spec-found.tmp" ] || die "no .md spec documents in: $p"
      cat "$OUT/spec-found.tmp" >> "$OUT/changed-files.txt"; rm -f "$OUT/spec-found.tmp"
    elif [ -f "$p" ]; then
      printf '%s\n' "$p" >> "$OUT/changed-files.txt"
    else
      die "spec path not found: $p"
    fi
  done <<EOF
$SPEC_PATHS
EOF
  [ -s "$OUT/changed-files.txt" ] || die "no spec paths given"
  RANGE_LABEL="spec documents: $(tr '\n' ' ' < "$OUT/changed-files.txt")"
elif [ "$MODE" = "uncommitted" ]; then
  DIFF_BASE="HEAD"
  git diff HEAD > "$OUT/diff.patch" || die "git diff HEAD failed"
  git diff HEAD --name-only -z | nul_to_lines > "$OUT/changed-files.txt" \
    || die "could not list changed files"
  git ls-files --others --exclude-standard -z 2> "$OUT/untracked.err" | nul_to_lines > "$OUT/untracked.txt" \
    || die "could not list untracked files"
  # an unreadable directory is a warning and rc 0 — its files are simply never listed
  [ -s "$OUT/untracked.err" ] && die "could not list every untracked file: $(head -3 "$OUT/untracked.err")"
  rm -f "$OUT/untracked.err"
  while IFS= read -r f; do
    case "$f" in "$OUT"/*) continue ;; esac
    # a nested repository or a symlinked directory: --no-index exits 1 and diffs nothing
    [ -d "$f" ] && { printf '%s\n' "$f" >> "$OUT/unreadable.txt"; continue; }
    git diff --no-index -- /dev/null "$f" >> "$OUT/diff.patch" 2>/dev/null
    # --no-index exits 1 when the files differ; anything above that is a failure
    [ $? -le 1 ] || printf '%s\n' "$f" >> "$OUT/unreadable.txt"
  done < "$OUT/untracked.txt"
  cat "$OUT/untracked.txt" >> "$OUT/changed-files.txt"
  rm -f "$OUT/untracked.txt"
  RANGE_LABEL="uncommitted changes in working tree"
else
  [ -n "$BASE" ] || BASE="$(detect_base_branch)"
  git rev-parse --verify "$BASE" >/dev/null 2>&1 || die "base ref not found: $BASE"
  MERGE_BASE="$(git merge-base "$BASE" HEAD)" || die "no merge base with $BASE"
  DIFF_BASE="$MERGE_BASE"
  git diff "$MERGE_BASE"...HEAD > "$OUT/diff.patch" || die "git diff failed"
  git diff "$MERGE_BASE"...HEAD --name-only -z | nul_to_lines > "$OUT/changed-files.txt" \
    || die "could not list changed files"
  git log --format='%h %s' "$MERGE_BASE"..HEAD > "$OUT/commits.txt"
  RANGE_LABEL="$BASE...$(git rev-parse --abbrev-ref HEAD) (merge-base ${MERGE_BASE:0:10})"
fi

# Never review our own generated artifacts — except in spec mode, where every path
# was named explicitly on the command line and dropping one silently reviews nothing.
# Only the generated ones: tracked .review/ sources (rubric, prompts, config) are
# review inputs like any other file, and excluding them makes a branch that changes
# only the review rules hit the zero-change early exit below and report a clean pass.
if [ "$MODE" = "spec" ]; then
  sort -u "$OUT/changed-files.txt" > "$OUT/changed-files.tmp"
else
  grep -v -E '^\.review/(raw|runs)/|^\.review/(findings\.json|findings\.md|verdict\.md|spec-verdict\.md)$' \
    "$OUT/changed-files.txt" | sort -u > "$OUT/changed-files.tmp"
fi
mv "$OUT/changed-files.tmp" "$OUT/changed-files.txt"

# A listed path that is neither readable on disk nor a deletion was never reviewed.
# In branch mode HEAD is the reviewed tree, so a path HEAD still has is not deleted.
while IFS= read -r f; do
  [ -L "$f" ] && continue
  if [ -e "$f" ]; then
    [ -r "$f" ] && continue
  elif [ -n "${DIFF_BASE:-}" ] && git rev-parse -q --verify "$DIFF_BASE:$f" >/dev/null; then
    [ "$MODE" = branch ] && git rev-parse -q --verify "HEAD:$f" >/dev/null || continue
  fi
  printf '%s\n' "$f" >> "$OUT/unreadable.txt"
done < "$OUT/changed-files.txt"
if [ -s "$OUT/unreadable.txt" ]; then
  sort -u -o "$OUT/unreadable.txt" "$OUT/unreadable.txt"
  warn "$(grep -c . < "$OUT/unreadable.txt") changed path(s) could not be read — the run will be marked incomplete:"
  sed 's/^/  /' "$OUT/unreadable.txt" >&2
fi
CHANGED_COUNT="$(grep -c . < "$OUT/changed-files.txt" || true)"
DIFF_LINES=0
[ -f "$OUT/diff.patch" ] && DIFF_LINES="$(wc -l < "$OUT/diff.patch" | tr -d ' ')"

if [ "${CHANGED_COUNT:-0}" -eq 0 ]; then
  info "no changes to review against $RANGE_LABEL"
  # Carries complete/lenses_failed like every other exit path. Adjudication is told to check
  # `complete` before anything else, so a payload without it forces the reader to guess — and
  # the guess that a clean run and a broken one look alike is exactly what those fields exist
  # to prevent. complete is false because nothing was reviewed: a wrong BASE lands here too.
  COMMITS=0
  if [ "$MODE" = "branch" ]; then
    COMMITS="$(git rev-list --count "$MERGE_BASE..HEAD")" || die "could not count commits in $MERGE_BASE..HEAD"
  fi
  # Commits that net out to no diff still publish whatever they once added.
  HISTORY=""; HISTORY_NOTE=""
  if [ "$COMMITS" -gt 0 ]; then
    if [ "$RUN_ANALYZERS" != "1" ]; then
      HISTORY="not_scanned"; HISTORY_NOTE="--no-analyzers"
    else
      . "$REPO_ROOT/scripts/lib/analyzers.sh"
      scan_history_secrets "$OUT"
      case $? in
        0) HISTORY="clean" ;;
        3) HISTORY="leaks" ;;
        4) HISTORY="not_scanned"; HISTORY_NOTE="gitleaks is not installed" ;;
        *) HISTORY="failed" ;;
      esac
    fi
  fi
  LEAKED=0; [ "$HISTORY" = "leaks" ] && LEAKED=1
  SECRET_FINDINGS="$(secret_findings "$LEAKED" \
    "The net diff is empty, but commits in ${MERGE_BASE:-}..HEAD still carry it, and pushing them publishes it.")" \
    || die "could not build the gitleaks finding"
  jq -n --arg h "$HISTORY" --argjson n "$COMMITS" --argjson secrets "$SECRET_FINDINGS" '
    { findings: $secrets, lenses_failed: [], complete: false, changed_files: 0 }
    + (if $h == "" then {} else { history_scan: { commits: $n, result: $h } } end)
  ' > .review/findings.json || die "could not write findings.json"
  {
    printf '# Codex pre-PR review\n\nNo changes to review against %s.\n' "$RANGE_LABEL"
    printf '\n> **Nothing was reviewed** — this is not a clean review. If changes were expected, check the base ref.\n'
    case "$HISTORY" in
      clean)  printf '\nIts %s commit(s) net out to no diff; their history was scanned for secrets and none were found.\n' "$COMMITS" ;;
      leaks)  printf '\n> **SECRET IN BRANCH HISTORY.** The net diff is empty, but gitleaks found leaks in its %s commit(s), and pushing them publishes them. See `%s/analyzers.txt`.\n' "$COMMITS" "$OUT" ;;
      failed) printf '\n> **INCOMPLETE — the secret scan of its %s commit(s) FAILED**, so their history was NOT checked. See `%s/analyzers.txt`.\n' "$COMMITS" "$OUT" ;;
      not_scanned) printf '\n> Its %s commit(s) net out to no diff, and their history was NOT scanned for secrets: %s.\n' "$COMMITS" "$HISTORY_NOTE" ;;
    esac
  } > .review/findings.md
  REPORT_WRITTEN=1
  warn "nothing was reviewed — the report is marked incomplete"
  case "$HISTORY" in
    clean)  info "its $COMMITS commit(s) were scanned for secrets: none found" ;;
    leaks)  warn "gitleaks found a secret in the branch history ($COMMITS commit(s)) — see $OUT/analyzers.txt"
            case "$FAIL_ON" in critical|high|medium|low) exit 2 ;; esac ;;
    failed) warn "INCOMPLETE: the secret scan of $COMMITS commit(s) failed — see $OUT/analyzers.txt" ;;
    not_scanned) warn "$COMMITS commit(s) were not scanned for secrets: $HISTORY_NOTE" ;;
  esac
  exit 0
fi

if [ "$MODE" = "spec" ]; then
  info "reviewing $CHANGED_COUNT spec file(s) — $RANGE_LABEL"
else
  info "reviewing $CHANGED_COUNT file(s), $DIFF_LINES diff lines — $RANGE_LABEL"
fi

# --- cheap static signal (fed to Codex as priors, so it aims higher) -------
SECRETS_LEAKED=0; SECRETS_FAILED=0; SECRETS_SKIPPED=0; SECRETS_NOTE=""
if [ "$RUN_ANALYZERS" = "1" ]; then
  . "$REPO_ROOT/scripts/lib/analyzers.sh"
  collect_analyzer_output "$OUT" || warn "analyzer collection had errors (non-fatal)"
  [ "$SECRETS_SKIPPED" = 0 ] || SECRETS_NOTE="gitleaks is not installed"
elif [ "$MODE" != "spec" ]; then
  SECRETS_NOTE="--no-analyzers"
fi
if [ "$MODE" = "branch" ]; then
  SECRETS_WHY="gitleaks found it in $MERGE_BASE..HEAD, and pushing those commits publishes it, even where a later commit removed it."
else
  SECRETS_WHY="gitleaks found it in the uncommitted changes, and committing and pushing them publishes it."
fi
SECRET_FINDINGS="$(secret_findings "$SECRETS_LEAKED" "$SECRETS_WHY")" || die "could not build the gitleaks finding"

# --- build the shared context block ----------------------------------------
{
  echo "## Review context"
  echo
  echo "- Repository root: \`$REPO_ROOT\`"
  echo "- Change set: $RANGE_LABEL"
  if [ "$MODE" = "spec" ]; then
    echo "- Documents under review (cite findings against these files' line numbers):"
    sed 's/^/  - `/;s/$/`/' "$OUT/changed-files.txt"
  else
    echo "- Files changed: $CHANGED_COUNT"
    echo "- Unified diff: \`.review/raw/diff.patch\`"
    echo "- Changed file list: \`.review/raw/changed-files.txt\`"
  fi
  [ -f "$OUT/commits.txt" ] && echo "- Commits in range: \`.review/raw/commits.txt\`"
  [ -s "$OUT/analyzers.txt" ] && echo "- Static analyzer output already collected: \`.review/raw/analyzers.txt\` (do NOT re-report anything a linter already flagged there)"
  echo
} > "$OUT/context.md"

[ ! -s .review/rubric.md ] || [ -r .review/rubric.md ] || die "cannot read .review/rubric.md"
[ -s .review/rubric.md ] || warn "no .review/rubric.md — lenses will not see this repository's house rules (run /review-onboard)"

# --- launch lenses ---------------------------------------------------------
pids=""; running=0; launched=""
OLD_IFS="$IFS"; IFS=','
for lens in $LENSES; do
  IFS="$OLD_IFS"
  lens="$(echo "$lens" | tr -d '[:space:]')"
  [ -n "$lens" ] || { IFS=','; continue; }
  lens_file=".review/prompts/${lens}.md"
  if [ ! -f "$lens_file" ]; then
    # Counted as failed, not merely skipped: its area went unreviewed either way, and a run
    # that silently drops a lens while reporting complete:true is the failure this whole
    # field exists to make visible. A local overlay alone does not create a lens — the shared
    # base prompt has to exist too.
    warn "no prompt for lens '$lens' at $lens_file — skipping"
    missing_lenses="${missing_lenses:-} $lens"
    IFS=','; continue
  fi

  pf="$OUT/prompt-$lens.md"
  common=".review/prompts/_common.md"
  [ "$MODE" = "spec" ] && common=".review/prompts/_common-spec.md"
  {
    cat "$common"
    echo; echo "---"; echo
    cat "$OUT/context.md"
    echo "---"; echo
    if [ -s .review/rubric.md ]; then
      echo "## House rules (\`.review/rubric.md\` — a violation is a finding for every lens)"
      echo
      cat .review/rubric.md
      echo; echo "---"; echo
    fi
    if [ -s .review/learnings-shared.md ]; then
      echo "## Kit-wide learnings (shared across repositories — obey these)"
      echo
      cat .review/learnings-shared.md
      echo; echo "---"; echo
    fi
    if [ -s .review/learnings.md ]; then
      echo "## Repository learnings (accumulated from past reviews — obey these)"
      echo
      cat .review/learnings.md
      echo; echo "---"; echo
    fi
    cat "$lens_file"
    # repo-owned overlay: extra hunt lists layered onto the shared lens prompt
    if [ -s ".review/prompts.local/${lens}.md" ]; then
      echo
      cat ".review/prompts.local/${lens}.md"
    fi
  } > "$pf"

  (
    # no --ask-for-approval: removed in codex 0.149; exec is non-interactive
    # and the deep-review profile pins approval_policy = "never" anyway.
    args="exec --profile $PROFILE --sandbox read-only"
    args="$args -c model_reasoning_effort=$EFFORT"
    [ -n "$MODEL" ] && args="$args --model $MODEL"
    # shellcheck disable=SC2086
    REVIEW_LENS_SESSION=1 run_with_timeout "$LENS_TIMEOUT" \
      codex $args \
        --output-schema .review/schema.json \
        -o "$OUT/out-$lens.json" \
        "$(cat "$pf")" \
      > "$OUT/log-$lens.txt" 2>&1
    echo "$?" > "$OUT/rc-$lens"
  ) &
  pids="$pids $!"
  launched="$launched $lens"
  info "  → lens '$lens' started (effort=$EFFORT)"

  running=$((running + 1))
  if [ "$running" -ge "$MAX_PARALLEL" ]; then wait; running=0; fi
  IFS=','
done
IFS="$OLD_IFS"

wait

# --- normalise each lens output -------------------------------------------
ok_lenses=0
failed_lenses=""
for lens in $launched; do
  rc="$(cat "$OUT/rc-$lens" 2>/dev/null)"
  case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
  f="$OUT/out-$lens.json"
  if [ ! -s "$f" ]; then
    warn "lens '$lens' produced no output (rc=$rc) — see $OUT/log-$lens.txt"
    failed_lenses="$failed_lenses $lens"
    printf '{"findings":[]}' > "$f"; continue
  fi
  salvage_json "$f" || {
    warn "lens '$lens' returned unparseable output — see $OUT/log-$lens.txt"
    failed_lenses="$failed_lenses $lens"
    printf '{"findings":[]}' > "$f"; continue
  }
  jq --arg l "$lens" '.findings = ((.findings // []) | map(. + {lens: $l}))' "$f" \
    > "$f.tmp" && mv "$f.tmp" "$f"
  n="$(jq '.findings | length' "$f")"
  if [ "$rc" -ne 0 ]; then
    # Parseable output is not a finished review: a lens killed by the timeout, or one
    # whose truncated output salvage_json scavenged, still leaves a valid JSON object.
    # Its findings are kept — its area is still unreviewed.
    warn "lens '$lens' exited rc=$rc — keeping its $n finding(s), but its area is unreviewed"
    failed_lenses="$failed_lenses $lens"
  else
    info "  ← lens '$lens': $n finding(s) (rc=$rc)"
  fi
  # Counts usable output, and only gates the every-lens-failed abort below — a salvaged
  # lens must still reach the merge even though it is also recorded as failed.
  ok_lenses=$((ok_lenses + 1))
done

if [ "$ok_lenses" -eq 0 ]; then
  # Write the failure out before dying. Otherwise .review/findings.json still holds the
  # PREVIOUS run's report — with its own complete:true — and the next reader adjudicates a
  # stale pass against the current branch without anything saying so.
  failed_lenses="$failed_lenses${missing_lenses:-}"
  jq -n --arg failed "$(printf '%s' "${failed_lenses# }")" --argjson secrets "$SECRET_FINDINGS" \
    --argjson n "$CHANGED_COUNT" \
    '{findings: $secrets, lenses_failed: ($failed | if . == "" then [] else split(" ") end), complete: false,
      changed_files: $n}' \
    > .review/findings.json
  printf '# Codex pre-PR review\n\n> **INCOMPLETE — every lens failed.** No area of this diff was reviewed.\n> Check `%s/log-*.txt`.\n' \
    "$OUT" > .review/findings.md
  REPORT_WRITTEN=1
  die "every lens failed — check $OUT/log-*.txt"
fi

# --- merge, filter, dedupe, sort ------------------------------------------
jq -s --argjson th "$CONFIDENCE_MIN" '
  { findings: (map(.findings // []) | add // []) }
  | .findings |= (
      map(select((.confidence // 0) >= $th))
      # collapse duplicates, but keep the highest severity/confidence seen and
      # remember every lens that independently reported it (agreement = signal)
      | group_by(((.file // "?") + ":" + ((.line_start // 0)|tostring) + ":" + (.title // "?")) | ascii_downcase)
      | map(
          ( sort_by(({critical:0,high:1,medium:2,low:3}[.severity] // 4), -(.confidence // 0)) | .[0] )
          + { lens: (map(.lens) | unique | join(",")),
              agreement: length,
              confidence: (map(.confidence // 0) | max) }
        )
      | sort_by(({critical:0, high:1, medium:2, low:3}[.severity] // 4), -(.agreement), .file, (.line_start // 0))
      | to_entries | map(.value + {id: ("F" + ((.key + 1)|tostring))})
    )
' "$OUT"/out-*.json > .review/findings.json || die "merge failed"

# A lens that died contributes an empty findings array, which is indistinguishable
# from a lens that ran and found nothing. Record which ones failed so adjudication
# cannot read a partial run as a complete review.
failed_lenses="$failed_lenses${missing_lenses:-}"
FAILED_LIST="$(printf '%s' "${failed_lenses# }")"
UNREADABLE_COUNT=0
[ -s "$OUT/unreadable.txt" ] && UNREADABLE_COUNT="$(grep -c . < "$OUT/unreadable.txt")"
jq --arg failed "$FAILED_LIST" --arg unreadable "$(cat "$OUT/unreadable.txt" 2>/dev/null)" \
  --argjson secrets "$SECRET_FINDINGS" --argjson scan_failed "$SECRETS_FAILED" --argjson n "$CHANGED_COUNT" '
  .findings = ($secrets + .findings | to_entries | map(.value + {id: ("F" + ((.key + 1)|tostring))}))
  | . + { lenses_failed: ($failed | if . == "" then [] else split(" ") end),
        unreadable_paths: ($unreadable | split("\n") | map(select(. != ""))) }
  | . + { complete: ((.lenses_failed | length) == 0 and (.unreadable_paths | length) == 0 and $scan_failed == 0),
          changed_files: $n }
' .review/findings.json > .review/findings.json.tmp \
  && mv .review/findings.json.tmp .review/findings.json || die "could not finalise findings.json"

TOTAL="$(jq '.findings | length' .review/findings.json)"

# --- human-readable render -------------------------------------------------
{
  echo "# Codex pre-PR review"
  echo
  echo "\`$RANGE_LABEL\` · $CHANGED_COUNT files · lenses:$launched · effort \`$EFFORT\` · min confidence \`$CONFIDENCE_MIN\`"
  echo
  if [ -n "$FAILED_LIST" ]; then
    echo "> **INCOMPLETE REVIEW — do not treat this as a clean pass.**"
    echo "> These lenses did not finish their review: \`$FAILED_LIST\`."
    echo "> Their areas are unreviewed; any findings they emitted before failing are"
    echo "> listed below. See \`$OUT/log-<lens>.txt\`, fix the cause and re-run before"
    echo "> relying on this report."
    echo
  fi
  if [ "$UNREADABLE_COUNT" -gt 0 ]; then
    echo "> **INCOMPLETE REVIEW — $UNREADABLE_COUNT changed path(s) could not be read**, so no lens saw them:"
    sed 's/^/> - `/;s/$/`/' "$OUT/unreadable.txt"
    echo
  fi
  if [ "$SECRETS_FAILED" = 1 ]; then
    echo "> **INCOMPLETE REVIEW — the gitleaks secret scan FAILED**, so secrets were NOT checked."
    echo "> See \`$OUT/analyzers.txt\`."
    echo
  fi
  if [ -n "$SECRETS_NOTE" ]; then
    echo "> Secrets were NOT checked: $SECRETS_NOTE."
    echo
  fi
  if [ "$(jq '.findings | length' .review/findings.json)" -eq 0 ]; then
    if [ -n "$FAILED_LIST" ] || [ "$UNREADABLE_COUNT" -gt 0 ] || [ "$SECRETS_FAILED" = 1 ]; then
      echo "_No findings — but the run was incomplete, so this is not a clean result._"
    else
      echo "_No findings above the confidence threshold._"
    fi
  else
    jq -r '
      .findings[]
      | "## " + (.id) + " · " + (.severity | ascii_upcase) + " · " + (.title)
      + "\n\n`" + (.file // "?") + ":" + ((.line_start // 0) | tostring)
      + (if (.line_end // 0) > (.line_start // 0) then "-" + ((.line_end)|tostring) else "" end)
      + "`  ·  lens `" + (.lens // "?") + "`  ·  " + (.category // "-")
      + "  ·  confidence " + ((.confidence // 0) | tostring)
      + (if (.agreement // 1) > 1 then "  ·  **" + ((.agreement)|tostring) + " lenses agree**" else "" end)
      + "\n\n**Why it matters.** " + (.why_it_matters // "-")
      + "\n\n**Evidence.** " + (.evidence // "-")
      + (if (.suggested_fix // "") != "" then "\n\n**Suggested fix.** " + .suggested_fix else "" end)
      + "\n"
    ' .review/findings.json
  fi
} > .review/findings.md
REPORT_WRITTEN=1

# --- summary ---------------------------------------------------------------
echo
info "$TOTAL finding(s) → .review/findings.json  ·  .review/findings.md"
[ -z "$FAILED_LIST" ] || warn "INCOMPLETE: lens(es) failed; their areas are unreviewed —$failed_lenses"
[ "$UNREADABLE_COUNT" -eq 0 ] || warn "INCOMPLETE: $UNREADABLE_COUNT changed path(s) could not be read — see $OUT/unreadable.txt"
[ "$SECRETS_FAILED" = 0 ] || warn "INCOMPLETE: the gitleaks secret scan failed — see $OUT/analyzers.txt"
[ "$SECRETS_LEAKED" = 0 ] || warn "gitleaks found a secret — see $OUT/analyzers.txt"
[ -z "$SECRETS_NOTE" ] || warn "secrets were not checked: $SECRETS_NOTE"
jq -r '
  (.findings | group_by(.severity) | map({(.[0].severity): length}) | add // {}) as $c
  | ["critical","high","medium","low"] | map(. + ": " + (($c[.] // 0)|tostring)) | join("   ")
' .review/findings.json

# --- gate ------------------------------------------------------------------
case "$FAIL_ON" in
  none) exit 0 ;;
  critical|high|medium|low)
    hit="$(jq --arg lvl "$FAIL_ON" '
      {critical:0,high:1,medium:2,low:3} as $r
      | [.findings[] | select(($r[.severity] // 9) <= ($r[$lvl] // 9))] | length' .review/findings.json)"
    if [ "$hit" -gt 0 ]; then
      warn "$hit finding(s) at or above '$FAIL_ON'"; exit 2
    fi
    ;;
esac
exit 0
