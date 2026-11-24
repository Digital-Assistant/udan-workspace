#!/usr/bin/env bash
# Test for check-unknown-repos.sh: '-' and '_' are equal and case is ignored; unknown names still fail.
# Usage: scripts/test-check-unknown-repos.sh. Exit code: 0 ok, 1 a check failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q

fails=0
# case <description> <expected exit code> <file content>
case_() {
  printf '%s\n' "$3" >"$tmp/f.txt"
  git -C "$tmp" add f.txt
  "$ROOT/scripts/check-unknown-repos.sh" --path "$tmp" >/dev/null 2>&1
  local rc=$?
  if (( rc == $2 )); then echo "  ok    $1"; else echo "  FAIL  $1 (exit $rc, expected $2)" >&2; fails=$((fails + 1)); fi
}

case_ "exact name as listed" 0 "see Digital_Assistant_Client"
case_ "lower case with dashes matches an underscore entry" 0 "see digital-assistant-client"
case_ "upper case with underscores matches a dash entry" 0 "see DIGITAL_ASSISTANT_SERVER"
case_ "mixed separators match" 0 "see Digital-Assistant_SDK"
case_ "unknown repository name fails" 1 "see Digital""-Assistant-Unknown"

if (( fails > 0 )); then echo "test-check-unknown-repos: ${fails} case(s) failed." >&2; exit 1; fi
echo "test-check-unknown-repos: all cases passed."
