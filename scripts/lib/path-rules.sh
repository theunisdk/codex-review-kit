#!/usr/bin/env bash
# Read the CodeRabbit config's reviews.path_instructions and keep the rules whose
# glob matches a changed file, so the lenses grade those files against the same
# path-scoped house rules the PR gate does. Read on every run rather than copied
# into the rubric at onboarding: a copy drifts from the file CodeRabbit reads.
#
# This file is synced from the kit — do not edit it in a repo.

# collect_path_rules <changed-files> <prompt-section-out>
# Writes the prompt section (empty when no rule applies) and sets PATH_RULES_JSON,
# PATH_RULES_STATUS and PATH_RULES_WARNING. Statuses that are a real "nothing":
# no_config, no_rules, no_match. applied means at least one rule reached the
# lenses. Every other status — not_inspected, no_parser, unparseable, invalid,
# failed — carries a warning: the lenses graded without some or all of the rules.
collect_path_rules() {
  local changed="$1" section="$2" cfg="" f rc err
  : > "$section"
  for f in .coderabbit.yaml .coderabbit.yml .coderabbit.config.ts coderabbit.yaml coderabbit.yml; do
    [ -e "$f" ] && { cfg="$f"; break; }
  done
  if [ -z "$cfg" ]; then
    _path_rules_set no_config "" ""
  elif [ "$cfg" = coderabbit.yaml ] || [ "$cfg" = coderabbit.yml ]; then
    _path_rules_set not_inspected "$cfg" "\`$cfg\` is not one of CodeRabbit's documented config names, so it is not read here and its path_instructions did NOT reach the lenses; if it is the gate's active config, rename it \`.$cfg\`"
  elif [ "$cfg" = .coderabbit.config.ts ]; then
    _path_rules_set not_inspected "$cfg" "\`$cfg\` is the active CodeRabbit config and is not read here, so its path_instructions did NOT reach the lenses"
  elif [ ! -f "$cfg" ] || [ ! -r "$cfg" ]; then
    _path_rules_set failed "$cfg" "\`$cfg\` cannot be read, so its path_instructions did NOT reach the lenses"
  elif ! command -v python3 >/dev/null 2>&1; then
    _path_rules_set no_parser "$cfg" "python3 is not installed, so \`$cfg\` path_instructions were NOT read and did NOT reach the lenses"
  else
    _path_rules_read "$cfg" "$changed" "$section" > "$section.json" 2> "$section.err"; rc=$?
    err="$(grep -m1 . "$section.err" 2>/dev/null | cut -c1-160)"
    if [ "$rc" -eq 0 ] && PATH_RULES_JSON="$(jq -ce 'select(type == "object" and (.status | type) == "string")' "$section.json" 2>/dev/null)" \
        && [ -n "$PATH_RULES_JSON" ]; then
      PATH_RULES_STATUS="$(jq -r '.status' <<< "$PATH_RULES_JSON")"
      PATH_RULES_WARNING="$(jq -r '.warning // ""' <<< "$PATH_RULES_JSON")"
    else
      : > "$section"
      _path_rules_set failed "$cfg" "the path-rule reader failed (rc=$rc${err:+: $err}), so \`$cfg\` path_instructions did NOT reach the lenses"
    fi
    rm -f "$section.json" "$section.err"
  fi
}

_path_rules_set() { # _path_rules_set <status> <config> <warning>
  PATH_RULES_STATUS="$1"; PATH_RULES_WARNING="$3"
  PATH_RULES_JSON="$(jq -cn --arg s "$1" --arg c "$2" --arg w "$3" \
    '{status: $s, config: (if $c == "" then null else $c end), rules: null, matched: null, inherits: null,
      warning: (if $w == "" then null else $w end)}')"
}

