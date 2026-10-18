#!/usr/bin/env bash
# Shared helpers. Deliberately POSIX-ish: works on macOS bash 3.2 and Linux.

_c_red=""; _c_yel=""; _c_dim=""; _c_off=""
if [ -t 2 ]; then
  _c_red=$'\033[31m'; _c_yel=$'\033[33m'; _c_dim=$'\033[2m'; _c_off=$'\033[0m'
fi

info() { printf '%s[review]%s %s\n' "$_c_dim" "$_c_off" "$*" >&2; }
warn() { printf '%s[review] warn:%s %s\n' "$_c_yel" "$_c_off" "$*" >&2; }
die()  { printf '%s[review] error:%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not on PATH"
}

# Detect the default base branch: origin/HEAD, else common names, else main.
detect_base_branch() {
  local ref
  ref="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -n "$ref" ]; then
    echo "${ref#refs/remotes/}"; return 0
  fi
  local b
  for b in origin/main origin/master origin/develop main master develop; do
    if git rev-parse --verify "$b" >/dev/null 2>&1; then echo "$b"; return 0; fi
  done
  echo "main"
}

# Will git run .githooks/pre-push on push? Run from the repo root. Sets HOOK_STATE
# (wired|chained|missing|noexec|unset|unset-live|foreign), HOOK_NOTE (what was found)
# and HOOK_FIX (the command that wires it; empty when wired). Returns 1 when unwired.
HOOK_CHAIN='.githooks/pre-push "$@" || exit $?'
hook_wiring() {
  local hooks_path hooks_dir hook user_hook live="" f chain
  HOOK_STATE=""; HOOK_NOTE=""; HOOK_FIX=""
  hooks_path="$(git config --get core.hooksPath 2>/dev/null)"
  hooks_dir="$(git rev-parse --git-path hooks 2>/dev/null)" \
    || { HOOK_STATE=missing; HOOK_NOTE="git could not resolve its hooks directory"; return 1; }
  if [ ! -f .githooks/pre-push ]; then
    HOOK_STATE=missing; HOOK_NOTE=".githooks/pre-push is missing"
    HOOK_FIX="re-sync the kit: scripts/review-update.sh"; return 1
  fi
  if [ ! -x .githooks/pre-push ]; then
    HOOK_STATE=noexec; HOOK_NOTE=".githooks/pre-push is not executable, so git skips it"
    HOOK_FIX="chmod +x .githooks/pre-push"; return 1
  fi
  if [ -d "$hooks_dir" ] && [ "$(cd "$hooks_dir" && pwd -P)" = "$(cd .githooks && pwd -P)" ]; then
    HOOK_STATE=wired; HOOK_NOTE="core.hooksPath = $hooks_path"; return 0
  fi
  hooks_dir="${hooks_dir%/}"; hook="$hooks_dir/pre-push"; user_hook="$hook"
  # husky 9: core.hooksPath is .husky/_, whose stubs run the user's .husky/<hook>
  case "$hooks_dir" in _|*/_) [ -f "$hooks_dir/h" ] && user_hook="${hooks_dir%_}pre-push" ;; esac
  # a chain runs .githooks/pre-push as the line's command; after any exec or exit it is not proven
  # to run, though exec with only redirections returns
  chain=1
  if [ -f "$user_hook" ] && [ ! -r "$user_hook" ]; then
    chain=2
  elif [ -f "$user_hook" ]; then
    awk 'function redirect_only(line,   w, n, i, op) {
        sub(/^[[:space:]]*exec/, "", line); sub(/[[:space:]]#.*$/, "", line)
        n = split(line, w, /[[:space:]]+/); op = 0
        for (i = 1; i <= n; i++) {
          if (w[i] == "") continue
          if (op) { op = 0; continue }
          if (w[i] ~ /^[0-9]*(<|>|>>|<>|>&|<&|>\|)$/) { op = 1; continue }
          if (w[i] !~ /^[0-9]*[<>]/) return 0
        }
        return !op
      }
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*((exec|sh|bash)[[:space:]]+)?(\.\/)?\.githooks\/pre-push([[:space:]]|;|$)/ { found = 1; exit }
      /^[[:space:]]*((exec|sh|bash)[[:space:]]+)?"\$\(git rev-parse --show-toplevel\)\/\.githooks\/pre-push"([[:space:]]|;|$)/ { found = 1; exit }
      /^[[:space:]]*exec([[:space:]]|;|$)/ && redirect_only($0) { next }
      /^[[:space:]]*(exec|exit)([[:space:]]|;|$)/ { blocked = 1; exit }
      END { exit(found ? 0 : blocked ? 3 : 1) }' "$user_hook" 2>/dev/null
    chain=$?
  fi
  if [ "$chain" = 0 ] && [ -x "$hook" ]; then
    HOOK_STATE=chained; HOOK_NOTE="$user_hook chains .githooks/pre-push"; return 0
  fi
  case "$chain" in
    0) HOOK_FIX="chmod +x $(printf %q "$hook")" ;;
    1) if [ -f "$user_hook" ]; then
           HOOK_FIX="printf '\\n%s\\n' '$HOOK_CHAIN' >> $(printf %q "$user_hook")"
         else
           HOOK_FIX="printf '#!/bin/sh\\n%s\\n' '$HOOK_CHAIN' > $(printf %q "$user_hook")"
         fi ;;
    3) HOOK_FIX="add the line  $HOOK_CHAIN  to $user_hook, above its first exec/exit" ;;
  esac
  [ -z "$HOOK_FIX" ] || [ "$chain" = 0 ] || [ "$user_hook" != "$hook" ] || [ -x "$hook" ] \
    || HOOK_FIX="$HOOK_FIX && chmod +x $(printf %q "$hook")"
  if [ -n "$hooks_path" ]; then
    HOOK_STATE=foreign
    HOOK_NOTE="core.hooksPath is '$hooks_path', and its pre-push does not call .githooks/pre-push"
    [ "$chain" != 0 ] || HOOK_NOTE="core.hooksPath is '$hooks_path', and $hook is not executable, so git skips it"
    [ "$chain" != 3 ] || HOOK_NOTE="core.hooksPath is '$hooks_path', and $user_hook can exec or exit before any call to .githooks/pre-push"
    [ "$chain" != 2 ] || HOOK_NOTE="core.hooksPath is '$hooks_path', and $user_hook cannot be read to check that it calls .githooks/pre-push"
    return 1
  fi
  if [ -d "$hooks_dir" ] && [ ! -r "$hooks_dir" ]; then
    HOOK_STATE=unset-live
    HOOK_NOTE="core.hooksPath is unset, and $hooks_dir cannot be listed to rule out live hooks that pointing it at .githooks would disable"
    return 1
  fi
  for f in "$hooks_dir"/*; do
    case "$f" in *.sample) continue ;; esac
    [ -f "$f" ] && [ -x "$f" ] && live="$live ${f##*/}"
  done
  if [ -n "$live" ]; then
    HOOK_STATE=unset-live
    HOOK_NOTE="core.hooksPath is unset, and $hooks_dir has live hooks (${live# }) that pointing it at .githooks would disable — chain the kit's hook from there, or move them into .githooks"
    return 1
  fi
  HOOK_STATE=unset; HOOK_NOTE="core.hooksPath is unset, so git never runs .githooks/pre-push"
  HOOK_FIX="git config core.hooksPath .githooks"
  return 1
}

