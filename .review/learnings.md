<!--
Accumulated review memory for the hub itself. Injected verbatim into every
Codex lens prompt when the hub reviews its own changes. Repo-owned: never
synced to spokes.

  SUPPRESS — a class of finding this repo does not want. Added by /review-tune
             when the same rejection reason recurs.
  WATCH    — a class of defect that reached CodeRabbit or production because the
             local pass missed it. Added by /review-postmortem.

Keep entries short and specific. Prune anything stale. If this file grows past
roughly 60 lines it is diluting every prompt — consolidate.
-->

## Repository facts

## SUPPRESS
- `scripts/review-replay.sh` already exports `GIT_CONFIG_COUNT`, which needs
  Git 2.31. A finding that a git option it uses needs Git 2.31 or older is a
  false positive there. A git feature newer than 2.31 is still a finding.

## WATCH
- 2026-10-18: a shell value validated as digits was spliced into JSON (or passed
  to `jq --argjson`) as-is. A leading zero (`07`) passes a `[0-9]` check but is
  not a JSON number, and `00` passes a check against `0` but is zero, so the JSON
  write failed and the run lost its record. Normalising with `$((10#$v))` then
  wraps an oversized value (`18446744073709551617` is 1). When a validated string
  reaches JSON or arithmetic, check every form the validation admits; strip
  leading zeros as a string and bound the length, or pass it with `--arg` and
  `tonumber`.
