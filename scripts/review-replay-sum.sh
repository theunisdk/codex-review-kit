#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# review-replay-sum.sh — one scorecard across several review-replay runs,
# from one spoke or many.
#
# Hub only. Reads the aggregate.json each run of scripts/review-replay.sh
# keeps under <spoke's git common dir>/review-replay/runs/<time>-<kit>/, and
# prints the same scorecard over all of them, each lesson named by repo#PR.
#
#   scripts/review-replay-sum.sh <run dir | aggregate.json>...
#     --json            print the combined scorecard as JSON instead
#     --aliases <file>  name each repo by its alias, and print lessons as counts
#                       only, so the output is safe to paste into the public hub.
#                       One "<owner/repo> <alias>" per line; # starts a comment.
#                       A repo the file does not cover is refused, and errors
#                       name each run by its argument number, not its path.
#
# Refuses, rather than sums: a run that stopped before its scorecard, one made
# by an older review-replay.sh, the same run twice, a PR scored in two runs,
# and runs of different kits. Exit: 0 summed · 1 refused · 64 usage
# ---------------------------------------------------------------------------
set -uo pipefail

HUB="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=lib/common.sh
. "$HUB/scripts/lib/common.sh"

usage() { sed -n '2,21p' "$0" >&2; exit 64; }

JSON=""; ALIASES=""; RUNS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json)    JSON=1 ;;
    --aliases) [ $# -ge 2 ] || { echo "error: --aliases needs a file" >&2; usage; }
               ALIASES="$2"; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    -*)        echo "error: unknown flag: $1" >&2; usage ;;
    *)         RUNS+=("$1") ;;
  esac
  shift
done
[ "${#RUNS[@]}" -gt 0 ] || { echo "error: name at least one run directory or aggregate.json" >&2; usage; }
need_cmd jq

TMP="$(mktemp -d)" || die "no temp dir"
trap 'rm -rf "$TMP"' EXIT
# jq's own errors quote the values they choke on, which may be spoke code
if [ -n "$ALIASES" ]; then jqq() { jq "$@" 2> /dev/null; }; else jqq() { jq "$@"; }; fi

# {"owner/repo" (lower case): alias}; the alias must not be able to carry a repo name
if [ -n "$ALIASES" ]; then
  [ -f "$ALIASES" ] && [ -r "$ALIASES" ] || die "cannot read the alias file $ALIASES"
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$ALIASES" | grep . > "$TMP/aliases.txt"
  [ $? -le 1 ] || die "cannot read the alias file $ALIASES"
  [ -s "$TMP/aliases.txt" ] || die "the alias file $ALIASES names no repo"
  bad="$(grep -vnE '^[^/[:space:]]+/[^/[:space:]]+[[:space:]]+[A-Za-z0-9_-]+$' "$TMP/aliases.txt" | head -n1)"
  [ -z "$bad" ] || die "alias file line is not \"<owner/repo> <alias>\" with a letters, digits, _ or - alias: ${bad%%:*} (comments and blank lines not counted)"
  jq -R -s 'split("\n") | map(select(. != "") | [splits("[[:space:]]+")] | {key: (.[0] | ascii_downcase), value: .[1]})
    | if (map(.key) | unique | length) != length then error("a repo is named twice")
      elif (map(.value | ascii_downcase) | unique | length) != length then error("two repos share an alias")
      else from_entries end' "$TMP/aliases.txt" > "$TMP/aliases.json" 2> "$TMP/aliases.err" \
    || die "bad alias file $ALIASES: $(sed 's/^jq: error[^:]*: //' "$TMP/aliases.err" | head -n1)"
fi

: > "$TMP/runs.all"; i=0
for r in "${RUNS[@]}"; do
  i=$((i + 1))
  f="$r"; [ ! -d "$r" ] || f="$r/aggregate.json"
  # a spoke's path names it, so aliased output never prints one
  lbl="$f" rl="$r"; [ -z "$ALIASES" ] || { lbl="argument $i"; rl="$lbl"; }
  if [ ! -e "$f" ]; then
    [ -d "$r" ] && [ -e "$r/summary.txt" ] \
      && die "$rl has no aggregate.json: the run stopped before its scorecard (see its summary.txt)"
    die "$lbl does not exist"
  fi
  [ -f "$f" ] && [ -r "$f" ] || die "$lbl cannot be read"
  jqq -e 'type == "object" and (.schema | type) == "string"' < "$f" > /dev/null 2>&1 || die "$lbl is not a replay run's aggregate"
  schema="$(jqq -r .schema < "$f")"
  [ "$schema" = review-replay-run/v2 ] \
    || die "$lbl is $schema, not review-replay-run/v2: an older review-replay.sh wrote it, without its incomplete PRs and denied commands — re-run it"
  jqq -e '(.spoke | type) == "string" and (.run | type) == "string"' < "$f" > /dev/null || die "$lbl names no spoke or run, so it cannot be told apart from another run"
  jqq -c --arg path "$lbl" '{path: $path, run, spoke, repo, kit, prs, cost, denials, records: [.repo as $r | .records[] | . + {repo: $r}]}' \
    < "$f" >> "$TMP/runs.all" \
    || die "cannot read $lbl"
done
jqq -s . "$TMP/runs.all" > "$TMP/runs.json" || die "cannot read the runs back"

