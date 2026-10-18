# Repo-owned stack wiring for the analyzer pass. Sourced by the kit's
# scripts/lib/analyzers.sh INSTEAD of its generic per-language stanzas, with
# these in scope:
#   $report            — append findings here (plain text, fed to the lenses)
#   $list              — file listing the changed paths, one per line
#   _have <cmd>        — true if the tool is installed
#   _section <title>   — write a section header into $report
#   _files_matching '<glob>|<glob>' — changed files that exist, by extension
#   _run_analyzer <title> <findings-ERE> <command> [args...]
#                      — runs a tool in its own section and ends the section
#                        with its status line: ran, failed or unknown
#   _analyzer_status <ran|skipped|failed|unknown> — <why>
#                      — the status line, for a section you write yourself
#   _node_deps_missing — true when package.json declares dependencies and
#                        none are installed (no node_modules)
#
# Keep every command best-effort — this pass informs the review, it never
# gates it. Verify each command works before adding it. Run each tool through
# _run_analyzer: the lenses do not re-report what a linter flagged, so a tool
# that could not run must not read as clean. Its <findings-ERE> matches a line
# of a real finding; a non-zero exit with no such line is labelled unknown,
# since a crash and a finding exit alike. A section with no status line is
# labelled unknown, or failed when its output says the tool never ran.
#
# Example (pnpm TypeScript monorepo — use the runner your lockfile implies:
# npx --no-install, yarn exec on berry, node_modules/.bin/ on yarn 1 or bun):
#
# local ts f; local -a files; ts="$(_files_matching '*.ts|*.tsx')"
# if [ -n "$ts" ] && _node_deps_missing; then
#   _section "eslint + tsc"
#   _analyzer_status "skipped — dependencies are not installed (no node_modules)"
# elif [ -n "$ts" ]; then
#   files=(); while IFS= read -r f; do files+=("$f"); done <<< "$ts"
#   _run_analyzer eslint '^[[:space:]]+[0-9]+:[0-9]+[[:space:]]+(error|warning)' pnpm exec eslint "${files[@]}"
#   _run_analyzer tsc '\([0-9]+,[0-9]+\): error TS' pnpm exec tsc --build --noEmit --pretty false
# fi