# The one-line findings.md note: a blockquote when a warning stands, plain otherwise.
path_rules_note() {
  local cfg rules matched inherited
  inherited=""
  [ "$(jq -r '.inherits // false' <<< "$PATH_RULES_JSON")" != true ] \
    || inherited=' Rules an org or central config adds through `inheritance: true` are not read.'
  if [ -n "$PATH_RULES_WARNING" ]; then
    printf '> **Path rules NOT fully applied:** %s.%s\n' "$PATH_RULES_WARNING" "$inherited"
    return
  fi
  cfg="$(jq -r '.config // ""' <<< "$PATH_RULES_JSON")"
  rules="$(jq -r '.rules // 0' <<< "$PATH_RULES_JSON")"
  matched="$(jq -r '.matched // 0' <<< "$PATH_RULES_JSON")"
  case "$PATH_RULES_STATUS" in
    applied)   printf 'Path rules: %s of the %s `%s` path_instructions match the change set and reached every lens.%s\n' "$matched" "$rules" "$cfg" "$inherited" ;;
    no_match)  printf 'Path rules: none of the %s `%s` path_instructions match the change set.%s\n' "$rules" "$cfg" "$inherited" ;;
    no_rules)  printf 'Path rules: `%s` sets no path_instructions.%s\n' "$cfg" "$inherited" ;;
    no_config) printf 'Path rules: no CodeRabbit config.\n' ;;
  esac
}

