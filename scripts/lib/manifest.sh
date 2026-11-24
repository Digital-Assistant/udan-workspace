#!/usr/bin/env bash
# Manifest reader for ./udan. Source it, then call manifest_load <workspace root>.
# Reads repos.yaml, then merges the optional, gitignored repos.local.yaml (same format).
# A local entry with a name already in repos.yaml overrides only the fields it sets; a new name is appended.
#
# Format (a flat subset of YAML, parsed with awk; no yq needed):
#   repos:
#     - name: server          # starts an entry
#       path: Some-Dir        # other "key: value" lines belong to the entry above
# Values may be quoted with "..." or '...'. A " #" starts a comment, except inside quotes. Lists, nesting and
# multi-line values are not supported. CRLF line ends are accepted.
#
# Rules (manifest_load fails with a message when one is broken):
#   - repos.yaml must exist and list at least one entry. A file with content must have a "repos:" list with
#     at least one entry; a file with only comments (a plain copy of repos.local.example.yaml) adds nothing.
#   - name: letters, digits, ".", "_" and "-" only; unique within a file.
#   - every entry needs path, url and branch. branch and ref must not start with "-".
#   - in_place: true or false.
#   - without in_place: true, path is a folder inside the workspace: not absolute, no "~", no "." or ".." part.
#
# After manifest_load:
#   MANIFEST_NAMES        array of entry names, in file order (repos.yaml first)
#   manifest_get N KEY    prints the field (empty when unset)
#   manifest_path N       prints the absolute checkout path (relative paths are under the workspace root, ~ expands)
#   manifest_url N        prints the clone URL; a relative local path is made absolute against the workspace root

MANIFEST_KEYS="name path url branch visibility build run ref in_place needs"
MANIFEST_NAMES=()
declare -gA MANIFEST_FIELDS=()
MANIFEST_ROOT=""

# _manifest_parse <file>: prints "name<TAB>key<TAB>value" for each field of each entry.
_manifest_parse() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function unquote(v,   q) {
      q = substr(v, 1, 1)
      if ((q == "\"" || q == "\047") && length(v) >= 2 && substr(v, length(v), 1) == q) return substr(v, 2, length(v) - 2)
      return v
    }
    function value(v,   q, end) {
      v = trim(v)
      q = substr(v, 1, 1)
      if (q == "\"" || q == "\047") {
        end = index(substr(v, 2), q)
        if (end > 0) return substr(v, 2, end - 1)
      }
      sub(/[ \t]+#.*$/, "", v)
      return unquote(trim(v))
    }
    function problem(msg) { printf "manifest: %s:%d: %s\n", FILENAME, FNR, msg > "/dev/stderr"; bad = 1 }
    { sub(/\r$/, "") }
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    { content = 1 }
    /^repos:[ \t]*$/ { inrepos = 1; sawrepos = 1; next }
    /^[^ \t-]/ { inrepos = 0; next }
    !inrepos { next }
    {
      line = $0
      if (match(line, /^[ \t]*-[ \t]+/)) { line = substr(line, RLENGTH + 1); newentry = 1 } else newentry = 0
      if (!match(line, /^[ \t]*[A-Za-z_][A-Za-z0-9_-]*:/)) { problem("not a \"key: value\" line"); next }
      key = trim(substr(line, 1, RLENGTH - 1))
      val = value(substr(line, RLENGTH + 1))
      if (newentry) {
        if (key != "name") { problem("an entry must start with name"); name = ""; next }
        if (val !~ /^[A-Za-z0-9._-]+$/) { problem("name \"" val "\" may only use letters, digits, . _ and -"); name = ""; next }
        if (val in seen) { problem("name \"" val "\" is listed twice"); name = ""; next }
        seen[val] = 1
        entries++
        name = val
      }
      if (name == "") { problem("field outside a valid entry"); next }
      printf "%s\t%s\t%s\n", name, key, val
    }
    END {
      if (content && !sawrepos) { printf "manifest: %s: no \"repos:\" list\n", FILENAME > "/dev/stderr"; bad = 1 }
      else if (sawrepos && entries == 0 && !bad) { printf "manifest: %s: \"repos:\" has no entries\n", FILENAME > "/dev/stderr"; bad = 1 }
      exit bad
    }
  ' "$1"
}

