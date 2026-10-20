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
RECOMMENDED_MODEL="gpt-6.1-sol"
MARK_START="<!-- BEGIN codex-review-kit -->"
MARK_END="<!-- END codex-review-kit -->"
fail=0

hdr() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
no()  { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }
skip(){ printf '  \033[2m·\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

# Print the top-level `model` value of a Codex profile. Returns 1 when it has
# no top-level model line, 3 when that line holds no quoted name (it is then
# printed raw), 2 when the file cannot be read or awk fails.
profile_model() {
  local rc
  [ -r "$1" ] || return 2
  awk -v q="'" '
    /^[[:space:]]*\[/ { exit }
    $0 ~ ("^[[:space:]]*(\"model\"|" q "model" q "|model)[[:space:]]*=") {
      found = 1
      v = $0; sub(/^[^=]*=[[:space:]]*/, "", v)
      c = substr(v, 1, 1); d = c
      if (substr(v, 1, 3) == c c c) d = c c c
      v = substr(v, length(d) + 1); n = index(v, d)
      if ((c != "\"" && c != q) || n < 2) { print $0; bad = 1; exit }
      print substr(v, 1, n - 1); exit
    }
    END { if (bad) exit 13; if (!found) exit 11 }' "$1" && return 0
  rc=$?
  [ "$rc" -eq 11 ] && return 1
  [ "$rc" -eq 13 ] && return 3
  return 2
}

# From /, so a repo-local yaml.py is never the module imported.
have_yaml_parser() { ( cd / && python3 -c 'import yaml' ) 2>/dev/null; }

# Print one line per wiring defect in a YAML CodeRabbit config; silence means
# correctly wired. Parsed rather than grepped: the seeded template names
# rubric.md and applyTo in its own comments, an entry misplaced under
# path_instructions is not a guideline at all, and a valid config may quote
# differently than the template.
cfg_diagnose() {
  ( cd / && python3 - "$REPO_ROOT/$1" ) 2>/dev/null <<'PYCFG'
import sys, yaml


class DuplicateKey(yaml.constructor.ConstructorError):
    pass


# PyYAML keeps the LAST of a duplicated key and says nothing, so a file whose
# real wiring sits in an overridden block would be vouched for here on the
# strength of a block the gate may never apply. Only literal keys are compared:
# `<<` merge keys are resolved by SafeLoader's own flattening, which this
# delegates to — rejecting them here would fail a valid anchored config.
class StrictLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _value_node in node.value:
            if key_node.tag == "tag:yaml.org,2002:merge":
                continue
            key = self.construct_object(key_node, deep=deep)
            try:
                if key in seen:
                    raise DuplicateKey(None, None, "duplicate key %r" % (key,),
                                       key_node.start_mark)
                seen.add(key)
            except TypeError:
                continue  # unhashable key — SafeLoader reports it in its own terms
        return super().construct_mapping(node, deep=deep)

try:
    with open(sys.argv[1]) as fh:
        d = yaml.load(fh, Loader=StrictLoader) or {}
except DuplicateKey as e:
    print("has a %s - this check reads the last one and other YAML parsers reject the file outright, so what the gate applies is not what was checked here" % e.problem)
    sys.exit(0)
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
pats = cg.get("filePatterns") if isinstance(cg, dict) else []
if pats is None:
    pats = []
if not isinstance(pats, list):
    print("sets knowledge_base.code_guidelines.filePatterns to a %s rather than a list - CodeRabbit cannot read the mappings from it" % type(pats).__name__)
    pats = []
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
have_yaml_parser && ok "python3 yaml module (reads CodeRabbit path_instructions for the lenses)" \
  || skip "python3 yaml module not installed (optional) — without it, a review in a repo with a YAML CodeRabbit config warns that the lenses did not see its path_instructions"
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
  if mkdir -p "$CODEX_HOME" && cat > "$PROFILE_FILE" <<TOML
# Codex profile for adversarial code review.
# Selected with: codex --profile deep-review
#
# NOTE: since Codex 0.134.0, profiles live in their own file with TOP-LEVEL keys.
# Do NOT wrap these in a [profiles.deep-review] table — that form is no longer read.

# Pinned for now: the model everyone is using for code reviews. Model names
# churn — when this stops resolving, check \`/model\` in the Codex TUI for what
# your plan exposes and re-pin.
model = "$RECOMMENDED_MODEL"

# $RECOMMENDED_MODEL accepts: low | medium | high | xhigh | max | ultra. ultra adds
# automatic task delegation — not for these headless, read-only review lenses.
model_reasoning_effort = "high"
model_reasoning_summary = "none"  # we only want the final JSON
model_verbosity = "low"

approval_policy = "never"         # required for headless runs
sandbox_mode = "read-only"        # reviewers never touch the working tree
TOML
  then
    ok "created: $PROFILE_FILE (pins $RECOMMENDED_MODEL)"
  else
    rm -f "$PROFILE_FILE"
    no "could not write $PROFILE_FILE"
  fi
fi
if [ -f "$PROFILE_FILE" ]; then
  pinned="$(profile_model "$PROFILE_FILE")"; pin_rc=$?
  if [ "$pin_rc" -eq 2 ]; then
    no "cannot read or parse $PROFILE_FILE — which model it pins is unknown"
  elif [ "$pin_rc" -eq 3 ]; then
    no "cannot parse the model line in $PROFILE_FILE ($pinned) — set it to: model = \"$RECOMMENDED_MODEL\""
  elif [ "$pin_rc" -eq 1 ]; then
    warn "profile pins no model — the fleet standard is $RECOMMENDED_MODEL; add: model = \"$RECOMMENDED_MODEL\""
  elif [ "$pinned" = "$RECOMMENDED_MODEL" ]; then
    ok "pins $RECOMMENDED_MODEL (the fleet standard)"
  else
    warn "profile pins model \"$pinned\", not the fleet standard $RECOMMENDED_MODEL — fine if deliberate; to switch, set this line in $PROFILE_FILE: model = \"$RECOMMENDED_MODEL\""
  fi
fi

# --- 4. executables --------------------------------------------------------
hdr "Scripts"
if [ "$CHECK_ONLY" -eq 0 ]; then
  chmod +x scripts/review.sh scripts/review-install.sh .githooks/* 2>/dev/null
fi
[ -x scripts/review.sh ] && ok "scripts/review.sh executable" || no "scripts/review.sh not executable"

# --- 5. git hooks ----------------------------------------------------------
hdr "Git hooks"
if hook_wiring; then
  ok "$HOOK_NOTE"
elif [ "$HOOK_STATE" = unset ] && [ "$CHECK_ONLY" -eq 0 ]; then
  if git config core.hooksPath .githooks; then
    ok "set core.hooksPath = .githooks"
    skip "hook warns on a stale verdict by default; blocks when REVIEW_STRICT=1"
  else
    no "could not set core.hooksPath — the pre-push hook will not run"
  fi
else
  no "pre-push hook not wired: $HOOK_NOTE"
  [ -z "$HOOK_FIX" ] || skip "fix: $HOOK_FIX"
  [ "$HOOK_STATE" != foreign ] || skip "e.g. husky: echo '$HOOK_CHAIN' >> .husky/pre-push"
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
  if ! cr_problems="$(cfg_diagnose "$cr_cfg")"; then
    cr_problems="could not be inspected — the wiring check failed on its contents; verify inheritance and the rubric/learnings mappings by hand"
  fi
  if [ -z "$cr_problems" ]; then
    ok "$cr_cfg wires inheritance and both guideline mappings (no other key is schema-checked here)"
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

# --- 10. kit sync ----------------------------------------------------------
hdr "Kit release sync"
if [ -f .github/workflows/review-kit-sync.yml ]; then
  if [ ! -f scripts/review-sync.sh ]; then
    no "review-kit-sync workflow present but scripts/review-sync.sh is missing — every run fails; sync it with scripts/review-update.sh"
  elif ! grep -q 'scripts/review-sync.sh' .github/workflows/review-kit-sync.yml; then
    skip "review-kit-sync workflow present but never runs scripts/review-sync.sh — check its edits"
  else
    ok "review-kit-sync workflow present — opens a PR for each new kit release"
  fi
else
  skip "no .github/workflows/review-kit-sync.yml — new kit releases arrive only by hand; seed it with scripts/review-update.sh --init, or opt out with KIT_SYNC_ACTION=0 in .review/config.sh"
fi

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
       .claude-plugin/, AGENTS.md, CLAUDE.md, that config file, and
       .github/workflows/review-kit-sync.yml if --init seeded it.

  Then, on a branch with changes:
    ./scripts/review.sh            — raw run, writes .review/findings.md
    /review                        — in Claude Code: run + verify + fix + verdict

  On a new machine: clone, then ./scripts/review-install.sh

  Across many repos: ./scripts/make-plugin.sh ../codex-review-plugin
    then /plugin marketplace add <that repo> in Claude Code. Installs once
    per machine; each repo still supplies its own rubric.md and learnings.md.
EOF
