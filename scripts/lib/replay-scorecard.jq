# The scorecard of a list of review-postmortem records, shared by review-replay.sh
# and review-replay-sum.sh. Load with: jq -L <hub>/scripts/lib 'include "replay-scorecard"; …'
def sum(p): map(p // 0) | add // 0;
def compare_failed: [(.findings // [])[] | select(.unscored_reason | strings | startswith("compare_failed"))] | length;
def missed_as($c): [(.findings // [])[] | select(.class == "missed" and .cause == $c)] | length;
# a record's missed_by_cause has four keys: an unverified miss, or one of no known cause, is in none
def tally:
  {counts: {caught: sum(.counts.caught), missed: sum(.counts.missed), rejected_wrongly: sum(.counts.rejected_wrongly),
            noise: sum(.counts.noise), unscored: sum(.counts.unscored), compare_failed: (map(compare_failed) | add // 0)},
   missed_by_cause: {wrong_lens: sum(.missed_by_cause.wrong_lens), tracing: sum(.missed_by_cause.tracing),
                     threshold: sum(.missed_by_cause.threshold), structural: sum(.missed_by_cause.structural),
                     unverified: (map(missed_as("unverified")) | add // 0)}}
  | .missed_by_cause.unattributed = .counts.missed - (.missed_by_cause | add);
# prs_text: of {replayed, incomplete, skipped, failed, unreviewed_passed_over}
def prs_text:
  "replayed \(.replayed) / incomplete \(.incomplete) / skipped \(.skipped) / failed \(.failed)"
  + (if .unreviewed_passed_over > 0 then " (\(.unreviewed_passed_over) merged PR(s) CodeRabbit never reviewed passed over)" else "" end);
# counts_text: of tally's output
def counts_text:
  "caught \(.counts.caught) / missed \(.counts.missed)"
  + " (wrong lens \(.missed_by_cause.wrong_lens) / tracing \(.missed_by_cause.tracing) / threshold \(.missed_by_cause.threshold)"
  + " / structural \(.missed_by_cause.structural) / unverified \(.missed_by_cause.unverified)"
  + (if .missed_by_cause.unattributed != 0 then " / no cause \(.missed_by_cause.unattributed)" else "" end) + ")"
  + " / rejected-wrongly \(.counts.rejected_wrongly) / noise \(.counts.noise) / unscored \(.counts.unscored) (compare_failed \(.counts.compare_failed))";
# lessons(who): the misses and proposals grouped by cause, each named by who, run on its record
def lessons(who):
  [.[] | who as $who | ((.findings // [])[] | select(.class == "missed") | {cause: (.cause // "unclassified"), who: $who, what: "missed: \(.file // "?") — \(.summary // "")"}),
                       ((.proposals // [])[] | {cause: (.cause // "unclassified"), who: $who, what: "propose (\(.route // "?")) \(.file // "?"): \(.lines // "")"})]
  | group_by(.cause) | .[]
  | "lessons — \(.[0].cause) (\(map(select(.what | startswith("missed"))) | length) missed):",
    (.[] | "  \(.who) \(.what)");
# denials_text: of {commands, prs_with_denials, prs_of_unknown_denials}
def denials_text:
  "\(.commands) command(s) denied in \(.prs_with_denials) PR(s)"
  + (if .prs_of_unknown_denials > 0 then " + unknown for \(.prs_of_unknown_denials) PR(s)" else "" end);