# Copy the verdicts into the clone's review history: under the git common dir, so
# every worktree shares it, it outlives worktree removal, and it is never committed.
# Keyed <mode>-<date>-<sha>-<cksum>.md, <sha> keeping a code verdict's +uncommitted
# marker: a re-run never duplicates a verdict, and a
# second verdict on the same commit never replaces the first. Run from the repo
# root. Warns on failure; never fails the caller.
archive_verdicts() {
  local f dir="" key target unparsed
  for f in .review/verdict.md .review/spec-verdict.md; do
    [ -f "$f" ] || continue
    if [ -z "$dir" ]; then
      dir="$(git rev-parse --git-common-dir 2>/dev/null)" && dir="$(cd "$dir" 2>/dev/null && pwd -P)" \
        && dir="$dir/review-history" && mkdir -p "$dir" 2>/dev/null && [ -d "$dir" ] && [ -w "$dir" ] \
        || { warn "verdict archive ${dir:-<git common dir>/review-history} is not writable — rejection history for /review-tune is not being kept"; return 0; }
    fi
    key="$(awk -F ' — ' 'NR == 1 {
      sha = $3; sub(/[+]uncommitted$/, "", sha)
      if (NF == 4 && ($1 == "# Review verdict" || $1 == "# Spec verdict") && sha ~ /^[0-9a-f]+$/ \
          && ($3 == sha || $1 == "# Review verdict") && length(sha) >= 4 && length(sha) <= 64 && $4 != "") {
        gsub(/[^A-Za-z0-9-]/, "_", $4)
        print ($1 == "# Spec verdict" ? "spec" : "code") "-" $4 "-" $3
      }
      exit
    }' "$f" 2>/dev/null)"
    unparsed=""
    if [ -z "$key" ]; then
      unparsed=1
      case "$f" in *spec-verdict.md) key="spec-unparsed" ;; *) key="code-unparsed" ;; esac
    fi
    key="$key-$(cksum < "$f" | awk '{ print $1 }')"
    target="$dir/$key.md"
    cmp -s "$f" "$target" 2>/dev/null && continue
    if { cp "$f" "$target.tmp.$$" && mv -f "$target.tmp.$$" "$target"; } 2>/dev/null; then
      [ -z "$unparsed" ] || warn "$f has no standard verdict header — archived as $key.md"
    else
      rm -f "$target.tmp.$$" 2>/dev/null; warn "could not archive $f to $target"
    fi
  done
  return 0
}

