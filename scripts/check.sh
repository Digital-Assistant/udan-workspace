#!/usr/bin/env bash
# Single entry for the workspace checks. CI and the git hooks both call this script.
# Usage: scripts/check.sh [--staged]
#   --staged   lint and link-check only the staged Markdown files (used by the pre-commit hook)
# Each step prints PASS, SKIP or FAIL. The exit code is non-zero when any step fails.
# Needs: bash, git, shellcheck, node 22+ with npx. Optional: jq (realm check), openssl (infra scripts), gitleaks,
# lychee. Tool versions are pinned below.
set -uo pipefail

MARKDOWNLINT_VERSION="0.24.0"
MERMAID_CLI_VERSION="12.0.0"
LIKEC4_VERSION="1.61.1"
MARKDOWN_LINK_CHECK_VERSION="3.15.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

staged=0
[[ "${1:-}" == "--staged" ]] && staged=1

fails=0
pass() { echo "PASS  $1"; }
skip() { echo "SKIP  $1: $2"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }
have() { command -v "$1" >/dev/null 2>&1; }

# Markdown files in scope.
if (( staged )); then
  mapfile -t md_files < <(git diff --cached --name-only --diff-filter=ACMR -- '*.md')
else
  mapfile -t md_files < <(git ls-files '*.md')
fi
# Keep only files that exist (a staged deletion or rename can leave stale names).
existing=()
for f in "${md_files[@]}"; do [[ -f "$f" ]] && existing+=("$f"); done
md_files=("${existing[@]}")

# 1. shellcheck on ./udan, scripts/*.sh and scripts/lib/*.sh.
sh_files=()
[[ -f udan ]] && sh_files+=(udan)
for f in scripts/*.sh scripts/lib/*.sh; do [[ -f "$f" ]] && sh_files+=("$f"); done
if (( ${#sh_files[@]} == 0 )); then
  skip shellcheck "no shell scripts"
elif ! have shellcheck; then
  skip shellcheck "shellcheck not installed"
elif shellcheck "${sh_files[@]}"; then
  pass shellcheck
else
  fail shellcheck
fi

# 2. markdownlint-cli2 (settings in .markdownlint-cli2.yaml).
if (( ${#md_files[@]} == 0 )); then
  skip markdownlint "no Markdown files in scope"
elif ! have npx; then
  skip markdownlint "npx not installed"
elif npx --yes "markdownlint-cli2@${MARKDOWNLINT_VERSION}" "${md_files[@]}"; then
  pass markdownlint
else
  fail markdownlint
fi

# 3. Mermaid blocks in docs/**/*.md must render.
mermaid_files=()
if [[ -d docs ]]; then
  while IFS= read -r f; do
    grep -q '^```mermaid' "$f" && mermaid_files+=("$f")
  done < <(git ls-files 'docs/*.md' 'docs/**/*.md')
fi
if (( ${#mermaid_files[@]} == 0 )); then
  skip mermaid "no Mermaid blocks under docs/"
elif ! have npx; then
  skip mermaid "npx not installed"
else
  tmp="$(mktemp -d)"
  echo '{"args":["--no-sandbox"]}' > "$tmp/puppeteer.json"
  mm_ok=1
  for f in "${mermaid_files[@]}"; do
    # Render each Mermaid block of the file; mermaid-cli reads Markdown and renders every block.
    if ! npx --yes "@mermaid-js/mermaid-cli@${MERMAID_CLI_VERSION}" -p "$tmp/puppeteer.json" \
      -i "$f" -o "$tmp/out.md" >/dev/null 2>"$tmp/err.txt"; then
      echo "mermaid error in $f" >&2
      cat "$tmp/err.txt" >&2
      mm_ok=0
    fi
  done
  rm -rf "$tmp"
  if (( mm_ok )); then pass mermaid; else fail mermaid; fi
fi

# 4. LikeC4 model validation.
if [[ ! -d docs/likec4 ]]; then
  skip likec4 "docs/likec4 does not exist yet"
elif ! have npx; then
  skip likec4 "npx not installed"
elif npx --yes "likec4@${LIKEC4_VERSION}" validate docs/likec4; then
  pass likec4
else
  fail likec4
fi

# 5. Links (relative links at minimum; external links are not fetched, so the check works offline).
if (( ${#md_files[@]} == 0 )); then
  skip links "no Markdown files in scope"
elif have lychee; then
  if lychee --offline --no-progress "${md_files[@]}"; then pass links; else fail links; fi
elif have npx; then
  link_ok=1
  for f in "${md_files[@]}"; do
    npx --yes "markdown-link-check@${MARKDOWN_LINK_CHECK_VERSION}" -q -c scripts/markdown-link-check.json "$f" \
      || link_ok=0
  done
  if (( link_ok )); then pass links; else fail links; fi
else
  skip links "neither lychee nor npx installed"
fi

# 6. No file names a repository missing from repos.yaml.
if scripts/check-unknown-repos.sh && { [[ ! -f scripts/test-check-unknown-repos.sh ]] || scripts/test-check-unknown-repos.sh; }; then
  pass unknown-repos
else
  fail unknown-repos
fi

# 7. Public dev Keycloak realm files (names, clients, no secrets beyond the dev value).
if [[ ! -d infra/keycloak/realms ]]; then
  skip realms "infra/keycloak/realms does not exist"
elif ! have jq; then
  skip realms "jq not installed"
elif scripts/check-realms.sh && scripts/test-check-realms.sh; then
  pass realms
else
  fail realms
fi

# 8. infra-env.sh and infra-certs.sh against a temporary folder.
if [[ ! -f scripts/test-infra-env-certs.sh ]]; then
  skip infra-scripts "scripts/test-infra-env-certs.sh does not exist"
elif ! have openssl; then
  skip infra-scripts "openssl not installed"
elif scripts/test-infra-env-certs.sh; then
  pass infra-scripts
else
  fail infra-scripts
fi

# 9. ./udan without Docker (fake docker, temp workspace, local git repositories).
if [[ ! -f scripts/test-udan.sh ]]; then
  skip udan "scripts/test-udan.sh does not exist"
elif ! have jq; then
  skip udan "jq not installed"
elif ! have openssl; then
  skip udan "openssl not installed"
elif scripts/test-udan.sh; then
  pass udan
else
  fail udan
fi

# 10. Secret scan of the working tree and history (the pre-commit hook scans the staged change instead).
if (( staged )); then
  skip gitleaks "staged mode: the hook runs gitleaks on the staged change"
elif ! have gitleaks; then
  skip gitleaks "gitleaks not installed"
elif gitleaks detect --no-banner --redact; then
  pass gitleaks
else
  fail gitleaks
fi

if (( fails > 0 )); then
  echo "RESULT: ${fails} check(s) failed."
  exit 1
fi
echo "RESULT: all checks passed or skipped."
