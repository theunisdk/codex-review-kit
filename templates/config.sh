# Sourced by scripts/review.sh before flag parsing. Commit this — it is how a
# repo pins its own review posture. Every value can still be overridden by a flag.

# Which lenses to run, in order. Drop one to go faster.
# LENSES="correctness,security,contracts,resources,tests,scope"

# Reasoning effort per lens (vocabulary is model-dependent; gpt-6.1-sol
# accepts: low | medium | high | xhigh | max | ultra). ultra adds automatic
# task delegation — not for these headless, read-only lenses.
# Start at high. Drop to medium if reviews feel slow before they feel shallow.
# EFFORT="high"

# Codex profile (see ~/.codex/deep-review.config.toml). Leave as-is unless you
# maintain several review postures.
# PROFILE="deep-review"

# Explicit model override. Empty = whatever the profile pins. Prefer pinning in
# the profile so every repo moves together when you change models.
# MODEL=""

# Drop findings below this confidence. Raise toward 0.7 once you trust the setup.
# CONFIDENCE_MIN="0.5"

# Lenses to run at once. 6 = all of them. Lower if you hit plan rate limits.
# MAX_PARALLEL="6"

# Per-lens wall-clock ceiling in seconds.
# LENS_TIMEOUT="900"

# Exit non-zero when findings at/above this severity exist: none|critical|high|medium|low
# FAIL_ON="none"

# Set to 0 to skip linters/semgrep before the Codex passes.
# RUN_ANALYZERS="1"

# Set to 0 and `review-update.sh --init` stops seeding
# .github/workflows/review-kit-sync.yml, the weekly job that opens a PR for each
# new kit release. Delete that file too if it was seeded already.
# KIT_SYNC_ACTION="1"