# before the refusals below, which name repos
if [ -n "$ALIASES" ]; then
  jqq -r --slurpfile a "$TMP/aliases.json" '[.[].repo | select(($a[0][ascii_downcase] // null) == null)] | unique | .[]' \
    "$TMP/runs.json" > "$TMP/unaliased" || die "cannot check the runs against the alias file"
  [ ! -s "$TMP/unaliased" ] \
    || die "the alias file covers no alias for $(grep -c . < "$TMP/unaliased") repo(s) in these runs; run without --aliases to see which"
  jqq --slurpfile a "$TMP/aliases.json" 'map(.repo = $a[0][.repo | ascii_downcase] | .records |= map(.repo = $a[0][.repo | ascii_downcase]))' \
    "$TMP/runs.json" > "$TMP/runs.aliased" && mv "$TMP/runs.aliased" "$TMP/runs.json" || die "cannot alias the runs"
fi

# what would be counted twice, or mixes kits
# a run is its spoke's; GitHub names are case-insensitive
jqq -r '(group_by("\(.spoke) \(.run)") | map(select(length > 1)) | .[] | "the same run twice: \(map(.path) | join(", "))"),
  ([.[] | .run as $run | .records[] | {key: "\(.repo | ascii_downcase)#\(.pr)", run: $run}] | group_by(.key) | map(select(length > 1)) | .[]
    | "\(.[0].key) is scored in more than one run (\(map(.run) | join(", "))): pass one of them"),
  (map(.kit.sha) | unique | select(length > 1) | "runs of different kits (\(map(.[0:7]) | join(", "))) do not sum to one kit'"'"'s scorecard")' \
  "$TMP/runs.json" > "$TMP/refused" || die "cannot check the runs"
[ ! -s "$TMP/refused" ] || die "$(head -n1 "$TMP/refused")"

SCORE=(jqq -L "$HUB/scripts/lib")
"${SCORE[@]}" 'include "replay-scorecard";
  def total(p): map(p) | add;
  {schema: "review-replay-sum/v1", kit: .[0].kit,
   runs: map({run, spoke, repo, path, prs}),
   prs: {replayed: total(.prs.replayed), incomplete: total(.prs.incomplete), skipped: total(.prs.skipped),
         failed: total(.prs.failed), unreviewed_passed_over: total(.prs.unreviewed_passed_over)}}
  + (map(.records[]) | tally)
  + {cost: {claude_usd: total(.cost.claude_usd), claude_calls_of_unknown_cost: total(.cost.claude_calls_of_unknown_cost),
            codex_tokens: total(.cost.codex_tokens), prs_of_unknown_codex_tokens: total(.cost.prs_of_unknown_codex_tokens)},
     denials: {commands: total(.denials.commands), prs_with_denials: total(.denials.prs_with_denials),
               prs_of_unknown_denials: total(.denials.prs_of_unknown_denials)},
     records: map(.records[])}' "$TMP/runs.json" > "$TMP/sum.json" || die "cannot sum the runs"

# aliased: no spoke path, no record, and lessons as counts — what each finding quotes is spoke code
if [ -n "$ALIASES" ]; then
  "${SCORE[@]}" 'include "replay-scorecard";
    del(.records) + {runs: (.runs | map(del(.spoke, .path))), lessons: (.records | lesson_counts("\(.repo) #\(.pr)"))}' \
    "$TMP/sum.json" > "$TMP/sum.aliased" && mv "$TMP/sum.aliased" "$TMP/sum.json" || die "cannot alias the scorecard"
fi

if [ -n "$JSON" ]; then cat "$TMP/sum.json"; exit 0; fi
"${SCORE[@]}" -r 'include "replay-scorecard";
  "review-replay-sum: runs — \(.runs | length) run(s) of kit \(.kit.describe) (\(.kit.sha[0:7])) across \(.runs | map(.repo | ascii_downcase) | unique | length) repo(s)",
  (.runs[] | "  \(.repo) \(.run): \(.prs | prs_text)"),
  "review-replay-sum: aggregate — \(.prs | prs_text) — \(counts_text)",
  if has("lessons") then (.lessons[] | "lessons — \(.cause) (\(.missed) missed, \(.proposals) proposal(s)): \(.prs | join(", "))")
  else (.records | lessons("\(.repo)#\(.pr)")) end' "$TMP/sum.json" || die "cannot print the scorecard"
cost="$(jqq -r '.cost | [.claude_usd, .claude_calls_of_unknown_cost, .codex_tokens, .prs_of_unknown_codex_tokens] | @tsv' "$TMP/sum.json")" \
  && read -r usd cu tokens tu <<< "$cost" || die "cannot print the cost"
printf 'review-replay-sum: cost — claude $%.2f' "$usd"
[ "$cu" = 0 ] || printf ' + unknown for %s call(s)' "$cu"
printf ', codex %s tokens' "$tokens"
[ "$tu" = 0 ] || printf ' + unknown for %s PR(s)' "$tu"
printf ', failed and skipped PRs included\n'
"${SCORE[@]}" -r 'include "replay-scorecard"; "review-replay-sum: denials — \(.denials | denials_text), failed PRs included"' "$TMP/sum.json" \
  || die "cannot print the denials"
