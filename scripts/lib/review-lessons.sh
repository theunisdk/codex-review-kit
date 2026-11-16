#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# review-lessons.sh — harvest the hub lessons that /review-postmortem proposed
# into `lesson` issues on the kit hub. /review-tune runs it; so does
# /review-postmortem step 6 for one PR.
#
#   ./scripts/lib/review-lessons.sh plan [--pr <n>] [--out <plan.json>]   # dry run
#   ./scripts/lib/review-lessons.sh file <plan.json>                      # file it
#
# `plan` reads every postmortem record in this clone's review history
# (<git common dir>/review-history/postmortem-pr*.md), takes each proposal
# routed to the hub, and drops the ones that are:
#   - harvested: already in the ledger, review-history/lessons-harvested;
#   - filed:     an issue on the hub, open or closed, carries its key;
#   - recorded:  held back, not filed: its record's `lessons` lists issues an
#                interactive postmortem filed, once without the label. `lessons`
#                does not say which proposal each one is, so whoever approves
#                the plan sets it to `duplicate` or `file`; until then every
#                run offers it again and `file` neither files nor ledgers it;
#   - duplicate: an open or closed `lesson` issue already holds the same line
#                (word overlap >= the threshold);
#   - in-hub:    the hub's current version of the file already holds it;
#   - repeated:  another proposal in this run says the same thing.
# What is left is to be filed. It prints the plan and writes it as JSON, to
# --out or a new review-history/lessons-plan-<time>-<pid>.json named on its
# last line; it files nothing and writes no ledger. The plan's `title` and `lines` may be
# edited before `file`, to strip anything that identifies a repo.
#
# Word overlap finds a lesson repeated nearly word for word, not one reworded,
# so whoever approves the plan reads its `file` entries against the existing
# lesson issues and may set an entry's `decision` to `duplicate` (with
# `duplicate_of: {"issue": <n>}`), `in-hub`, `repeated` (with `same_as`),
# `decline` (never file it), or `skip`
# (not this time: it comes back next run).
#
# `file` takes a per-clone lock, re-reads the hub's `lesson` issues, files
# each entry still marked `file` whose key no issue carries yet, and appends
# every other entry's outcome but `skip` to the ledger, so a second run files
# nothing new. Each
# issue's body ends in `<!-- review-lesson: <key> -->`, which is how every
# clone sees it.
#
# The first line of output is the status:
#   review-lessons: plan — …       (exit 0; exit 2 when a record was unread)
#   review-lessons: filed — …      (exit 0)
#   review-lessons: no-history — … (exit 0: no review history in this clone)
#   review-lessons: failed — <step>: <error>   (exit 1; nothing filed after it)
# A lookup that fails never reads as "no issues" or "no records": a failed
# issue list, label check or hub-file read stops the run before any filing.
#
# Env: REVIEW_KIT_REPO (the hub, owner/name; default theunisdk/codex-review-kit),
# REVIEW_LESSONS_HISTORY (the review-history dir; default the clone's),
# REVIEW_LESSONS_THRESHOLD (word overlap that makes a duplicate; default 0.5).
# ---------------------------------------------------------------------------
set -uo pipefail

HUB="${REVIEW_KIT_REPO:-theunisdk/codex-review-kit}"
THRESHOLD="${REVIEW_LESSONS_THRESHOLD:-0.5}"
LABEL="lesson"

fail() { printf 'review-lessons: failed — %s\n' "$*"; exit 1; }
usage() { sed -n '7,8p' "$0" | sed 's/^# *//' >&2; exit 64; }

command -v jq >/dev/null 2>&1 || fail "setup: jq is not on PATH"
command -v gh >/dev/null 2>&1 || fail "setup: gh (GitHub CLI) is not on PATH"
printf '%s\n' "$HUB" | grep -Eqx '[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' || fail "setup: REVIEW_KIT_REPO '$HUB' is not owner/name"
printf '%s\n' "$THRESHOLD" | grep -Eqx '0?\.[0-9]+|1(\.0+)?' && awk -v t="$THRESHOLD" 'BEGIN { exit !(t + 0 > 0) }' \
  || fail "setup: REVIEW_LESSONS_THRESHOLD '$THRESHOLD' is not a number in (0, 1]"

