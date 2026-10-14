# Repo-owned stack wiring for the analyzer pass. Sourced by the kit's
# scripts/lib/analyzers.sh INSTEAD of its generic per-language stanzas, with
# these in scope:
#   $report            — append findings here (plain text, fed to the lenses)
#   $list              — file listing the changed paths, one per line
#   _have <cmd>        — true if the tool is installed
#   _section <title>   — write a section header into $report
#   _files_matching '<glob>|<glob>' — changed files that exist, by extension
#
# Keep every command best-effort — this pass informs the review, it never
# gates it. Verify each command works before adding it. Never leave a section
# empty: the lenses read empty as clean, so keep stderr and write a clean line
# or the rc when there is no other output.
#
# Example (pnpm TypeScript monorepo — use the runner your lockfile implies:
# npx --no-install, yarn exec on berry, node_modules/.bin/ on yarn 1 or bun):
#
# local ts out rc; ts="$(_files_matching '*.ts|*.tsx')"
# if [ -n "$ts" ]; then
#   _section "eslint"
#   out="$(printf '%s\n' "$ts" | tr '\n' '\0' | xargs -0 pnpm exec eslint 2>&1)"; rc=$?
#   if [ "$rc" -eq 0 ] && [ -z "$out" ]; then echo "eslint: clean" >> "$report"
#   else printf 'eslint rc=%s\n%s\n' "$rc" "$out" | head -200 >> "$report"; fi
#   _section "tsc"
#   out="$(pnpm exec tsc --build --noEmit 2>&1)"; rc=$?
#   if [ "$rc" -eq 0 ] && [ -z "$out" ]; then echo "tsc: clean" >> "$report"
#   else printf 'tsc rc=%s\n%s\n' "$rc" "$out" | head -100 >> "$report"; fi
# fi