# Run from / with absolute paths: started in the repository, python3 would import
# a repo-local yaml.py, json.py or re.py in place of the real module.
_path_rules_read() { # _path_rules_read <config> <changed-files> <section-out> — JSON on stdout
  local a=() p
  for p in "$1" "$2" "$3"; do
    case "$p" in /*) a+=("$p") ;; *) a+=("$PWD/$p") ;; esac
  done
  ( cd / && python3 - "${a[@]}" "$1" ) <<'PYRULES'
import json, re, sys

path, changed, section, cfg = sys.argv[1:5]


def emit(status, warning=None, rules=None, matched=None, inherits=None):
    print(json.dumps({"status": status, "config": cfg, "rules": rules, "matched": matched,
                      "inherits": inherits, "warning": warning}))
    sys.exit(0)


try:
    import yaml
except ImportError:
    emit("no_parser", "the python3 yaml module (PyYAML) is not installed, so `%s` path_instructions "
         "were NOT read and did NOT reach the lenses - install it: python3 -m pip install pyyaml" % cfg)


class DuplicateKey(yaml.constructor.ConstructorError):
    pass


# PyYAML keeps the last of a duplicated key; CodeRabbit's parser rejects the file.
class StrictLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _value_node in node.value:
            if key_node.tag == "tag:yaml.org,2002:merge":
                continue
            key = self.construct_object(key_node, deep=deep)
            try:
                if key in seen:
                    raise DuplicateKey(None, None, "duplicate key %r" % (key,), key_node.start_mark)
                seen.add(key)
            except TypeError:
                continue
        return super().construct_mapping(node, deep=deep)


try:
    with open(path, encoding="utf-8") as fh:
        d = yaml.load(fh, Loader=StrictLoader)
except Exception as e:
    msg = (str(e).splitlines() or [type(e).__name__])[0][:120]
    emit("unparseable", "`%s` does not parse (%s), so its path_instructions did NOT reach the lenses, "
         "and CodeRabbit discards the whole file and reviews with defaults" % (cfg, msg))
if d is None:
    d = {}
if not isinstance(d, dict):
    emit("unparseable", "`%s` is not a YAML mapping, so its path_instructions did NOT reach the lenses, "
         "and CodeRabbit discards the whole file and reviews with defaults" % cfg)

def kind(v):
    return "null" if v is None else type(v).__name__


inherits = d.get("inheritance") is True
reviews = d.get("reviews")
if "reviews" in d and not isinstance(reviews, dict):
    emit("invalid", "`%s` sets reviews to %s rather than a mapping, so no path_instructions reached "
         "the lenses, and CodeRabbit may discard the whole file" % (cfg, kind(reviews)), inherits=inherits)
pi = reviews.get("path_instructions") if isinstance(reviews, dict) else None
if not isinstance(reviews, dict) or "path_instructions" not in reviews or pi == []:
    emit("no_rules", rules=0, matched=0, inherits=inherits)
if not isinstance(pi, list):
    emit("invalid", "`%s` sets reviews.path_instructions to %s rather than a list, so none of it "
         "reached the lenses, and CodeRabbit may discard the whole file" % (cfg, kind(pi)), inherits=inherits)


def split_top(body):
    parts, d, cur, i = [], 0, "", 0
    while i < len(body):
        ch = body[i]
        if ch == "\\":
            cur += body[i:i + 2]
            i += 2
            continue
        if ch == "," and d == 0:
            parts.append(cur)
            cur = ""
        else:
            d += (ch == "{") - (ch == "}")
            cur += ch
        i += 1
    parts.append(cur)
    return parts


def brace_range(body, budget):
    m = re.fullmatch(r"(?:(-?[0-9]+)\.\.(-?[0-9]+)|([A-Za-z])\.\.([A-Za-z]))(?:\.\.(-?[0-9]+))?", body)
    if not m:
        return None
    num = m.group(1) is not None
    a, b = (int(m.group(1)), int(m.group(2))) if num else (ord(m.group(3)), ord(m.group(4)))
    step = abs(int(m.group(5) or 1)) or 1
    if (abs(b - a) // step) + 1 > budget[0]:
        raise ValueError("brace range too large")
    width = 0
    if num and any(re.match(r"-?0[0-9]", e) for e in (m.group(1), m.group(2), m.group(5) or "")):
        width = max(len(m.group(1)), len(m.group(2)))
    step = step if b >= a else -step
    out = []
    for x in range(a, b + (1 if b >= a else -1), step):
        if not num:
            out.append(chr(x))
        elif width:
            out.append(("-" if x < 0 else "") + str(abs(x)).zfill(width - (1 if x < 0 else 0)))
        else:
            out.append(str(x))
    return out


def braces(p, budget):
    depth, start, i = 0, None, 0
    while i < len(p):
        c = p[i]
        if c == "\\":
            i += 2
            continue
        if c == "{":
            if depth == 0:
                start = i
            depth += 1
        elif c == "}" and depth:
            depth -= 1
            if depth == 0:
                body = p[start + 1:i]
                parts = brace_range(body, budget) or split_top(body)
                if len(parts) > 1 or brace_range(body, budget):
                    budget[0] -= len(parts)
                    if budget[0] < 0:
                        raise ValueError("too many brace alternatives")
                    return [x for part in parts for x in braces(p[:start] + part + p[i + 1:], budget)]
        i += 1
    return [p]


STAR = object()
GLOBSTAR = object()


# One path segment as tokens: STAR, or a one-character test. Extglobs and POSIX
# classes are refused rather than read as literals, so they surface as invalid.
def segment(s):
    toks, i = [], 0
    while i < len(s):
        c = s[i]
        if c in "@+!*?" and s[i + 1:i + 2] == "(":
            raise ValueError("extglob")
        if c == "\\" and i + 1 < len(s):
            toks.append(s[i + 1].__eq__)
            i += 2
            continue
        if c == "*":
            if not toks or toks[-1] is not STAR:
                toks.append(STAR)
        elif c == "?":
            toks.append(lambda ch: True)
        elif c == "[":
            j = i + 1
            if s[j:j + 1] in ("!", "^"):
                j += 1
            if s[j:j + 1] == "]":
                j += 1
            j = s.find("]", j)
            if j < 0:
                toks.append(c.__eq__)
            else:
                body = s[i + 1:j]
                if "[:" in body:
                    raise ValueError("POSIX class")
                neg = body[:1] in ("!", "^")
                body = body[1:] if neg else body
                rx = re.compile(("[^" if neg else "[") + re.sub(r"([\\\[\]^])", r"\\\1", body) + "]", re.DOTALL)
                toks.append(lambda ch, rx=rx: rx.fullmatch(ch) is not None)
                i = j
        else:
            toks.append(c.__eq__)
        i += 1
    return toks


def segment_match(toks, s):  # greedy wildcard match: O(len(toks) * len(s)), no backtracking blowup
    ti = si = 0
    star, mark = -1, 0
    while si < len(s):
        if ti < len(toks) and toks[ti] is STAR:
            star, mark = ti, si
            ti += 1
        elif ti < len(toks) and toks[ti](s[si]):
            ti += 1
            si += 1
        elif star >= 0:
            mark += 1
            si, ti = mark, star + 1
        else:
            return False
    while ti < len(toks) and toks[ti] is STAR:
        ti += 1
    return ti == len(toks)


# minimatch semantics, with dotfiles matched: `**` spans directories, `*` and `?`
# stay inside one, and a pattern without a slash matches top-level paths only.
def glob_compile(p):
    if p.startswith("!"):
        raise ValueError("negated pattern")
    alts = []
    for q in braces(p, [256]):
        q = re.sub(r"^(\./)+", "", q).lstrip("/")
        if q.endswith("/"):
            q += "**"
        segs = []
        for s in q.split("/"):
            if s == "**":
                if not segs or segs[-1] is not GLOBSTAR:
                    segs.append(GLOBSTAR)
            else:
                segs.append(segment(s))
        alts.append(segs)
    return alts


def glob_match(alts, path):
    parts = path.split("/")
    for segs in alts:
        nxt = [False] * len(parts) + [True]
        for seg in reversed(segs):
            cur = [False] * (len(parts) + 1)
            for j in range(len(parts), -1, -1):
                if seg is GLOBSTAR:
                    cur[j] = nxt[j] or (j < len(parts) and cur[j + 1])
                else:
                    cur[j] = j < len(parts) and nxt[j + 1] and segment_match(seg, parts[j])
            nxt = cur
        if nxt[0]:
            return True
    return False


rules, bad, unread = [], [], []
for n, e in enumerate(pi, 1):
    path = e.get("path") if isinstance(e, dict) else None
    text = e.get("instructions") if isinstance(e, dict) else None
    if not (isinstance(path, str) and path.strip() and isinstance(text, str) and text.strip()):
        bad.append(n)
        continue
    try:
        rules.append((path.strip(), text.strip(), glob_compile(path.strip())))
    except (re.error, ValueError, RecursionError):
        unread.append(n)

with open(changed, encoding="utf-8", errors="surrogateescape") as fh:
    files = [l.rstrip("\n") for l in fh if l.strip()]

hits = []
for path, text, alts in rules:
    matched = [f for f in files if glob_match(alts, f)]
    if matched:
        hits.append((path, text, matched))

if hits:
    with open(section, "w", encoding="utf-8", errors="surrogateescape") as out:
        out.write("## Path-scoped house rules (`%s` `reviews.path_instructions` - CodeRabbit grades "
                  "the matching files against these; a violation in a matching file is a finding "
                  "for every lens)\n" % cfg)
        for path, text, matched in hits:
            shown = ", ".join("`%s`" % f for f in matched[:10])
            more = " and %d more" % (len(matched) - 10) if len(matched) > 10 else ""
            out.write("\n### `%s` - applies to %s%s\n\n%s\n" % (path, shown, more, text))



def entries(ns):
    return "entr%s %s" % ("ies" if len(ns) > 1 else "y", ", ".join("#%d" % n for n in ns))


notes = []
if bad:
    notes.append("%s lack%s a non-empty string path and instructions, so CodeRabbit may discard "
                 "the whole file" % (entries(bad), "" if len(bad) > 1 else "s"))
if unread:
    notes.append("%s use%s a glob this reader cannot match (such as an extglob, a POSIX class, "
                 "a `!` negation, or braces expanding to more than 256 alternatives in total)"
                 % (entries(unread), "" if len(unread) > 1 else "s"))
warning = None
if notes:
    warning = ("`%s` reviews.path_instructions %s; %s did NOT reach the lenses"
               % (cfg, "; ".join(notes), "they" if len(bad) + len(unread) > 1 else "it"))
emit("invalid" if notes else "applied" if hits else "no_match", warning,
     rules=len(pi), matched=len(hits), inherits=inherits)
PYRULES
}
