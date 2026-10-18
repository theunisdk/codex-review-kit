#!/usr/bin/env bash
# Collect cheap static-analysis signal on the changed files and write it to
# .review/raw/analyzers.txt. Every tool is OPTIONAL — a tool that is not
# installed is skipped. The point is not to gate on this output; it is to hand
# Codex the lint-level noise up front so it spends its reasoning budget on
# semantic bugs a linter structurally cannot find.
#
# Every section ends with one status line, which review.sh carries into the lens
# prompt and findings.json:
#   analyzer status: <ran|skipped|failed|unknown> — <why>
# Only `ran` sections hold results. The lenses are told not to re-report what a
# linter flagged, so a tool that could not run must never read as clean.
#
# This file is synced from the kit — do not edit it in a repo. Wire your own
# stack in .review/analyzers.local.sh instead (repo-owned, never overwritten).

# Output that says the tool never ran, whatever its exit status: npx fetching an
# unrelated package named like the tool, a missing binary or dependency, a crash.
# No backslashes: _label_sections hands it to awk.
ANALYZER_CANNOT_RUN_RE='This is not the tsc command you are looking for|command not found|: not found$|could not determine executable to run|Command "[^"]*" not found|ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL|will be installed:|Need to install the following packages|MODULE_NOT_FOUND|Cannot find package|failed to load config from|Failed to load url|ModuleNotFoundError|Traceback [(]most recent call last[)]|^panic: |Segmentation fault|cannot find main module|missing go[.]sum entry|no required module provides package|could not find .Cargo[.]toml.|spawn [^ ]* ENOENT'

_analyzer_status() { printf 'analyzer status: %s\n' "$*" >> "$report"; }

# The first line of <output> that says the tool never ran, trimmed; empty if none.
_cannot_run_line() {
  printf '%s\n' "$1" | grep -m 1 -E "$ANALYZER_CANNOT_RUN_RE" | sed 's/^[[:space:]]*//' | cut -c 1-200
}