if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum | cut -c1-16; }
elif command -v shasum >/dev/null 2>&1; then sha() { shasum -a 256 | cut -c1-16; }
else fail "setup: neither sha256sum nor shasum is on PATH"; fi

TMP="$(mktemp -d)" || fail "setup: no temp dir"
LOCK=""
trap 'rm -rf "$TMP"; [ -z "$LOCK" ] || rmdir "$LOCK" 2>/dev/null' EXIT

history_dir() {
  if [ -n "${REVIEW_LESSONS_HISTORY:-}" ]; then printf '%s\n' "$REVIEW_LESSONS_HISTORY"; return 0; fi
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  printf '%s/review-history\n' "$common"
}

# The ledger: one line per harvested key, "<key>\t<outcome>\t<UTC time>".
read_ledger() { # read_ledger <hist> — keys on stdout; non-zero if it exists and cannot be read
  local f="$1/lessons-harvested"
  [ -e "$f" ] || return 0
  [ -f "$f" ] && [ -r "$f" ] || return 1
  cut -f1 "$f"
}

# Every `lesson` issue, open and closed, as [{number,title,body,url,state}].
fetch_issues() { # fetch_issues <out>
  local n
  gh issue list -R "$HUB" --label "$LABEL" --state all --limit 1000 \
     --json number,title,body,url,state > "$1" 2> "$TMP/issues.err" \
    || { printf '%s' "$(head -n1 "$TMP/issues.err" | cut -c1-200)"; return 1; }
  n="$(jq -e 'if type == "array" then length else error("not a list") end' "$1" 2>/dev/null)" \
    || { printf 'gh issue list returned something other than a list'; return 1; }
  # --limit is a cap, not a page: at the cap, older issues may be missing
  [ "$n" -lt 1000 ] || { printf 'gh issue list hit its 1000-issue cap; older lesson issues would be unseen'; return 1; }
}

