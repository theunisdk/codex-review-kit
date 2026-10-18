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
#     --json    print the combined scorecard as JSON instead
#
# Refuses, rather than sums: a run that stopped before its scorecard, one made
# by an older review-replay.sh, the same run twice, a PR scored in two runs,
# and runs of different kits. Exit: 0 summed · 1 refused · 64 usage
# ---------------------------------------------------------------------------
set -uo pipefail

HUB="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=lib/common.sh
. "$HUB/scripts/lib/common.sh"

usage() { sed -n '2,16p' "$0" >&2; exit 64; }

JSON=""; RUNS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json)    JSON=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    -*)        echo "error: unknown flag: $1" >&2; usage ;;
    *)         RUNS+=("$1") ;;
  esac
  shift
done
[ "${#RUNS[@]}" -gt 0 ] || { echo "error: name at least one run directory or aggregate.json" >&2; usage; }
need_cmd jq

TMP="$(mktemp -d)" || die "no temp dir"
trap 'rm -rf "$TMP"' EXIT

: > "$TMP/runs.all"
for r in "${RUNS[@]}"; do
  f="$r"; [ ! -d "$r" ] || f="$r/aggregate.json"
  if [ ! -e "$f" ]; then
    [ -d "$r" ] && [ -e "$r/summary.txt" ] \
      && die "$r has no aggregate.json: the run stopped before its scorecard (see its summary.txt)"
    die "$f does not exist"
  fi
  jq -e 'type == "object" and (.schema | type) == "string"' "$f" > /dev/null 2>&1 || die "$f is not a replay run's aggregate"
  schema="$(jq -r .schema "$f")"
  [ "$schema" = review-replay-run/v2 ] \
    || die "$f is $schema, not review-replay-run/v2: an older review-replay.sh wrote it, without its incomplete PRs and denied commands — re-run it"
  jq -c --arg path "$f" '{path: $path, run, spoke, repo, kit, prs, cost, denials, records: [.repo as $r | .records[] | . + {repo: $r}]}' \
    "$f" >> "$TMP/runs.all" \
    || die "cannot read $f"
done
jq -s . "$TMP/runs.all" > "$TMP/runs.json" || die "cannot read the runs back"

# what would be counted twice, or mixes kits
# a run is its spoke's; GitHub names are case-insensitive
jq -r '(group_by("\(.spoke) \(.run)") | map(select(length > 1)) | .[] | "the same run twice: \(map(.path) | join(", "))"),
  ([.[] | .run as $run | .records[] | {key: "\(.repo | ascii_downcase)#\(.pr)", run: $run}] | group_by(.key) | map(select(length > 1)) | .[]
    | "\(.[0].key) is scored in more than one run (\(map(.run) | join(", "))): pass one of them"),
  (map(.kit.sha) | unique | select(length > 1) | "runs of different kits (\(map(.[0:7]) | join(", "))) do not sum to one kit'"'"'s scorecard")' \
  "$TMP/runs.json" > "$TMP/refused" || die "cannot check the runs"
[ ! -s "$TMP/refused" ] || die "$(head -n1 "$TMP/refused")"

SCORE=(jq -L "$HUB/scripts/lib")
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

if [ -n "$JSON" ]; then cat "$TMP/sum.json"; exit 0; fi
"${SCORE[@]}" -r 'include "replay-scorecard";
  "review-replay-sum: runs — \(.runs | length) run(s) of kit \(.kit.describe) (\(.kit.sha[0:7])) across \(.runs | map(.repo | ascii_downcase) | unique | length) repo(s)",
  (.runs[] | "  \(.repo) \(.run): \(.prs | prs_text)"),
  "review-replay-sum: aggregate — \(.prs | prs_text) — \(counts_text)",
  (.records | lessons("\(.repo)#\(.pr)"))' "$TMP/sum.json" || die "cannot print the scorecard"
cost="$(jq -r '.cost | [.claude_usd, .claude_calls_of_unknown_cost, .codex_tokens, .prs_of_unknown_codex_tokens] | @tsv' "$TMP/sum.json")" \
  && read -r usd cu tokens tu <<< "$cost" || die "cannot print the cost"
printf 'review-replay-sum: cost — claude $%.2f' "$usd"
[ "$cu" = 0 ] || printf ' + unknown for %s call(s)' "$cu"
printf ', codex %s tokens' "$tokens"
[ "$tu" = 0 ] || printf ' + unknown for %s PR(s)' "$tu"
printf ', failed and skipped PRs included\n'
"${SCORE[@]}" -r 'include "replay-scorecard"; "review-replay-sum: denials — \(.denials | denials_text), failed PRs included"' "$TMP/sum.json" \
  || die "cannot print the denials"