# _run_analyzer <title> <findings-ERE> <command> [args...] — runs one tool in a
# section of its own and labels it from its exit status and output.
# <findings-ERE> matches a line of a real finding, such as '\.ts:[0-9]+'; pass ''
# when the tool has no fixed shape. A non-zero exit with no such line is unknown,
# never clean: a crash and a finding exit alike.
_run_analyzer() {
  local title="$1" re="$2" out rc why; shift 2
  _section "$title"
  out="$("$@" < /dev/null 2>&1)"; rc=$?
  why="$(_cannot_run_line "$out")"
  if [ -n "$why" ]; then
    printf '%s\n' "$out" | head -20 >> "$report"
    _analyzer_status "failed — $title could not run (rc=$rc): $why"
  elif [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    _analyzer_status "ran — clean (rc=0, no output)"
  elif [ -n "$re" ] && grep -qE -- "$re" <<< "$out"; then
    printf '%s\n' "$out" | head -200 >> "$report"
    _analyzer_status "ran — findings above (rc=$rc)"
  elif [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out" | head -200 >> "$report"
    _analyzer_status "ran — rc=0, output above"
  else
    printf '%s\n' "$out" | head -20 >> "$report"
    if [ -n "$re" ]; then why="no output line is a finding"; else why="no findings pattern to tell a finding from a crash"; fi
    _analyzer_status "unknown — rc=$rc and $why, so $title may not have checked anything"
  fi
}

# Gives every section without a status line one: what .review/analyzers.local.sh
# wrote without _run_analyzer. Its exit status is lost, so it is unknown, or
# failed when its output says the tool never ran.
_label_sections() {
  [ -s "$report" ] || return 0
  RE="$ANALYZER_CANNOT_RUN_RE" awk '
    function close_section() {
      if (!open || labelled) return
      if (why != "") print "analyzer status: failed — the tool could not run: " why
      else if (!body) print "analyzer status: unknown — the section is empty, and no exit status was recorded"
      else print "analyzer status: unknown — no exit status was recorded (written without _run_analyzer), so its output may be a failure, not a result"
    }
    /^### / { close_section(); open = 1; labelled = 0; body = 0; why = ""; print; next }
    open && /^analyzer status: / { labelled = 1 }
    open && NF { body = 1 }
    open && why == "" && $0 ~ ENVIRON["RE"] { why = $0; sub(/^[ \t]+/, "", why); why = substr(why, 1, 200) }
    { print }
    END { close_section() }' "$report" > "$report.tmp" && mv "$report.tmp" "$report"
}

# True when package.json declares dependencies and none are installed: no
# node_modules, and no Yarn Plug'n'Play map.
_node_deps_missing() {
  [ -f package.json ] && grep -qE '"(devD|d)ependencies"[[:space:]]*:' package.json \
    && [ ! -d node_modules ] && [ ! -f .pnp.cjs ] && [ ! -f .pnp.js ]
}

# --- secrets: shared with the zero-change path in review.sh ----------------
# Branch mode scans each commit in the range as well as the net diff: a secret
# added then removed on the branch is absent from diff.patch but still pushed.
# --remerge-diff: without it `git log -p` prints no patch for a merge, so a secret
# that only merge resolutions add and remove is in no scanned patch. Git < 2.36,
# or a range holding an octopus merge (remerge skips those), falls back to -m,
# which also rescans what each merge brought in from its base.
# rc 3 means leaks. Any other non-zero rc, an ERR/FTL line, or no commits
# scanned when the range adds lines means the scan did not happen — a bad
# --log-opts range logs ERR, then "no leaks found", and exits 0.
# Writes to $report. Returns 0 clean, 3 leaks, 1 scan failed. A failed scan can
# still have found leaks, so rc 3 also sets GITLEAKS_LEAKED.
_gitleaks() { # _gitleaks <label> <min-commits|-> <gitleaks args...>
  local label="$1" min="$2" gl_out gl_rc why="" n; shift 2
  gl_out="$(gitleaks "$@" --no-banner --no-color --redact -v --exit-code 3 2>&1)"; gl_rc=$?
  [ "$gl_rc" != 3 ] || GITLEAKS_LEAKED=1
  gl_out="$(printf '%s\n' "$gl_out" | sed "s/$(printf '\033')\[[0-9;]*m//g")"
  case "$gl_rc" in 0|3) ;; *) why="rc=$gl_rc" ;; esac
  if grep -qE '^[^ ]+ (ERR|FTL) ' <<< "$gl_out"; then
    why="${why:+$why, }gitleaks logged an error"
  fi
  if [ "$min" != "-" ]; then
    n="$(printf '%s\n' "$gl_out" | sed -n 's/.* \([0-9][0-9]*\) commits scanned.*/\1/p' | tail -n 1)"
    if [ -z "$n" ]; then
      why="${why:+$why, }no commit count reported"
    elif [ "$n" -lt "$min" ]; then
      why="${why:+$why, }$n commits scanned"
    fi
  fi
  printf -- '-- %s\n' "$label" >> "$report"
  if [ -z "$why" ]; then
    printf '%s\n' "$gl_out" | head -100 >> "$report"
    if [ "$(printf '%s\n' "$gl_out" | wc -l | tr -d ' ')" -gt 100 ]; then
      printf '… (truncated)\n%s\n' "$(printf '%s\n' "$gl_out" | tail -n +101 | tail -n 3)" >> "$report"
    fi
  else
    printf 'SCAN FAILED (%s) — secrets were NOT checked:\n%s\n' \
      "$why" "$(printf '%s\n' "$gl_out" | head -20)" >> "$report"
    return 1
  fi
  [ "$gl_rc" = 3 ] && return 3
  return 0
}

_gitleaks_history() { # each commit in $MERGE_BASE..HEAD
  local numstat adds head merges=--remerge-diff
  head="$(git rev-parse -q --verify HEAD 2>/dev/null)"
  [ -n "$head" ] && [ "$(git log -1 --format=%H --remerge-diff --no-patch HEAD 2>/dev/null)" = "$head" ] \
    && [ "$(git rev-list --count --min-parents=3 "$MERGE_BASE..HEAD" 2>/dev/null)" = 0 ] || merges=-m
  if ! numstat="$(git log "$merges" --numstat --format= "$MERGE_BASE..HEAD" 2>&1)"; then
    printf -- '-- commit history %s\nSCAN FAILED (git log could not list the range) — secrets were NOT checked:\n%s\n' \
      "$MERGE_BASE..HEAD" "$(printf '%s\n' "$numstat" | head -5)" >> "$report"
    return 1
  fi
  adds="$(printf '%s\n' "$numstat" | awk '$1 ~ /^[0-9]+$/ && $1 > 0 { n = 1 } END { print n + 0 }')"
  _gitleaks "commit history $MERGE_BASE..HEAD" "$adds" \
    detect --source . --log-opts="$merges $MERGE_BASE..HEAD" < /dev/null
}

# A branch whose commits net out to no diff: only the history scan has anything
# to read. Writes <out>/analyzers.txt. Returns as _gitleaks, or 4 if gitleaks is
# not installed.
scan_history_secrets() {
  local report="$1/analyzers.txt"
  GITLEAKS_LEAKED=0
  command -v gitleaks >/dev/null 2>&1 || return 4
  printf '\n### %s\n' "gitleaks (secrets)" > "$report"
  _gitleaks_history
}

# Sets SECRETS_LEAKED and SECRETS_FAILED (0/1) for review.sh, and SECRETS_NOTE
# when secrets were not checked.
collect_analyzer_output() {
  local out="$1"
  local list="$out/changed-files.txt"
  local report="$out/analyzers.txt"
  : > "$report"

  _have() { command -v "$1" >/dev/null 2>&1; }
  _section() { printf '\n### %s\n' "$1" >> "$report"; }

  # --- files by extension, existing only ---
  # The pattern must be a literal like '*.ts|*.tsx'. eval is required: a `|`
  # that arrives via expansion is matched literally, so `case "$f" in $pat)`
  # never matches a multi-alternative pattern on any file without a `|` in
  # its name.
  _files_matching() {
    local pat="$1" f
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      eval "case \"\$f\" in $pat) printf '%s\n' \"\$f\" ;; esac"
    done < "$list"
  }

  SECRETS_FAILED=0 GITLEAKS_LEAKED=0
  _secrets_rc() { case "$1" in 0|3) ;; *) SECRETS_FAILED=1 ;; esac; }
  _section "gitleaks (secrets)"
  if ! _have gitleaks; then
    SECRETS_NOTE="gitleaks is not installed"
    echo "analyzer skipped: gitleaks is not installed — secrets were NOT checked" >> "$report"
  else
    if [ "${MODE:-}" = "branch" ] && [ -n "${MERGE_BASE:-}" ]; then
      _gitleaks_history; _secrets_rc $?
    fi
    if [ -s "$out/diff.patch" ]; then
      _gitleaks "net diff" - detect --pipe < "$out/diff.patch"; _secrets_rc $?
    else
      SECRETS_NOTE="no diff to scan"
      echo "no diff to scan — secrets were NOT checked" >> "$report"
    fi
  fi
  SECRETS_LEAKED="$GITLEAKS_LEAKED"
  if [ "$SECRETS_FAILED" = 1 ]; then _analyzer_status "failed — a gitleaks scan did not complete, so secrets were NOT checked"
  elif [ "$SECRETS_LEAKED" = 1 ]; then _analyzer_status "ran — leaks found"
  elif [ -n "${SECRETS_NOTE:-}" ]; then _analyzer_status "skipped — $SECRETS_NOTE"
  else _analyzer_status "ran — clean"
  fi

  # --- semgrep (multi-language, high signal) ------------------------------
  # With --error, rc 0 is clean and rc 1 is findings; anything else, or output
  # that isn't semgrep's JSON, is a failed scan.
  local sg_list f sg_out sg_rc sg_hits sg_errs sg_status; sg_list="$(_files_matching '*')"
  if [ -n "$sg_list" ] && ! _have semgrep; then
    _section "semgrep --config=auto"
    echo "analyzer skipped: semgrep is not installed" >> "$report"
    _analyzer_status "skipped — semgrep is not installed"
  elif [ -n "$sg_list" ]; then
    _section "semgrep --config=auto"
    local -a sg_files; sg_files=()
    while IFS= read -r f; do sg_files+=("$f"); done <<< "$sg_list"
    sg_out="$(semgrep --config=auto --quiet --error --json "${sg_files[@]}" 2> "$out/semgrep.stderr" < /dev/null)"; sg_rc=$?
    if [ "$sg_rc" -le 1 ] && jq -e 'type == "object" and has("results")' >/dev/null 2>&1 <<< "$sg_out"; then
      sg_hits="$(jq -r '.results[] | "- " + .path + ":" + (.start.line|tostring) + " [" + .check_id + "] " + .extra.message' <<< "$sg_out")"
      if [ -n "$sg_hits" ]; then
        printf '%s\n' "$sg_hits" | head -200 >> "$report"
        sg_status="ran — findings above"
      elif [ "$sg_rc" -eq 0 ]; then
        echo "semgrep: no findings in ${#sg_files[@]} file(s)" >> "$report"
        sg_status="ran — clean"
      else
        echo "semgrep FAILED (rc=1 with no results) — findings were NOT reported" >> "$report"
        sg_status="failed — rc=1 with no results"
      fi
      sg_errs="$(jq -r '.errors[]? | "- " + (.type | tostring) + ": " + ((.message // "") | tostring)' <<< "$sg_out")"
      if [ -n "$sg_errs" ]; then
        printf 'semgrep reported errors — some files or rules were NOT scanned:\n%s\n' \
          "$(printf '%s\n' "$sg_errs" | head -10)" >> "$report"
        sg_status="$sg_status; some files or rules were NOT scanned"
      fi
      _analyzer_status "$sg_status"
    else
      printf 'semgrep FAILED (rc=%s) — files were NOT scanned:\n%s\n' \
        "$sg_rc" "$( { cat "$out/semgrep.stderr"; printf '%s\n' "$sg_out"; } | grep . | head -20)" >> "$report"
      _analyzer_status "failed — rc=$sg_rc, and the output is not semgrep's JSON"
    fi
    rm -f "$out/semgrep.stderr"
  fi

  # --- Shell --------------------------------------------------------------
  # A tool given the changed files as arguments; a missing one is a named skip.
  _run_on_files() { # _run_on_files <title> <findings-ERE> <file list> <command...>
    local title="$1" re="$2" list="$3" f; shift 3
    if ! _have "$1"; then
      _section "$title"; echo "analyzer skipped: $1 is not installed" >> "$report"
      _analyzer_status "skipped — $1 is not installed"
      return
    fi
    local -a files; files=()
    while IFS= read -r f; do files+=("$f"); done <<< "$list"
    _run_analyzer "$title" "$re" "$@" "${files[@]}"
  }

  local sh; sh="$(_files_matching '*.sh|*.bash')"
  [ -z "$sh" ] || _run_on_files shellcheck ':[0-9]+:[0-9]+: ' "$sh" shellcheck -f gcc

  # --- repo-specific stack wiring ------------------------------------------
  # A repo that knows its stack writes .review/analyzers.local.sh (start from
  # templates/analyzers.local.sh in the kit). It runs INSTEAD of the generic
  # per-language stanzas below, with $report, $list and the
  # _have/_section/_files_matching/_run_analyzer helpers in scope.
  if [ -f .review/analyzers.local.sh ]; then
    # shellcheck disable=SC1091
    . .review/analyzers.local.sh
    _label_sections
    if [ ! -s "$report" ]; then rm -f "$report"; fi
    return 0
  fi

  # --- JS / TS ------------------------------------------------------------
  # The runner follows the repo's package manager: npx cannot see binaries a
  # pnpm or yarn workspace keeps out of the root node_modules/.bin. yarn classic
  # and bun call the hoisted binary directly — their `run` prefers a package.json
  # script of the same name. Each tool writes output, a clean line, a named skip,
  # or FAILED: the lenses are told not to re-report what a linter flagged, so an
  # empty section reads as clean.
  _js_runner() { # prints "<runner>|<how it was chosen>"; a runner ending in / is a bin dir
    local pm major src
    pm="$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([a-z]*\)@\([0-9]*\).*/\1 \2/p' package.json | head -n 1)"
    if [ -n "$pm" ]; then
      major="${pm#* }"; pm="${pm%% *}"; src="packageManager field"
    elif [ -f pnpm-lock.yaml ]; then pm=pnpm src=pnpm-lock.yaml
    elif [ -f yarn.lock ]; then
      pm=yarn src=yarn.lock major=1
      if [ -f .yarnrc.yml ] || grep -q '^__metadata:' yarn.lock; then major=2; fi
    elif [ -f bun.lock ] || [ -f bun.lockb ]; then pm=bun src="bun lockfile"
    elif [ -f package-lock.json ]; then pm=npm src=package-lock.json
    else pm=npm src="no lockfile"
    fi
    case "$pm" in
      pnpm) printf 'pnpm exec|%s\n' "$src" ;;
      yarn) if [ "${major:-1}" -ge 2 ] 2>/dev/null; then printf 'yarn exec|%s\n' "$src"
            else printf 'node_modules/.bin/|%s\n' "$src"; fi ;;
      bun)  printf 'node_modules/.bin/|%s\n' "$src" ;;
      *)    printf 'npx --no-install|%s\n' "$src" ;;
    esac
  }

  _js_run() { # _js_run <tool> <args...>
    local tool="$1"; shift
    case "$runner" in
      */) "$runner$tool" "$@" < /dev/null ;;
      *)  # shellcheck disable=SC2086
          $runner "$tool" "$@" < /dev/null ;;
    esac
  }

  # _js_resolve <tool> — true if $runner resolves it; otherwise writes the skip line
  _js_resolve() {
    local why
    case "$runner" in
      */) ;;
      *) if ! _have "${runner%% *}"; then
           echo "analyzer skipped: $1 not run — ${runner%% *} ($runner_src) is not installed" >> "$report"
           _analyzer_status "skipped — ${runner%% *} is not installed"
           return 1
         fi ;;
    esac
    if ! why="$(_js_run "$1" --version 2>&1)"; then
      why="$(printf '%s\n' "$why" | grep . | head -n 1 | cut -c 1-200)"
      echo "analyzer skipped: $1 not resolvable via $runner ($runner_src)${why:+: $why} — workspace-local? wire it in .review/analyzers.local.sh" >> "$report"
      _analyzer_status "skipped — $1 is not resolvable via $runner${why:+: $why}"
      return 1
    fi
  }

  local js; js="$(_files_matching '*.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs')"
  if [ -n "$js" ]; then
    if [ ! -f package.json ]; then
      _section "eslint"
      echo "analyzer skipped: eslint/tsc not run — no package.json at the repo root; wire them in .review/analyzers.local.sh" >> "$report"
      _analyzer_status "skipped — eslint/tsc not run: no package.json at the repo root"
    elif _node_deps_missing; then
      # an unresolved import fails both tools, and npx may fetch a stranger named like the tool
      for f in eslint tsc; do
        [ "$f" = eslint ] || [ -f tsconfig.json ] || [ -n "$(_files_matching '*.ts|*.tsx')" ] || continue
        _section "$f"
        echo "analyzer skipped: $f not run — package.json declares dependencies, but none are installed (no node_modules)" >> "$report"
        _analyzer_status "skipped — dependencies are not installed (no node_modules)"
      done
    else
      local runner runner_src f tool_out tool_rc tsc_args why
      local -a js_files; js_files=()
      runner="$(_js_runner)"; runner_src="${runner#*|}"; runner="${runner%%|*}"
      while IFS= read -r f; do js_files+=("$f"); done <<< "$js"

      _section "eslint"
      if _js_resolve eslint; then
        # no --format flag: eslint 9 removed every non-core formatter, unix included
        tool_out="$(_js_run eslint "${js_files[@]}" 2>&1)"; tool_rc=$?
        why="$(_cannot_run_line "$tool_out")"
        if [ -n "$why" ]; then
          printf 'eslint FAILED (rc=%s) — files were NOT linted:\n%s\n' \
            "$tool_rc" "$(printf '%s\n' "$tool_out" | head -20)" >> "$report"
          _analyzer_status "failed — eslint could not run: $why"
        elif [ "$tool_rc" -eq 0 ]; then
          echo "eslint: no errors in ${#js_files[@]} file(s)" >> "$report"
          [ -z "$tool_out" ] || printf '%s\n' "$tool_out" | head -200 >> "$report"
          _analyzer_status "ran — no errors"
        elif [ "$tool_rc" -eq 1 ] && [ -n "$tool_out" ]; then
          printf '%s\n' "$tool_out" | head -200 >> "$report"
          _analyzer_status "ran — findings above"
        else
          printf 'eslint FAILED (rc=%s) — files were NOT linted:\n%s\n' \
            "$tool_rc" "$(printf '%s\n' "$tool_out" | head -20)" >> "$report"
          if [ -n "$tool_out" ]; then why="output that is not lint findings"; else why="no output"; fi
          _analyzer_status "failed — rc=$tool_rc with $why"
        fi
      fi

      if [ -f tsconfig.json ] || [ -n "$(_files_matching '*.ts|*.tsx')" ]; then
        _section "tsc"
        if [ ! -f tsconfig.json ]; then
          echo "analyzer skipped: tsc not run — no tsconfig.json at the repo root" >> "$report"
          _analyzer_status "skipped — no tsconfig.json at the repo root"
        elif _js_resolve tsc; then
          tsc_args="--noEmit"
          if grep -q '"references"' tsconfig.json && grep -q '"path"' tsconfig.json; then
            tsc_args="--build --noEmit"
          fi
          # shellcheck disable=SC2086
          tool_out="$(_js_run tsc $tsc_args --pretty false 2>&1)"; tool_rc=$?
          why="$(_cannot_run_line "$tool_out")"
          # tsc exits non-zero both for type errors and for never checking: only a
          # located error is a finding, and an unlocated TS error is config.
          # A located error means it ran, whatever else the output says.
          if [ "$tool_rc" -ne 0 ] && grep -q 'error TS5094' <<< "$tool_out"; then
            echo "analyzer skipped: tsc --build --noEmit needs TypeScript >= 5.6 (plain --build writes build output into the tree) — references not type-checked; wire it in .review/analyzers.local.sh" >> "$report"
            _analyzer_status "skipped — tsc --build --noEmit needs TypeScript >= 5.6"
          elif grep -qE '\([0-9]+,[0-9]+\): error TS' <<< "$tool_out"; then
            printf 'tsc %s:\n%s\n' "$tsc_args" "$(printf '%s\n' "$tool_out" | head -100)" >> "$report"
            _analyzer_status "ran — type errors above"
          elif [ -n "$why" ]; then
            printf 'tsc %s FAILED (rc=%s) — types were NOT checked:\n%s\n' \
              "$tsc_args" "$tool_rc" "$(printf '%s\n' "$tool_out" | head -20)" >> "$report"
            _analyzer_status "failed — tsc could not run: $why"
          elif [ "$tool_rc" -eq 0 ]; then
            echo "tsc $tsc_args: no errors" >> "$report"
            [ -z "$tool_out" ] || printf '%s\n' "$tool_out" | head -100 >> "$report"
            _analyzer_status "ran — no errors"
          elif grep -qE '(^|[^)]: )error TS[0-9]+' <<< "$tool_out"; then
            printf 'tsc %s FAILED (rc=%s) — types were NOT checked:\n%s\n' \
              "$tsc_args" "$tool_rc" "$(printf '%s\n' "$tool_out" | head -20)" >> "$report"
            _analyzer_status "failed — rc=$tool_rc with a configuration error and no located type error"
          else
            printf 'tsc %s rc=%s, with neither a located type error nor a known failure — types are UNKNOWN, not clean:\n%s\n' \
              "$tsc_args" "$tool_rc" "$(printf '%s\n' "$tool_out" | head -20)" >> "$report"
            _analyzer_status "unknown — rc=$tool_rc with no located type error"
          fi
        fi
      fi
    fi
  fi

  # --- Python -------------------------------------------------------------
  local py; py="$(_files_matching '*.py')"
  if [ -n "$py" ]; then
    _run_on_files ruff ':[0-9]+:[0-9]+: ' "$py" ruff check --output-format concise
    _run_on_files mypy ':[0-9]+: (error|warning|note): ' "$py" mypy --no-error-summary
    _run_on_files bandit ':[0-9]+: B[0-9]+' "$py" bandit -q -f custom
  fi

  # --- Go -----------------------------------------------------------------
  # one module-wide run each, so a skip names the tool rather than a file
  _run_module() { # _run_module <title> <findings-ERE> <command...>
    if _have "$3"; then _run_analyzer "$@"
    else _section "$1"; echo "analyzer skipped: $3 is not installed" >> "$report"; _analyzer_status "skipped — $3 is not installed"
    fi
  }
  if [ -n "$(_files_matching '*.go')" ]; then
    _run_module "go vet" '\.go:[0-9]+:[0-9]+: ' go vet ./...
    _have go && _run_module staticcheck '\.go:[0-9]+:[0-9]+: ' staticcheck ./...
  fi

  # --- Rust ---------------------------------------------------------------
  [ -z "$(_files_matching '*.rs')" ] \
    || _run_module "cargo clippy" '\.rs:[0-9]+:[0-9]+: (warning|error)' cargo clippy --quiet --message-format short

  # --- Terraform / IaC ----------------------------------------------------
  [ -z "$(_files_matching '*.tf')" ] || _run_module tflint '\.tf:[0-9]+:[0-9]+: ' tflint --format compact

  _label_sections
  if [ ! -s "$report" ]; then rm -f "$report"; fi
  return 0
}
