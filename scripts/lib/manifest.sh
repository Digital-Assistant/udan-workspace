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
# multi-line values are not supported.
#
# After manifest_load:
#   MANIFEST_NAMES        array of entry names, in file order (repos.yaml first)
#   manifest_get N KEY    prints the field (empty when unset)
#   manifest_path N       prints the absolute checkout path (relative paths are under the workspace root, ~ expands)
#   manifest_url N        prints the clone URL; a relative local path is made absolute against the workspace root

MANIFEST_KEYS="name path url branch visibility build run ref in_place"
MANIFEST_NAMES=()
declare -gA MANIFEST_FIELDS=()
MANIFEST_ROOT=""

# _manifest_parse <file>: prints "name<TAB>key<TAB>value" for each field of each entry.
_manifest_parse() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
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
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    /^repos:[ \t]*$/ { inrepos = 1; next }
    /^[^ \t-]/ { inrepos = 0; next }
    !inrepos { next }
    {
      line = $0
      if (match(line, /^[ \t]*-[ \t]+/)) { line = substr(line, RLENGTH + 1); newentry = 1 } else newentry = 0
      if (!match(line, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*:/)) next
      key = trim(substr(line, 1, RLENGTH - 1))
      val = value(substr(line, RLENGTH + 1))
      if (newentry) {
        if (key != "name") { printf "manifest: %s:%d: an entry must start with name\n", FILENAME, NR > "/dev/stderr"; bad = 1; next }
        name = val
      }
      if (name == "") { printf "manifest: %s:%d: field before the first name\n", FILENAME, NR > "/dev/stderr"; bad = 1; next }
      printf "%s\t%s\t%s\n", name, key, val
    }
    END { exit bad }
  ' "$1"
}

# manifest_load <workspace root>. Returns 1 when a file is malformed or an entry lacks path or url.
manifest_load() {
  MANIFEST_ROOT="$1"
  MANIFEST_NAMES=()
  MANIFEST_FIELDS=()
  local file name key val parsed known
  for file in "$MANIFEST_ROOT/repos.yaml" "$MANIFEST_ROOT/repos.local.yaml"; do
    [[ -f "$file" ]] || continue
    parsed="$(_manifest_parse "$file")" || return 1
    while IFS=$'\t' read -r name key val; do
      [[ -n "$name" ]] || continue
      case " $MANIFEST_KEYS " in
        *" $key "*) ;;
        *) echo "manifest: $(basename "$file"): $name: unknown field '$key' (ignored)" >&2; continue ;;
      esac
      known=0
      [[ -v "MANIFEST_FIELDS[$name|name]" ]] && known=1
      (( known )) || MANIFEST_NAMES+=("$name")
      MANIFEST_FIELDS["$name|$key"]="$val"
    done <<<"$parsed"
  done
  for name in "${MANIFEST_NAMES[@]}"; do
    for key in path url branch; do
      [[ -n "${MANIFEST_FIELDS[$name|$key]:-}" ]] || { echo "manifest: entry '$name' has no $key" >&2; return 1; }
    done
  done
}

manifest_get() { printf '%s' "${MANIFEST_FIELDS[$1|$2]:-}"; }

manifest_has() { [[ -v "MANIFEST_FIELDS[$1|name]" ]]; }

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
