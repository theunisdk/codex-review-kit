#!/usr/bin/env bash
# Collect cheap static-analysis signal on the changed files and write it to
# .review/raw/analyzers.txt. Every tool is OPTIONAL — a tool that is not
# installed is skipped. The secrets and JS/TS sections are never empty: they
# hold output, a clean line, a named skip, or FAILED. The point is not to gate
# on this output; it is to hand Codex the lint-level noise up front so it spends
# its reasoning budget on semantic bugs a linter structurally cannot find.
#
# This file is synced from the kit — do not edit it in a repo. Wire your own
# stack in .review/analyzers.local.sh instead (repo-owned, never overwritten).

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

  # --- secrets ------------------------------------------------------------
  # Branch mode scans each commit in the range as well as the net diff: a secret
  # added then removed on the branch is absent from diff.patch but still pushed.
  # The net-diff scan stays because `git log -p` shows no content for merges.
  # rc 3 means leaks. Any other non-zero rc, an ERR/FTL line, or no commits
  # scanned when the range adds lines means the scan did not happen — a bad
  # --log-opts range logs ERR, then "no leaks found", and exits 0.
  _gitleaks() { # _gitleaks <label> <min-commits|-> <gitleaks args...>
    local label="$1" min="$2" gl_out gl_rc why="" n; shift 2
    gl_out="$(gitleaks "$@" --no-banner --no-color --redact -v --exit-code 3 2>&1)"; gl_rc=$?
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
        printf '… (truncated)\n%s\n' "$(printf '%s\n' "$gl_out" | tail -n 3)" >> "$report"
      fi
    else
      printf 'SCAN FAILED (%s) — secrets were NOT checked:\n%s\n' \
        "$why" "$(printf '%s\n' "$gl_out" | head -20)" >> "$report"
    fi
  }

  if _have gitleaks; then
    _section "gitleaks (secrets)"
    if [ "${MODE:-}" = "branch" ] && [ -n "${MERGE_BASE:-}" ]; then
      local adds
      adds="$(git log --no-merges --numstat --format= "$MERGE_BASE..HEAD" \
        | awk '$1 ~ /^[0-9]+$/ && $1 > 0 { n = 1 } END { print n + 0 }')"
      _gitleaks "commit history $MERGE_BASE..HEAD" "$adds" \
        detect --source . --log-opts="$MERGE_BASE..HEAD" < /dev/null
    fi
    if [ -s "$out/diff.patch" ]; then
      _gitleaks "net diff" - detect --pipe < "$out/diff.patch"
    else
      echo "no diff to scan — secrets were NOT checked" >> "$report"
    fi
  fi

  # --- semgrep (multi-language, high signal) ------------------------------
  if _have semgrep; then
    _section "semgrep --config=auto"
    # shellcheck disable=SC2046
    semgrep --config=auto --quiet --error --json $(tr '\n' ' ' < "$list") 2>/dev/null \
      | jq -r '.results[]? | "- " + .path + ":" + (.start.line|tostring) + " [" + .check_id + "] " + .extra.message' \
      2>/dev/null | head -200 >> "$report" || true
  fi

  # --- Shell --------------------------------------------------------------
  local sh; sh="$(_files_matching '*.sh|*.bash')"
  if [ -n "$sh" ] && _have shellcheck; then
    _section "shellcheck"
    printf '%s\n' "$sh" | xargs shellcheck -f gcc 2>/dev/null | head -100 >> "$report" || true
  fi

  # --- repo-specific stack wiring ------------------------------------------
  # A repo that knows its stack writes .review/analyzers.local.sh (start from
  # templates/analyzers.local.sh in the kit). It runs INSTEAD of the generic
  # per-language stanzas below, with $report, $list and the
  # _have/_section/_files_matching helpers in scope.
  if [ -f .review/analyzers.local.sh ]; then
    # shellcheck disable=SC1091
    . .review/analyzers.local.sh
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
      # shellcheck disable=SC2086
      *)  $runner "$tool" "$@" < /dev/null ;;
    esac
  }

  # _js_resolve <tool> — true if $runner resolves it; otherwise writes the skip line
  _js_resolve() {
    local why
    case "$runner" in
      */) ;;
      *) if ! _have "${runner%% *}"; then
           echo "analyzer skipped: $1 not run — ${runner%% *} ($runner_src) is not installed" >> "$report"
           return 1
         fi ;;
    esac
    if ! why="$(_js_run "$1" --version 2>&1)"; then
      why="$(printf '%s\n' "$why" | grep . | head -n 1 | cut -c 1-200)"
      echo "analyzer skipped: $1 not resolvable via $runner ($runner_src)${why:+: $why} — workspace-local? wire it in .review/analyzers.local.sh" >> "$report"
      return 1
    fi
  }

  local js; js="$(_files_matching '*.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs')"
  if [ -n "$js" ]; then
    if [ ! -f package.json ]; then
      _section "eslint"
      echo "analyzer skipped: eslint/tsc not run — no package.json at the repo root; wire them in .review/analyzers.local.sh" >> "$report"
    else
      local runner runner_src f tool_out tool_rc tsc_args
      local -a js_files; js_files=()
      runner="$(_js_runner)"; runner_src="${runner#*|}"; runner="${runner%%|*}"
      while IFS= read -r f; do js_files+=("$f"); done <<< "$js"

      _section "eslint"
      if _js_resolve eslint; then
        # no --format flag: eslint 9 removed every non-core formatter, unix included
        tool_out="$(_js_run eslint "${js_files[@]}" 2>&1)"; tool_rc=$?
        if [ "$tool_rc" -eq 0 ]; then
          echo "eslint: no errors in ${#js_files[@]} file(s)" >> "$report"
          [ -z "$tool_out" ] || printf '%s\n' "$tool_out" | head -200 >> "$report"
        elif [ "$tool_rc" -eq 1 ] && [ -n "$tool_out" ]; then
          printf '%s\n' "$tool_out" | head -200 >> "$report"
        else
          printf 'eslint FAILED (rc=%s) — files were NOT linted:\n%s\n' \
            "$tool_rc" "$(printf '%s\n' "$tool_out" | head -20)" >> "$report"
        fi
      fi

      if [ -f tsconfig.json ] || [ -n "$(_files_matching '*.ts|*.tsx')" ]; then
        _section "tsc"
        if [ ! -f tsconfig.json ]; then
          echo "analyzer skipped: tsc not run — no tsconfig.json at the repo root" >> "$report"
        elif _js_resolve tsc; then
          tsc_args="--noEmit"
          if grep -q '"references"' tsconfig.json && grep -q '"path"' tsconfig.json; then
            tsc_args="--build --noEmit"
          fi
          # shellcheck disable=SC2086
          tool_out="$(_js_run tsc $tsc_args --pretty false 2>&1)"; tool_rc=$?
          if [ "$tool_rc" -ne 0 ] && grep -q 'error TS5094' <<< "$tool_out"; then
            # TypeScript < 5.6 rejects --noEmit with --build
            tsc_args="--build"
            tool_out="$(_js_run tsc $tsc_args --pretty false 2>&1)"; tool_rc=$?
          fi
          if [ "$tool_rc" -eq 0 ]; then
            echo "tsc $tsc_args: no errors" >> "$report"
            [ -z "$tool_out" ] || printf '%s\n' "$tool_out" | head -100 >> "$report"
          elif grep -qE '\([0-9]+,[0-9]+\): error TS' <<< "$tool_out"; then
            printf 'tsc %s:\n%s\n' "$tsc_args" "$(printf '%s\n' "$tool_out" | head -100)" >> "$report"
          else
            printf 'tsc %s FAILED (rc=%s) — types were NOT checked:\n%s\n' \
              "$tsc_args" "$tool_rc" "$(printf '%s\n' "$tool_out" | head -20)" >> "$report"
          fi
        fi
      fi
    fi
  fi

  # --- Python -------------------------------------------------------------
  local py; py="$(_files_matching '*.py')"
  if [ -n "$py" ]; then
    if _have ruff; then
      _section "ruff"
      printf '%s\n' "$py" | xargs ruff check --output-format concise 2>/dev/null | head -200 >> "$report" || true
    fi
    if _have mypy; then
      _section "mypy"
      printf '%s\n' "$py" | xargs mypy --no-error-summary 2>/dev/null | head -100 >> "$report" || true
    fi
    if _have bandit; then
      _section "bandit"
      printf '%s\n' "$py" | xargs bandit -q -f custom 2>/dev/null | head -100 >> "$report" || true
    fi
  fi

  # --- Go -----------------------------------------------------------------
  if [ -n "$(_files_matching '*.go')" ] && _have go; then
    _section "go vet"
    go vet ./... 2>&1 | head -100 >> "$report" || true
    _have staticcheck && { _section "staticcheck"; staticcheck ./... 2>&1 | head -100 >> "$report" || true; }
  fi

  # --- Rust ---------------------------------------------------------------
  if [ -n "$(_files_matching '*.rs')" ] && _have cargo; then
    _section "cargo clippy"
    cargo clippy --quiet --message-format short 2>&1 | head -100 >> "$report" || true
  fi

  # --- Terraform / IaC ----------------------------------------------------
  if [ -n "$(_files_matching '*.tf')" ] && _have tflint; then
    _section "tflint"; tflint --format compact 2>&1 | head -80 >> "$report" || true
  fi

  if [ ! -s "$report" ]; then rm -f "$report"; fi
  return 0
}
