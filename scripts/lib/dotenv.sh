#!/usr/bin/env bash
# Reader for infra/.env. Source it. It gives the same values as Docker Compose for the subset below, which
# infra/README.md documents. The file is read, never sourced.
#
# Subset:
#   - blank lines and lines that start with # are skipped; a trailing CR is ignored (CRLF files work)
#   - KEY=VALUE; "export " before KEY and spaces around KEY and = are allowed
#   - unquoted VALUE: spaces around it are removed; " #" (a space, then #) starts a comment
#   - 'single-quoted': taken as it is, including $, # and \
#   - "double-quoted": taken as it is; it must not contain $ or \
#   - text after the closing quote is ignored (Compose does the same)
#   - when a KEY appears twice, the last line wins
# Outside the subset (Compose would expand or unescape it, or refuse the file): $ in an unquoted or
# double-quoted value, \ in a double-quoted value, a quote that is not closed on the same line.

# Shared awk code: parse(line) sets K (key), V (value) and BAD (1 = outside the subset). It returns 0 for a line
# without an assignment.
_DOTENV_AWK='
  function parse(line,   eq, v, q, rest, end, p) {
    sub(/\r$/, "", line)
    if (line ~ /^[ \t]*(#|$)/) return 0
    sub(/^[ \t]+/, "", line)
    if (line ~ /^export[ \t]+/) sub(/^export[ \t]+/, "", line)
    eq = index(line, "=")
    if (eq == 0) return 0
    K = substr(line, 1, eq - 1)
    sub(/[ \t]+$/, "", K)
    v = substr(line, eq + 1)
    sub(/^[ \t]+/, "", v)
    BAD = 0
    q = substr(v, 1, 1)
    if (q == "\047" || q == "\"") {
      rest = substr(v, 2)
      end = index(rest, q)
      if (end == 0) { V = ""; BAD = 1; return 1 }
      V = substr(rest, 1, end - 1)
      if (q == "\"" && V ~ /[$\\]/) BAD = 1
    } else {
      p = index(v, " #")
      if (p > 0) v = substr(v, 1, p - 1)
      sub(/[ \t]+$/, "", v)
      V = v
      if (V ~ /[$]/) BAD = 1
    }
    return 1
  }
'

# dotenv_get FILE NAME: prints the value of NAME. Returns 0 when set, 1 when not set (or no file), 3 when the
# value is outside the subset (nothing is printed then).
dotenv_get() {
  [[ -f "$1" ]] || return 1
  awk -v want="$2" "$_DOTENV_AWK"'
    parse($0) && K == want { found = 1; val = V; bad = BAD }
    END {
      if (!found) exit 1
      if (bad) exit 3
      printf "%s", val
    }
  ' "$1"
}

# dotenv_keys FILE: prints every KEY that has an assignment, one per line, in file order.
dotenv_keys() {
  [[ -f "$1" ]] || return 0
  awk "$_DOTENV_AWK"'parse($0) { print K }' "$1"
}
