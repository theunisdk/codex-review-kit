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
  for f in .coderabbit.yaml .coderabbit.yml .coderabbit.config.ts; do
    [ -e "$f" ] && { cfg="$f"; break; }
  done
  if [ -z "$cfg" ]; then
    _path_rules_set no_config "" ""
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
    '{status: $s, config: (if $c == "" then null else $c end), rules: null, matched: null,
      warning: (if $w == "" then null else $w end)}')"
}

# The one-line findings.md note: a blockquote when a warning stands, plain otherwise.
path_rules_note() {
  local cfg rules matched
  if [ -n "$PATH_RULES_WARNING" ]; then
    printf '> **Path rules NOT fully applied:** %s.\n' "$PATH_RULES_WARNING"
    return
  fi
  cfg="$(jq -r '.config // ""' <<< "$PATH_RULES_JSON")"
  rules="$(jq -r '.rules // 0' <<< "$PATH_RULES_JSON")"
  matched="$(jq -r '.matched // 0' <<< "$PATH_RULES_JSON")"
  case "$PATH_RULES_STATUS" in
    applied)   printf 'Path rules: %s of the %s `%s` path_instructions match the change set and reached every lens.\n' "$matched" "$rules" "$cfg" ;;
    no_match)  printf 'Path rules: none of the %s `%s` path_instructions match the change set.\n' "$rules" "$cfg" ;;
    no_rules)  printf 'Path rules: `%s` sets no path_instructions.\n' "$cfg" ;;
    no_config) printf 'Path rules: no CodeRabbit config.\n' ;;
  esac
}

_path_rules_read() { # _path_rules_read <config> <changed-files> <section-out> — JSON on stdout
  python3 - "$1" "$2" "$3" <<'PYRULES'
import json, re, sys

cfg, changed, section = sys.argv[1:4]


def emit(status, warning=None, rules=None, matched=None):
    print(json.dumps({"status": status, "config": cfg, "rules": rules,
                      "matched": matched, "warning": warning}))
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
    with open(cfg, encoding="utf-8") as fh:
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

reviews = d.get("reviews")
pi = reviews.get("path_instructions") if isinstance(reviews, dict) else None
if reviews is not None and not isinstance(reviews, dict):
    emit("invalid", "`%s` sets reviews to a %s rather than a mapping, so no path_instructions reached "
         "the lenses" % (cfg, type(reviews).__name__))
if pi is None or pi == []:
    emit("no_rules", rules=0, matched=0)
if not isinstance(pi, list):
    emit("invalid", "`%s` sets reviews.path_instructions to a %s rather than a list, so none of it "
         "reached the lenses" % (cfg, type(pi).__name__))


def braces(p, budget):
    depth, start = 0, None
    for i, c in enumerate(p):
        if c == "{":
            if depth == 0:
                start = i
            depth += 1
        elif c == "}" and depth:
            depth -= 1
            if depth == 0:
                parts, d, cur = [], 0, ""
                for ch in p[start + 1:i]:
                    if ch == "," and d == 0:
                        parts.append(cur)
                        cur = ""
                        continue
                    d += (ch == "{") - (ch == "}")
                    cur += ch
                parts.append(cur)
                if len(parts) < 2:
                    continue
                budget[0] -= len(parts)
                if budget[0] < 0:
                    raise ValueError("too many brace alternatives")
                return [x for part in parts for x in braces(p[:start] + part + p[i + 1:], budget)]
    return [p]


def segment(s):
    out, i = "", 0
    while i < len(s):
        c = s[i]
        if c == "*":
            while i + 1 < len(s) and s[i + 1] == "*":
                i += 1
            out += "[^/]*"
        elif c == "?":
            out += "[^/]"
        elif c == "[":
            j = i + 1
            if s[j:j + 1] in ("!", "^"):
                j += 1
            if s[j:j + 1] == "]":
                j += 1
            j = s.find("]", j)
            if j < 0:
                out += re.escape(c)
            else:
                body = s[i + 1:j]
                neg = body[:1] in ("!", "^")
                body = body[1:] if neg else body
                out += ("[^/" if neg else "[") + re.sub(r"([\\\[\]])", r"\\\1", body) + "]"
                i = j
        else:
            out += re.escape(c)
        i += 1
    return out


# minimatch semantics, with dotfiles matched: `**` spans directories, `*` and `?`
# stay inside one, and a pattern without a slash matches top-level paths only.
def glob_regex(p):
    alts = []
    for q in braces(p, [256]):
        q = re.sub(r"^(\./)+", "", q).lstrip("/")
        if q.endswith("/"):
            q += "**"
        parts = q.split("/")
        r = ""
        for k, s in enumerate(parts):
            last = k == len(parts) - 1
            if s == "**":
                r += ".*" if last else "(?:[^/]+/)*"
            else:
                r += segment(s) + ("" if last else "/")
        alts.append("(?:%s)" % r)
    return re.compile("|".join(alts), re.DOTALL)


rules, bad = [], []
for n, e in enumerate(pi, 1):
    path = e.get("path") if isinstance(e, dict) else None
    text = e.get("instructions") if isinstance(e, dict) else None
    if not (isinstance(path, str) and path.strip() and isinstance(text, str) and text.strip()):
        bad.append(n)
        continue
    try:
        rules.append((path.strip(), text.strip(), glob_regex(path.strip())))
    except (re.error, ValueError, RecursionError):
        bad.append(n)

with open(changed, encoding="utf-8", errors="surrogateescape") as fh:
    files = [l.rstrip("\n") for l in fh if l.strip()]

hits = []
for path, text, rx in rules:
    matched = [f for f in files if rx.fullmatch(f)]
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

warning = None
if bad:
    many = len(bad) > 1
    warning = ("`%s` reviews.path_instructions entr%s %s lack%s a non-empty string path and "
               "instructions, or a usable glob, so %s did NOT reach the lenses, and CodeRabbit "
               "may discard the whole file" % (cfg, "ies" if many else "y",
                                               ", ".join("#%d" % n for n in bad),
                                               "" if many else "s", "they" if many else "it"))
emit("invalid" if bad else "applied" if hits else "no_match", warning,
     rules=len(pi), matched=len(hits))
PYRULES
}
