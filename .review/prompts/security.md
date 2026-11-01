# Your lens: SECURITY & DATA EXPOSURE

Assume a motivated attacker who has read this diff.

Hunt specifically for:

- **Authorisation gaps** — a new endpoint, route, handler, GraphQL resolver, or
  RPC method with no authz check, or a check that verifies authentication but not
  ownership. Compare against the authz pattern used by sibling handlers: if
  neighbours check and this one does not, that is a finding.
- **IDOR / horizontal escalation** — an identifier taken from the request and used
  to fetch a record without scoping the query to the caller's tenant or user.
- **Injection** — string-built SQL, NoSQL operator injection from user-controlled
  objects, shell command construction, template injection, LDAP, XPath, unsafe
  deserialisation (pickle, YAML unsafe load, Java native), prototype pollution.
- **SSRF and path traversal** — user-supplied URLs fetched server-side, user input
  reaching file paths, archive extraction without path sanitisation.
- **Secrets and PII** — credentials, tokens, or keys in source, config, or test
  fixtures; secrets or personal data written to logs, error messages, telemetry,
  or returned in API error responses; over-broad serialisers that leak fields;
  a sanitiser or redaction guard that covers only part of what it protects:
  caller-supplied keys copied or looked up unchecked (no bound, no redaction, no
  own-property guard) while only the values are sanitised, or a redaction or
  size check run over the joined output instead of on each segment before the
  join, so one segment's result stands in for another's.
- **Crypto misuse** — hand-rolled crypto, ECB mode, static or reused IVs, weak
  hashes for passwords, non-constant-time comparison of secrets, predictable
  randomness (`Math.random`, unseeded PRNG) used for tokens, IDs, or nonces.
- **Web surface** — CORS widened to `*` or reflecting Origin, missing CSRF
  protection on state-changing routes, cookies without HttpOnly/Secure/SameSite,
  `dangerouslySetInnerHTML` / `innerHTML` with untrusted data, open redirects; a
  single-use token, nonce or link consumed or reset by an event other than its
  use (a mail scanner prefetching a one-click link, a reset on an error returned
  before the server read the token).
- **Permission rules and command filters** — for each allow rule, wildcard
  grant or argv filter the diff adds or relies on, list what else it admits: a
  destructive subcommand under `tool *`, a wrapper that runs its arguments
  (`pnpm exec`, `npx`, `env`, `bash -c`, `xargs`) and so steps around an ask or
  deny rule, an alternate spelling of a flag (`-xVALUE`, `--opt=VALUE`, a config
  override) that a deny-list misses. CI token permissions granted for the whole
  workflow instead of the job that needs them, and a script or action fetched at
  a mutable ref (a branch, a `@v4` tag) and run with write credentials, or run
  after its download failed, are findings.
- **Isolation and grant checks that prove less than they claim** — a probe set,
  smoke test or verification step reported as proof of isolation or of a grant:
  list every way to reach the resource (recursive, list, batch and history reads
  beside the direct get) and check each is probed, and check that the expected
  result could not come from elsewhere (a public resource any credential can
  read, a default that already allows it).
- **Missing limits** — no rate limit, no size cap on uploads or request bodies, no
  pagination cap, unbounded loop driven by user input (DoS surface).
- **Dependency and supply chain** — a newly added dependency doing something the
  change did not need, a pinned version loosened, a postinstall script.

Report the exploit path concretely: what an attacker sends, and what they get.