# _manifest_check <name>: validates one merged entry. Prints the problem and returns 1.
_manifest_check() {
  local n="$1" key p part in_place
  for key in path url branch; do
    [[ -n "${MANIFEST_FIELDS["$n|$key"]:-}" ]] || { echo "manifest: entry '$n' has no $key" >&2; return 1; }
  done
  for key in branch ref; do
    [[ "${MANIFEST_FIELDS["$n|$key"]:-}" != -* ]] || { echo "manifest: entry '$n': $key must not start with '-'" >&2; return 1; }
  done
  in_place="${MANIFEST_FIELDS["$n|in_place"]:-false}"
  case "$in_place" in
    true) return 0 ;;
    false) ;;
    *) echo "manifest: entry '$n': in_place must be true or false, not '$in_place'" >&2; return 1 ;;
  esac
  p="${MANIFEST_FIELDS["$n|path"]}"
  local why=""
  case "$p" in
    /* | "~"*) why="it is absolute or starts with ~" ;;
  esac
  if [[ -z "$why" ]]; then
    local parts=()
    IFS=/ read -ra parts <<<"$p"
    for part in "${parts[@]}"; do
      if [[ "$part" == "." || "$part" == ".." ]]; then why="it has a '$part' part"; fi
    done
  fi
  if [[ -n "$why" ]]; then
    echo "manifest: entry '$n': path '$p' must be a folder inside the workspace ($why)." \
      "Use in_place: true for a checkout elsewhere." >&2
    return 1
  fi
}

# manifest_load <workspace root>. Returns 1 when a file is malformed or an entry breaks a rule above.
manifest_load() {
  MANIFEST_ROOT="$1"
  MANIFEST_NAMES=()
  MANIFEST_FIELDS=()
  local file name key val parsed
  [[ -f "$MANIFEST_ROOT/repos.yaml" ]] || { echo "manifest: $MANIFEST_ROOT/repos.yaml not found" >&2; return 1; }
  for file in "$MANIFEST_ROOT/repos.yaml" "$MANIFEST_ROOT/repos.local.yaml"; do
    [[ -f "$file" ]] || continue
    parsed="$(_manifest_parse "$file")" || return 1
    while IFS=$'\t' read -r name key val; do
      [[ -n "$name" ]] || continue
      case " $MANIFEST_KEYS " in
        *" $key "*) ;;
        *) echo "manifest: $(basename "$file"): $name: unknown field '$key' (ignored)" >&2; continue ;;
      esac
      [[ -n "${MANIFEST_FIELDS["$name|name"]+set}" ]] || MANIFEST_NAMES+=("$name")
      MANIFEST_FIELDS["$name|$key"]="$val"
    done <<<"$parsed"
  done
  (( ${#MANIFEST_NAMES[@]} > 0 )) || { echo "manifest: no repositories listed" >&2; return 1; }
  for name in "${MANIFEST_NAMES[@]}"; do
    _manifest_check "$name" || return 1
  done
}

manifest_get() { printf '%s' "${MANIFEST_FIELDS["$1|$2"]:-}"; }

manifest_has() { [[ -n "${MANIFEST_FIELDS["$1|name"]+set}" ]]; }

# _manifest_abs <path>: absolute path; relative to the workspace root, ~ expanded.
_manifest_abs() {
  local p="$1"
  case "$p" in
    "~") p="$HOME" ;;
    \~/*) p="$HOME/${p#\~/}" ;;
  esac
  [[ "$p" == /* ]] || p="$MANIFEST_ROOT/$p"
  printf '%s' "$p"
}

manifest_path() { _manifest_abs "$(manifest_get "$1" path)"; }

manifest_url() {
  local u
  u="$(manifest_get "$1" url)"
  case "$u" in
    *://* | *@*:* | /*) printf '%s' "$u" ;;
    *) _manifest_abs "$u" ;;
  esac
}

# manifest_in_place N: true when the entry is an existing checkout used as is (in_place: true).
manifest_in_place() { [[ "$(manifest_get "$1" in_place)" == "true" ]]; }