# Is release tag $1 older than $2? Both vN.N.N.
release_older() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "${1#v}" "${2#v}" \
    | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "${1#v}" ]
}

# Compare the synced kit (.review/kit-version) with the hub's latest release, as
# `scripts/review-update.sh --latest-release` resolves it. Run from the repo root.
# Sets KIT_STATE (current|behind|newer|unreleased|unsynced|unknown) and KIT_NOTE.
# The lookup is cached under the git common dir — a day when the hub answered, an
# hour when it did not — and capped at about KIT_CHECK_TIMEOUT seconds. Never fails.
KIT_CHECK_TIMEOUT=5
kit_staleness() {
  local f=.review/kit-version tab url installed ref cache now stamp cstate curl cval cinst
  local ttl latest="" why="" out rc dir aged="" ssh_cmd
  KIT_STATE=unknown; KIT_NOTE=""; tab="$(printf '\t')"
  if [ ! -f "$f" ]; then
    KIT_STATE=unsynced; KIT_NOTE="review kit version unknown: no $f (not synced by scripts/review-update.sh)"
    return 0
  fi
  url="$(sed -n 's/^kit: \([^ ]*\) .*/\1/p' "$f" | head -n1)"
  ref="$(sed -n 's/^ref: //p' "$f" | head -n1)"
  installed="$(sed -n 's/^release: //p' "$f" | head -n1)"
  # a kit-version from before release: was recorded names a release only as its ref
  [ -n "$installed" ] || installed="$(printf '%s\n' "$ref" | grep -Ex 'v[0-9]+\.[0-9]+\.[0-9]+')"
  if [ "$installed" = unreleased ]; then
    KIT_STATE=unreleased; KIT_NOTE="review kit is an unreleased sync (${ref:-no ref}) — staleness unknown"
    return 0
  fi
  if ! printf '%s\n' "$installed" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+' || [ -z "$url" ]; then
    KIT_NOTE="review kit staleness unknown: $f names no release (ref: ${ref:-none}) — re-sync with scripts/review-update.sh"
    return 0
  fi

  dir="$(git rev-parse --git-common-dir 2>/dev/null)"; cache="${dir:+$dir/review-kit-latest}"
  now="$(date +%s)"
  if [ -n "$cache" ] && [ -f "$cache" ] && IFS="$tab" read -r stamp cstate curl cval cinst 2>/dev/null < "$cache"; then
    case "$stamp" in ''|*[!0-9]*|?????????????*) stamp=0 ;; esac
    ttl=86400; [ "$cstate" = ok ] || ttl=3600
    if [ "$curl" = "$url" ] && [ "$now" -ge "$stamp" ] && [ $((now - stamp)) -lt "$ttl" ]; then
      aged=" (checked $(( (now - stamp) / 3600 ))h ago)"
      if [ "$cstate" = ok ]; then
        latest="$(printf '%s\n' "$cval" | grep -Ex 'v[0-9]+\.[0-9]+\.[0-9]+')" || latest=""
        # a sync since the cached answer, to a release newer than it, proves it stale
        [ -z "$latest" ] || ! release_older "$latest" "$installed" || [ "$cinst" = "$installed" ] || latest=""
        [ -n "$latest" ] || aged=""
      elif [ "$cstate" = fail ] && [ -n "$cval" ]; then
        why="$cval$aged"
      fi
    fi
  fi
  if [ -z "$latest" ] && [ -z "$why" ]; then
    # an updater from before the flag ignores it and runs a full sync
    if ! grep -q -- '--latest-release)' scripts/review-update.sh 2>/dev/null; then
      why="scripts/review-update.sh is missing or predates --latest-release"
    elif ! out="$(mktemp 2>/dev/null)"; then
      why="no temp file for the lookup"
    else
      ssh_cmd="${GIT_SSH_COMMAND:-$(git config core.sshCommand 2>/dev/null)}"
      run_with_timeout "$KIT_CHECK_TIMEOUT" env GIT_ASKPASS=true GIT_TERMINAL_PROMPT=0 \
        GIT_SSH_COMMAND="${ssh_cmd:-${GIT_SSH:-ssh}} -o BatchMode=yes" REVIEW_KIT_URL="$url" \
        bash scripts/review-update.sh --latest-release > "$out" 2>/dev/null; rc=$?
      latest="$(head -n1 "$out" 2>/dev/null | grep -Ex 'v[0-9]+\.[0-9]+\.[0-9]+')" || latest=""
      rm -f "$out"
      if [ "$rc" != 0 ] || [ -z "$latest" ]; then
        latest=""
        case "$rc" in
          0)       why="the lookup on $url printed no release tag" ;;
          2)       why="$url lists no release tag" ;;
          137|143) why="$url did not answer within ${KIT_CHECK_TIMEOUT}s" ;;
          *)       why="could not reach $url" ;;
        esac
        cstate=fail; cval="$why"
      else
        cstate=ok; cval="$latest"
      fi
      [ -z "$cache" ] || { printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$cstate" "$url" "$cval" "$installed" > "$cache.tmp.$$" \
        && mv -f "$cache.tmp.$$" "$cache"; } 2>/dev/null || rm -f "$cache.tmp.$$" 2>/dev/null
    fi
  fi

  if [ -z "$latest" ]; then
    KIT_NOTE="review kit $installed — staleness unknown: $why"
  elif [ "$installed" = "$latest" ]; then
    KIT_STATE=current; KIT_NOTE="review kit $installed is the latest release$aged"
  elif release_older "$installed" "$latest"; then
    KIT_STATE=behind
    KIT_NOTE="review kit $installed is behind the latest release $latest$aged — sync with scripts/review-update.sh"
  else
    KIT_STATE=newer; KIT_NOTE="review kit $installed is newer than $url's latest release $latest$aged"
  fi
  return 0
}

