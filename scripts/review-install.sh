#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# review-install.sh — set up the Codex review pipeline on this machine + repo.
#
# Idempotent and non-destructive: it never overwrites an existing config, an
# existing AGENTS.md, or an existing CLAUDE.md. Safe to re-run after a git pull
# and safe to run on every machine you work from.
#
#   ./scripts/review-install.sh            # install
#   ./scripts/review-install.sh --check    # verify only, change nothing
# ---------------------------------------------------------------------------
set -uo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: run this from inside the git repository you want to install into" >&2
  exit 1; }
cd "$REPO_ROOT" || exit 1
. "$REPO_ROOT/scripts/lib/common.sh"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
PROFILE_FILE="$CODEX_HOME/deep-review.config.toml"
MARK_START="<!-- BEGIN codex-review-kit -->"
MARK_END="<!-- END codex-review-kit -->"
fail=0

hdr() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
no()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
skip(){ printf '  \033[2m·\033[0m %s\n' "$*"; }

have_yaml_parser() { python3 -c 'import yaml' 2>/dev/null; }

# Print one line per wiring defect in a YAML CodeRabbit config; silence means
# correctly wired. Parsed rather than grepped: the seeded template names
# rubric.md and applyTo in its own comments, an entry misplaced under
# path_instructions is not a guideline at all, and a valid config may quote
# differently than the template.
cfg_diagnose() {
  python3 - "$1" 2>/dev/null <<'PYCFG'
import sys, yaml

try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception as e:
    msg = str(e).splitlines()[0][:100]
    print("does not parse (%s) - CodeRabbit discards the whole file and reviews with defaults" % msg)
    sys.exit(0)

if not isinstance(d, dict):
    print("is not a YAML mapping - CodeRabbit discards the whole file and reviews with defaults")
    sys.exit(0)

if d.get("inheritance") is not True:
    print("omits 'inheritance: true' - CodeRabbit resolves a single config source, so this file replaces the org and central settings instead of merging with them")

kb = d.get("knowledge_base") or {}
cg = kb.get("code_guidelines") if isinstance(kb, dict) else None
if isinstance(cg, dict) and cg.get("enabled") is False:
    print("sets knowledge_base.code_guidelines.enabled to false - the mappings below are inert and the gate applies neither the rubric nor the learnings")
pats = (cg or {}).get("filePatterns") or [] if isinstance(cg, dict) else []
for g in (".review/rubric.md", ".review/learnings.md"):
    if not any(isinstance(e, dict) and e.get("files") == g and e.get("applyTo") == "**/*"
               for e in pats):
        print('has no knowledge_base.code_guidelines.filePatterns entry mapping %s with applyTo "**/*" - the gate grades without it while the lenses grade with it' % g)
PYCFG
}

# --- 1. dependencies -------------------------------------------------------
hdr "Dependencies"
for c in git jq codex; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c ($(command -v "$c"))"; else no "$c not on PATH"; fi
done
command -v claude >/dev/null 2>&1 && ok "claude" || skip "claude CLI not found (fine if you use the desktop app)"
for c in semgrep gitleaks shellcheck; do
  command -v "$c" >/dev/null 2>&1 && ok "$c (optional analyzer)" || skip "$c not installed (optional)"
done
[ "$fail" -eq 1 ] && { echo; echo "Install the missing required tools, then re-run." >&2; exit 1; }

# --- 2. codex auth ---------------------------------------------------------
hdr "Codex authentication"
if codex login status >/dev/null 2>&1; then
  ok "authenticated"
else
  no "not authenticated — run: codex login"
fi

# --- 3. review profile (per machine) --------------------------------------
hdr "Codex review profile"
if [ -f "$PROFILE_FILE" ]; then
  ok "exists: $PROFILE_FILE (left untouched)"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  no "missing: $PROFILE_FILE"
else
  mkdir -p "$CODEX_HOME"
  cat > "$PROFILE_FILE" <<'TOML'
# Codex profile for adversarial code review.
# Selected with: codex --profile deep-review
#
# NOTE: since Codex 0.134.0, profiles live in their own file with TOP-LEVEL keys.
# Do NOT wrap these in a [profiles.deep-review] table — that form is no longer read.

# Pinned for now: the model everyone is using for code reviews. Model names
# churn — when this stops resolving, check `/model` in the Codex TUI for what
# your plan exposes and re-pin.
model = "gpt-5.6-sol"

model_reasoning_effort = "high"   # sol accepts: none | low | medium | high | xhigh | max
model_reasoning_summary = "none"  # we only want the final JSON
model_verbosity = "low"

approval_policy = "never"         # required for headless runs
sandbox_mode = "read-only"        # reviewers never touch the working tree
TOML
  ok "created: $PROFILE_FILE (pins gpt-5.6-sol)"
fi
if [ -f "$PROFILE_FILE" ] && ! grep -q '^model *=' "$PROFILE_FILE"; then
  skip "profile pins no model — the fleet standard is gpt-5.6-sol; add: model = \"gpt-5.6-sol\""
fi

