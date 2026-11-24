#!/usr/bin/env bash
# Fail when a file names a UDAN repository (Digital-Assistant-* or Digital_Assistant_*) that repos.yaml
# does not list. The allowed set comes from repos.yaml (path: and url: fields); no name is hard-coded here.
#
# Usage: check-unknown-repos.sh [--path DIR] [FILE...]
#   no arguments   scan every file `git ls-files` lists in the workspace
#   FILE...        scan these files only
#   --path DIR     scan the tracked files of another checkout (for example a cloned repository)
# The manifest is always this workspace's repos.yaml. Matching ignores case and treats - and _ as equal.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/repos.yaml"
PATTERN='Digital[-_]Assistant[-_][A-Za-z]+'

scan_dir="$ROOT"
files=()
while (( $# > 0 )); do
  case "$1" in
    --path)
      scan_dir="${2:?--path needs a directory}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,9p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      files+=("$1")
      shift
      ;;
  esac
done

if [[ ! -f "$MANIFEST" ]]; then
  echo "FAIL: manifest not found: $MANIFEST" >&2
  exit 2
fi

# Allowed names: the last path segment of every "path:" value and of every "url:" value (minus .git).
mapfile -t allowed < <(
  sed -n -E 's/^[[:space:]]*-?[[:space:]]*(path|url):[[:space:]]*([^#[:space:]]+).*/\2/p' "$MANIFEST" |
    sed -E 's#/+$##; s#.*/##; s#\.git$##' |
    grep -E -i "^${PATTERN}\$" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | sort -u
)
if (( ${#allowed[@]} == 0 )); then
  echo "FAIL: no repository names found in $MANIFEST" >&2
  exit 2
fi

cd "$scan_dir"
if (( ${#files[@]} == 0 )); then
  mapfile -t files < <(git ls-files)
fi

bad=0
for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue
  while IFS=: read -r line match; do
    [[ -n "$line" ]] || continue
    lower="$(tr '[:upper:]_' '[:lower:]-' <<<"$match")"
    ok=0
    for a in "${allowed[@]}"; do
      if [[ "$lower" == "$a" ]]; then ok=1; break; fi
    done
    if (( ok == 0 )); then
      echo "$f:$line: unknown repository name '$match' (not in repos.yaml)" >&2
      bad=1
    fi
  done < <(grep -n -o -I -i -E "$PATTERN" "$f" | sed -E 's/^([0-9]+):/\1:/' || true)
done

if (( bad != 0 )); then
  echo "FAIL: names found that repos.yaml does not list. Use repos.local.yaml for extra repositories." >&2
  exit 1
fi
echo "OK: every Digital-Assistant-* name is listed in repos.yaml (${#allowed[@]} allowed)."