# Portable timeout: run_with_timeout SECS cmd args...
# (macOS has no coreutils `timeout` by default.)
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  (
    local waited=0
    while [ "$waited" -lt "$secs" ]; do
      kill -0 "$pid" 2>/dev/null || exit 0
      sleep 2; waited=$((waited + 2))
    done
    kill -TERM "$pid" 2>/dev/null
    sleep 5
    kill -KILL "$pid" 2>/dev/null
  ) & local watcher=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill -TERM "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return "$rc"
}

# Make a model's final message parse as JSON, in place.
# Strips markdown fences and any prose before the first '{'. Returns 1 if hopeless.
salvage_json() {
  local f="$1"
  if jq -e . "$f" >/dev/null 2>&1; then return 0; fi
  sed -e 's/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$//' -e 's/^[[:space:]]*```[[:space:]]*$//' \
    "$f" > "$f.strip" 2>/dev/null
  if jq -e . "$f.strip" >/dev/null 2>&1; then mv "$f.strip" "$f"; return 0; fi
  # last resort: take from the first '{' to the last '}'. Buffering to the last line that
  # closes a brace matters — printing to EOF leaves any trailing prose in the payload, so a
  # lens that emitted valid JSON followed by a sentence still failed to parse.
  awk 'BEGIN{s=0;n=0;last=0}
       /\{/ && s==0 {s=1}
       s==1 {buf[n++]=$0; if ($0 ~ /\}/) last=n}
       END{for(i=0;i<last;i++) print buf[i]}' "$f.strip" 2>/dev/null > "$f.brace"
  if jq -e . "$f.brace" >/dev/null 2>&1; then mv "$f.brace" "$f"; rm -f "$f.strip"; return 0; fi
  rm -f "$f.strip" "$f.brace"
  return 1
}