# --- 4. executables --------------------------------------------------------
hdr "Scripts"
if [ "$CHECK_ONLY" -eq 0 ]; then
  chmod +x scripts/review.sh scripts/review-install.sh .githooks/* 2>/dev/null
fi
[ -x scripts/review.sh ] && ok "scripts/review.sh executable" || no "scripts/review.sh not executable"

# --- 5. git hooks ----------------------------------------------------------
hdr "Git hooks"
current="$(git config --get core.hooksPath 2>/dev/null || true)"
if [ "$current" = ".githooks" ]; then
  ok "core.hooksPath = .githooks"
elif [ -n "$current" ]; then
  skip "core.hooksPath already set to '$current' — leaving alone; add .githooks/pre-push yourself"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  no "core.hooksPath not set"
elif git config core.hooksPath .githooks; then
  ok "set core.hooksPath = .githooks"
  skip "hook only WARNS about a stale review; it never blocks a push"
else
  no "could not set core.hooksPath — the pre-push hook will not run"
fi

# --- 6. agent pointer files ------------------------------------------------
hdr "Agent instruction files"
block() {
  cat <<EOF
$MARK_START
## Code review standards

This repository uses a shared review rubric at \`.review/rubric.md\`. Read it
before reviewing or writing code here. Accumulated review memory — suppressions
and known blind spots — is in \`.review/learnings.md\`.

Pre-PR review runs via \`./scripts/review.sh\` (parallel Codex lenses). The
adjudication procedure is \`.review/adjudication.md\` — follow it rather than
reviewing a diff ad hoc. CodeRabbit is the final gate on the PR.
$MARK_END
EOF
}
for f in AGENTS.md CLAUDE.md; do
  if [ -f "$f" ] && grep -q "$MARK_START" "$f" 2>/dev/null; then
    ok "$f already references the rubric"
  elif [ "$CHECK_ONLY" -eq 1 ]; then
    no "$f does not reference .review/rubric.md"
  else
    if [ -f "$f" ]; then printf '\n' >> "$f"; else printf '# %s\n\n' "${f%.md}" > "$f"; fi
    block >> "$f"
    ok "appended rubric pointer to $f"
  fi
done

# --- 7. PR gate ------------------------------------------------------------
hdr "PR gate (CodeRabbit)"
cr_cfg=""
for f in .coderabbit.yaml .coderabbit.yml .coderabbit.config.ts; do
  [ -f "$f" ] && { cr_cfg="$f"; break; }
done
cr_undoc=""
for f in coderabbit.yaml coderabbit.yml; do
  [ -f "$f" ] && { cr_undoc="$f"; break; }
done
if [ -z "$cr_cfg" ] && [ -n "$cr_undoc" ]; then
  skip "$cr_undoc present — not one of CodeRabbit's documented config names, so it is not inspected here; if it is your active config verify its wiring by hand. --init will not seed alongside it"
elif [ -z "$cr_cfg" ]; then
  skip "no CodeRabbit config — the gate runs on its defaults, not this repo's rubric; seed one with scripts/review-update.sh --init"
elif [ "$cr_cfg" = .coderabbit.config.ts ]; then
  skip "$cr_cfg is the active config and is NOT inspected here — verify its inheritance and rubric wiring by hand, and do not add a .coderabbit.yaml (YAML overrides it outright)"
elif ! have_yaml_parser; then
  skip "$cr_cfg present, but no python3 yaml module here to verify its wiring — check inheritance and the rubric/learnings mappings by hand"
else
  cr_problems="$(cfg_diagnose "$cr_cfg")"
  if [ -z "$cr_problems" ]; then
    ok "$cr_cfg wires inheritance and both guideline mappings"
  else
    while IFS= read -r cr_line; do
      [ -n "$cr_line" ] || continue
      if [ "$CHECK_ONLY" -eq 1 ]; then no "$cr_cfg $cr_line"; else skip "$cr_cfg $cr_line"; fi
    done <<EOF
$cr_problems
EOF
  fi
fi

# --- 8. agent skills -------------------------------------------------------
hdr "Agent skills"
if [ -f .claude/skills/pre-pr-review/SKILL.md ]; then
  ok "Claude Code: pre-pr-review skill (auto-triggers near commit/push/PR)"
else
  no ".claude/skills/pre-pr-review/SKILL.md missing"
fi
if [ -f .codex/skills/repo-review-standards/SKILL.md ]; then
  ok "Codex: repo-review-standards skill (interactive sessions only)"
else
  skip ".codex/skills/ not present — optional; the pipeline does not need it"
fi
[ -f .review/adjudication.md ] && ok "shared adjudication procedure" \
  || no ".review/adjudication.md missing (skill and command both delegate to it)"

# --- 9. gitignore ----------------------------------------------------------
hdr "Ignore rules"
if [ -f .review/.gitignore ]; then ok ".review/.gitignore present"; else no ".review/.gitignore missing"; fi

# --- done ------------------------------------------------------------------
hdr "Result"
if [ "$fail" -eq 1 ]; then
  echo "  Some checks failed — see above."; exit 1
fi
cat <<'EOF'
  Ready.

  Next:
    1. Edit .review/rubric.md      — your house rules, replacing the examples.
    2. Edit .review/config.sh      — posture per repo (all values are commented out).
    3. Optionally pin a model in ~/.codex/deep-review.config.toml.
    4. Edit the CodeRabbit config named above — the PR gate; /review-onboard
       wires it to .review/rubric.md. Do not add a second one: YAML in either
       spelling overrides .coderabbit.config.ts outright.
    5. Commit .review/, scripts/, .claude/, .codex/, .githooks/,
       .claude-plugin/, AGENTS.md, CLAUDE.md, and that config file.

  Then, on a branch with changes:
    ./scripts/review.sh            — raw run, writes .review/findings.md
    /review                        — in Claude Code: run + verify + fix + verdict

  On a new machine: clone, then ./scripts/review-install.sh

  Across many repos: ./scripts/make-plugin.sh ../codex-review-plugin
    then /plugin marketplace add <that repo> in Claude Code. Installs once
    per machine; each repo still supplies its own rubric.md and learnings.md.
EOF
