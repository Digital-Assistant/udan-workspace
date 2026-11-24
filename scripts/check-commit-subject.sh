#!/usr/bin/env bash
# Refuse a commit message whose subject is not a Conventional Commit. Used by the commit-msg hook.
# Usage: check-commit-subject.sh <message-file>
# Merge and revert commits that git generates are accepted.
set -euo pipefail

file="${1:?message file}"
subject="$(sed -n '/^[^#]/{p;q;}' "$file")"
pattern='^(feat|fix|perf|refactor|docs|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?: .+'

if [[ "$subject" =~ ^(Merge|Revert)\  ]] || [[ "$subject" =~ $pattern ]]; then
  exit 0
fi
echo "Commit subject must look like 'feat: add x' or 'fix(api): y'." >&2
echo "Types: feat, fix, perf, refactor, docs, test, build, ci, chore, revert. Got: $subject" >&2
exit 1
