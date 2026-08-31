# codex-review-kit

A multi-lens pre-PR code-review pipeline: six narrow, parallel Codex review
passes over a branch diff, merged into structured findings, adjudicated by
Claude Code, gated by CodeRabbit on the PR.

This repository is the **hub**. Consuming repos are spokes: they vendor the
shared machinery via `scripts/review-update.sh` and keep their own rubric,
learnings, and stack wiring. Lessons learned in one repo route back here and
reach every other repo on its next sync.

- **[REVIEW.md](REVIEW.md)** — what the kit is, how it works, how to install it
- **[OPERATING.md](OPERATING.md)** — proving the pipeline works, and its quiet failure modes

## Install into a repo

In Claude Code, say `/review-onboard` (or use the `review-kit-install` skill) —
it bootstraps the files and does the adaptation properly. By hand:

```bash
# From a local hub clone — no download, and the default path:
bash ~/dev/private/codex-review-kit/scripts/review-update.sh --init
./scripts/review-install.sh
```

Without a local clone, the bootstrap fetches the hub's latest release tag —
never the mutable `main` — and prints the source and revision it installs.
Set `REVIEW_KIT_REF` to a tag or full commit SHA to pin harder. See
[REVIEW.md](REVIEW.md) for the full install notes.

## Tests

```bash
./tests/review-test.sh
```

Drives the real `scripts/review.sh` end-to-end in a throwaway git repo with a
stubbed `codex` on PATH — no network, no Codex login. CI runs it on every push.

## History

Extracted from [theunisdk/ai-dev](https://github.com/theunisdk/ai-dev)
(`codex-review-kit/`), where the kit's pre-split history lives.

## License

MIT