hub_file_path() { # the hub path a proposal's `file` names
  case "$1" in
    .review/*) printf '%s\n' "$1" ;;
    learnings-shared.md|prompts/*) printf '.review/%s\n' "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# --- plan -------------------------------------------------------------------
cmd_plan() {
  local pr="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) [ $# -ge 2 ] || usage; pr="$2"; shift 2 ;;
      --out) [ $# -ge 2 ] || usage; out="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -z "$pr" ] || printf '%s\n' "$pr" | grep -Eqx '[0-9]+' || fail "args: --pr '$pr' is not a PR number"

  local hist; hist="$(history_dir)" || fail "history: not in a git clone, and REVIEW_LESSONS_HISTORY is unset"
  if [ ! -e "$hist" ]; then
    printf 'review-lessons: no-history — %s does not exist; nothing to harvest\n' "$hist"; exit 0
  fi
  [ -d "$hist" ] && [ -r "$hist" ] && [ -x "$hist" ] || fail "history: $hist is not a readable directory"
  [ -n "$out" ] || out="$hist/lessons-plan-$(TZ=UTC0 date +%Y%m%dT%H%M%SZ)-$$.json"

  # Records: each one's JSON block, or a reason it could not be read.
  local recs="$TMP/records.jsonl" unread="$TMP/unread" f j nrec=0
  : > "$recs"; : > "$unread"
  local list; list="$(find "$hist" -maxdepth 1 -name 'postmortem-pr*.md' -type f)" || fail "history: cannot list $hist"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$(basename "$f")" in postmortem-pr[0-9]*.md) ;; *) continue ;; esac
    if [ -n "$pr" ] && [ "$(basename "$f")" != "postmortem-pr$pr.md" ]; then continue; fi
    nrec=$((nrec + 1))
    [ -r "$f" ] || { printf '%s\tunreadable\n' "$f" >> "$unread"; continue; }
    j="$(awk '/^```json[[:space:]]*$/ && !done { inb = 1; next }
              inb && /^```[[:space:]]*$/ { inb = 0; done = 1; next }
              inb { print }' "$f")"
    [ -n "$j" ] || { printf '%s\tno JSON block\n' "$f" >> "$unread"; continue; }
    printf '%s\n' "$j" | jq -ce --arg f "$f" '
        select(.schema == "review-postmortem/v1")
        | if ((.proposals // []) | type == "array") and ((.lessons // []) | type == "array")
          then {file: $f, pr, proposals: (.proposals // []), lessons: (.lessons // [])}
          else error("proposals or lessons is not a list") end' >> "$recs" 2>/dev/null \
      || printf '%s\tJSON does not parse or is not a review-postmortem/v1 record\n' "$f" >> "$unread"
  done <<EOF
$list
EOF
  if [ -n "$pr" ] && [ "$nrec" -eq 0 ]; then
    printf 'review-lessons: no-history — no postmortem record for PR #%s in %s\n' "$pr" "$hist"; exit 0
  fi

  # Hub proposals, keyed by their normalised file and lines.
  local props="$TMP/props.jsonl" k p
  : > "$props"
  jq -sc 'sort_by(.pr | numbers) | .[] | . as $r | .proposals[] | select(type == "object" and .route == "hub")
         | {pr: $r.pr, record: $r.file, recorded: $r.lessons, file: (.file // "" | tostring),
            lines: (.lines // "" | tostring), cause: (.cause // "" | tostring)}' "$recs" > "$TMP/raw.jsonl" \
    || fail "records: cannot read the proposals"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    f="$(hub_file_path "$(printf '%s' "$p" | jq -r .file)")" || fail "records: cannot read a proposal"
    # the path reaches `gh api`: a hub file path, never an API path of its own
    if ! printf '%s\n' "$f" | grep -Eqx '[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*' || printf '%s\n' "$f" | grep -q '\.\.'; then
      printf '%s\tskipped a hub proposal whose file is not a hub path: %s\n' "$(printf '%s' "$p" | jq -r .record)" "$f" >> "$unread"; continue
    fi
    if [ -z "$(printf '%s' "$p" | jq -r '.lines | gsub("\\s"; "")')" ]; then
      printf '%s\tskipped a hub proposal with no lines for %s\n' "$(printf '%s' "$p" | jq -r .record)" "$f" >> "$unread"; continue
    fi
    k="$(printf '%s' "$p" | jq -r --arg f "$f" '$f + "\n" + (.lines | ascii_downcase | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" "))' | sha)" \
      || fail "records: cannot key a proposal"
    printf '%s' "$p" | jq -c --arg k "$k" --arg f "$f" '. + {key: $k, file: $f}' >> "$props" || fail "records: cannot key a proposal"
  done < "$TMP/raw.jsonl"

  local ledger; ledger="$(read_ledger "$hist")" || fail "ledger: $hist/lessons-harvested exists but cannot be read"
  printf '%s\n' "$ledger" | jq -R . | jq -s 'map(select(length > 0))' > "$TMP/ledger.json" || fail "ledger: cannot parse it"

  local err
  err="$(fetch_issues "$TMP/issues.json")" || fail "issues: $err"

  # The hub's current version of each file a proposal names.
  jq -n '{}' > "$TMP/hubfiles.json"
  local paths hp body
  paths="$(jq -r .file "$props" | sort -u)" || fail "records: cannot list the hub files"
  while IFS= read -r hp; do
    [ -n "$hp" ] || continue
    if body="$(gh api -H 'Accept: application/vnd.github.raw' "repos/$HUB/contents/$hp" 2> "$TMP/hub.err")"; then
      jq --arg p "$hp" --arg b "$body" '. + {($p): $b}' "$TMP/hubfiles.json" > "$TMP/hf" && mv "$TMP/hf" "$TMP/hubfiles.json" \
        || fail "hub file: cannot store $hp"
    elif grep -q 'HTTP 404' "$TMP/hub.err"; then
      jq --arg p "$hp" '. + {($p): null}' "$TMP/hubfiles.json" > "$TMP/hf" && mv "$TMP/hf" "$TMP/hubfiles.json" \
        || fail "hub file: cannot store $hp"
    else
      fail "hub file: gh api $hp: $(head -n1 "$TMP/hub.err" | cut -c1-200)"
    fi
  done <<EOF
$paths
EOF

  jq -s --slurpfile issues "$TMP/issues.json" --slurpfile ledger "$TMP/ledger.json" \
        --slurpfile hub "$TMP/hubfiles.json" --argjson t "$THRESHOLD" \
        --arg hubrepo "$HUB" --arg hist "$hist" --rawfile unread "$unread" --argjson nrec "$nrec" '
    def stop: {"that":1,"this":1,"with":1,"when":1,"from":1,"into":1,"than":1,"then":1,"them":1,
               "they":1,"their":1,"there":1,"what":1,"which":1,"where":1,"while":1,"each":1,"every":1,
               "only":1,"also":1,"does":1,"have":1,"been":1,"before":1,"after":1,"over":1,"must":1,
               "should":1,"would":1,"could":1,"other":1,"same":1,"just":1,"like":1,"such":1,"some":1,
               "flag":1,"check":1,"watch":1,"hunt":1,"specifically":1,"suppress":1,"stack":1};
    def toks: ascii_downcase | [scan("[a-z][a-z0-9_]{3,}")] | map(select(stop[.] | not)) | unique;
    def jac($a; $b): if ($a | length) == 0 or ($b | length) == 0 then 0
                     else (($a - ($a - $b)) | length) / (($a + $b | unique) | length) end;
    def blocks: [scan("(?s)```[^\n]*\n(.*?)```") | .[0]] | join("\n");
    def lens($f): if $f | test("^\\.review/prompts/[^/]+\\.md$") then $f | sub("^\\.review/prompts/"; "") | sub("\\.md$"; "")
                  else $f | sub("^.*/"; "") | sub("\\.md$"; "") end;
    def summary: gsub("\\s+"; " ")
                 | sub("^\\s*(##\\s*)?(WATCH|SUPPRESS)\\b[^A-Za-z]*"; ""; "i")
                 | sub("^\\s*Hunt specifically for:?\\s*"; ""; "i")
                 | sub("^[-:—–\\s]+"; "")
                 | (split(". ")[0] | rtrimstr("."))
                 | if length > 90 then .[0:90] | sub(" [^ ]*$"; "") + "…" else . end;
    ($issues[0] | map(. + {toks: ((if (.body | blocks) != "" then .body | blocks else .title + "\n" + .body end) | toks),
                           keys: [.body | scan("<!-- review-lesson: ([0-9a-f]{16}) -->") | .[0]]})) as $iss
    | ($hub[0] | with_entries(.value |= if . == null then null
          else [split("\n") | foreach (.[], "- ") as $l ({cur: "", out: null};
                 if ($l | test("^(- |## |#)")) then {cur: $l, out: .cur} else {cur: (.cur + " " + $l), out: null} end;
                 .out) | select(. != null and . != "") | toks] end)) as $hubtoks
    | ($ledger[0] | map({(.): true}) | add // {}) as $done
    | reduce .[] as $p ({entries: [], seen: {}};
        if .seen[$p.key] then
          .entries |= map(if .key == $p.key
                          then .prs += [$p.pr] | .prs |= unique | .recorded = (.recorded + $p.recorded | unique)
                               | if .decision == "file" and (.recorded | length) > 0 then .decision = "recorded" else . end
                          else . end)
        else
          ($p.lines | toks) as $pt
          | ($iss | map(select(.keys | index($p.key)))[0]) as $marked
          | ([$iss[] | {issue: .number, url, state, score: jac($pt; .toks)}] | max_by(.score)) as $near
          | ([($hubtoks[$p.file] // [])[] | jac($pt; .)] | max // 0) as $inhub
          | ([.entries[] | select(.decision == "file") | {key, score: jac($pt; (.lines | toks))}] | max_by(.score)) as $twin
          | .seen[$p.key] = true
          | .entries += [{key: $p.key, file: $p.file, lens: lens($p.file), cause: $p.cause, lines: $p.lines,
                          title: ("lesson(" + lens($p.file) + "): " + ($p.lines | summary)),
                          prs: [$p.pr], nearest: $near,
                          hub_file_missing: ($hub[0] | has($p.file) and .[$p.file] == null),
                          decision: (if $done[$p.key] then "harvested"
                                     elif $marked then "filed"
                                     elif ($p.recorded | length) > 0 then "recorded"
                                     elif ($near.score // 0) >= $t then "duplicate"
                                     elif $inhub >= $t then "in-hub"
                                     elif ($twin.score // 0) >= $t then "repeated"
                                     else "file" end),
                          duplicate_of: (if $marked then {issue: $marked.number, url: $marked.url}
                                         elif ($near.score // 0) >= $t then $near else null end),
                          hub_score: $inhub,
                          same_as: (if ($twin.score // 0) >= $t then $twin.key else null end),
                          recorded: $p.recorded}]
        end)
    | {schema: "review-lessons/v1", hub: $hubrepo, history: $hist, threshold: $t,
       records: $nrec, unread: ($unread | split("\n") | map(select(length > 0) | split("\t") | {file: .[0], why: .[1]})),
       entries: .entries}
  ' "$props" > "$TMP/plan.json" || fail "plan: jq could not build the plan"

  cp "$TMP/plan.json" "$out.tmp.$$" && mv -f "$out.tmp.$$" "$out" || { rm -f "$out.tmp.$$"; fail "plan: cannot write $out"; }

  jq -r '
    def n($d): [.entries[] | select(.decision == $d)] | length;
    "review-lessons: plan — records \(.records) (unread \(.unread | length)), hub proposals \([.entries[].prs | length] | add // 0) (distinct \(.entries | length)): harvested \(n("harvested")), filed \(n("filed")), recorded \(n("recorded")), duplicate \(n("duplicate")), in-hub \(n("in-hub")), repeated \(n("repeated")), to file \(n("file"))",
    (.unread[] | "unread \(.file): \(.why)"),
    (.entries[] | select(.decision == "file")
      | "file      \(.key) \(.title)  [PR \(.prs | map("#\(.)") | join(" "))]"
        + (if .nearest then "  nearest #\(.nearest.issue) \(.nearest.score * 100 | floor)%" else "" end)
        + (if .hub_file_missing then "  (hub has no \(.file))" else "" end)),
    (.entries[] | select(.decision == "duplicate" or .decision == "filed")
      | "\(.decision) \(.key) = #\(.duplicate_of.issue)" + (if .duplicate_of.score then " \(.duplicate_of.score * 100 | floor)%" else "" end) + "  \(.title)"),
    (.entries[] | select(.decision == "recorded") | "recorded  \(.key) its record lists \(.recorded | map(tostring) | join(" "))  \(.title)"),
    (.entries[] | select(.decision == "in-hub") | "in-hub    \(.key) \(.hub_score * 100 | floor)% in \(.file)  \(.title)"),
    (.entries[] | select(.decision == "repeated") | "repeated  \(.key) = \(.same_as)  \(.title)")
  ' "$out" || fail "plan: cannot print $out"
  echo "plan written: $out"
  [ ! -s "$unread" ] || exit 2
  exit 0
}

# --- file -------------------------------------------------------------------
cmd_file() {
  [ $# -eq 1 ] || usage
  local plan="$1"
  jq -e '.schema == "review-lessons/v1" and (.entries | type == "array")' "$plan" >/dev/null 2>&1 \
    || fail "plan: $plan is not a review-lessons/v1 plan"
  [ "$(jq -r .hub "$plan")" = "$HUB" ] || fail "plan: $plan was made for $(jq -r .hub "$plan"), not $HUB"
  local hist; hist="$(jq -r .history "$plan")"
  [ -d "$hist" ] && [ -w "$hist" ] || fail "ledger: $hist is not a writable directory"
  local ledger="$hist/lessons-harvested"
  # one filer per clone: two worktrees filing at once would both see a key unfiled
  mkdir "$hist/.lessons-lock" 2>/dev/null \
    || fail "lock: another harvest is filing from this clone (if none is, remove $hist/.lessons-lock)"
  LOCK="$hist/.lessons-lock"
  read_ledger "$hist" > "$TMP/ledger" || fail "ledger: $ledger exists but cannot be read"

  # The label lookup reads the same list the dedupe reads: an issue filed
  # without it would be invisible to the next run's dedupe, so never file one.
  local labels
  labels="$(gh label list -R "$HUB" --search "$LABEL" --json name -q '.[].name' 2> "$TMP/label.err")" \
    || fail "label: gh label list: $(head -n1 "$TMP/label.err" | cut -c1-200)"
  if ! printf '%s\n' "$labels" | grep -qFx "$LABEL"; then
    gh label create "$LABEL" -R "$HUB" --description "Review lesson routed from a spoke" > /dev/null 2> "$TMP/label.err" \
      || fail "label: gh label create $LABEL: $(head -n1 "$TMP/label.err" | cut -c1-200)"
  fi

  local err
  err="$(fetch_issues "$TMP/issues.json")" || fail "issues: $err"

  local now filed=0 marked=0 skipped=0 e k decision title url
  now="$(TZ=UTC0 date +%Y-%m-%dT%H:%M:%SZ)"
  jq -c '.entries[]' "$plan" > "$TMP/entries.jsonl" || fail "plan: cannot read its entries"
  while IFS= read -r e; do
    k="$(printf '%s' "$e" | jq -r .key)"; decision="$(printf '%s' "$e" | jq -r .decision)"
    printf '%s\n' "$k" | grep -Eqx '[0-9a-f]{16}' || fail "plan: entry key '$k' is not a key"
    if grep -qFx "$k" "$TMP/ledger"; then skipped=$((skipped + 1)); continue; fi
    url="$(jq -r --arg k "$k" '[.[] | select(.body | contains("<!-- review-lesson: " + $k + " -->"))][0].url // empty' "$TMP/issues.json")"
    if [ -n "$url" ]; then decision="filed"; fi
    case "$decision" in
      file)
        title="$(printf '%s' "$e" | jq -r .title)"
        printf '%s' "$e" | jq -r '
          def cause: {"wrong_lens": "wrong lens — no lens whose scope covers this defect class read the code",
                      "tracing": "insufficient tracing — the right lens read the code and reported nothing on it"}[.] // .;
          "Routed from a spoke'"'"'s `/review-postmortem`, harvested by `/review-tune`.\n\n"
          + "**Hub file:** `\(.file)`\n\n**Proposed lines:**\n\n```markdown\n\(.lines)\n```\n\n"
          + "**Defect class:** \(.title | sub("^lesson\\([^)]*\\): "; ""))\n\n"
          + "**Cause:** \(.cause | cause)\n\n"
          + "**Seen in:** \(.prs | length) postmortem record(s) in one spoke.\n\n"
          + "<!-- review-lesson: \(.key) -->"' > "$TMP/body.md" || fail "file: cannot write the body for $k"
        url="$(gh issue create -R "$HUB" --label "$LABEL" --title "$title" --body-file "$TMP/body.md" 2> "$TMP/create.err")" \
          || { cp "$TMP/body.md" "$hist/lesson-$k.md" 2>/dev/null
               fail "file: gh issue create for $k: $(head -n1 "$TMP/create.err" | cut -c1-200) (filed $filed before it; body saved to $hist/lesson-$k.md)"; }
        printf '%s\tfiled %s\t%s\n' "$k" "${url:-(gh printed no URL)}" "$now" >> "$ledger" \
          || fail "ledger: filed $url but cannot record $k in $ledger — add it by hand, or the next run files it again"
        printf 'filed     %s %s\n' "$k" "$url" >> "$TMP/report"
        filed=$((filed + 1)) ;;
      filed|duplicate|in-hub|repeated|decline)
        local why
        why="$(printf '%s' "$e" | jq -r --arg d "$decision" --arg u "$url" '
          if $d == "filed" then "filed " + (if $u != "" then $u else .duplicate_of.url end)
          elif $d == "duplicate" then "duplicate " + (.duplicate_of.url // ("#" + (.duplicate_of.issue | tostring)))
          elif $d == "in-hub" then "in-hub " + .file
          elif $d == "decline" then "declined"
          else "repeated " + (.same_as // "?") end')" || fail "plan: cannot read entry $k"
        printf '%s\t%s\t%s\n' "$k" "$why" "$now" >> "$ledger" || fail "ledger: cannot record $k in $ledger"
        marked=$((marked + 1)) ;;
      harvested|skip|recorded) skipped=$((skipped + 1)) ;;
      *) fail "plan: entry $k has unknown decision '$decision'" ;;
    esac
  done < "$TMP/entries.jsonl"
  printf 'review-lessons: filed — %d issue(s) filed, %d marked harvested without filing, %d already harvested or skipped\n' \
    "$filed" "$marked" "$skipped"
  [ ! -f "$TMP/report" ] || cat "$TMP/report"
  exit 0
}

case "${1:-}" in
  plan) shift; cmd_plan "$@" ;;
  file) shift; cmd_file "$@" ;;
  *) usage ;;
esac
