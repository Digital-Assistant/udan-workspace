#!/usr/bin/env bash
# Repairs a workspace checkout that was made on Windows with core.autocrlf=true.
# Such a checkout has CRLF line endings in files that git stores with LF, so
# ./udan fails in WSL or Linux with "/usr/bin/env: 'bash\r': No such file or
# directory". This rewrites every tracked text file to LF, then refreshes the
# index so git reports a clean tree again.
#
# With .gitattributes (added for Windows support) a fresh clone already gets LF;
# this script is only for checkouts made before that file existed.
#
# Usage: scripts/fix-line-endings.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "not a git checkout: $ROOT" >&2; exit 1; }

# Local settings so checkouts and status agree on LF, matching .gitattributes.
git config core.autocrlf false
git config core.eol lf

fixed=0
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  if grep -Iq $'\r' "$f" 2>/dev/null; then
    sed -i 's/\r$//' "$f"
    fixed=$((fixed + 1))
  fi
done < <(git ls-files -z)

# Re-hash the tracked files so the index stat cache matches the new content.
git add -u

echo "Normalized $fixed file(s) to LF."
git status --short
