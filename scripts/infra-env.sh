#!/usr/bin/env bash
# Create infra/.env from infra/.env.example, or check that it is complete.
# Usage: scripts/infra-env.sh [--dir INFRA_DIR] [--check]
#   --dir DIR   infra folder (default: <repo>/infra)
#   --check     do not create anything; print every variable of .env.example that .env lacks. Exit 1 if any.
# An existing .env is never overwritten. A new .env gets mode 600. Needs: bash.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
infra="$ROOT/infra"
check=0
while (( $# > 0 )); do
  case "$1" in
    --dir)
      infra="${2:?--dir needs a directory}"
      shift 2
      ;;
    --check)
      check=1
      shift
      ;;
    -h | --help)
      sed -n '2,6p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

example="$infra/.env.example"
env_file="$infra/.env"
[[ -f "$example" ]] || { echo "infra-env: $example not found" >&2; exit 2; }

names() { sed -n -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$1"; }

if (( check )); then
  [[ -f "$env_file" ]] || { echo "infra-env: $env_file does not exist" >&2; exit 1; }
  missing=0
  while IFS= read -r name; do
    if ! names "$env_file" | grep -qx "$name"; then
      echo "missing: $name"
      missing=1
    fi
  done < <(names "$example")
  if (( missing )); then exit 1; fi
  echo "infra-env: $env_file has every variable of .env.example."
  exit 0
fi

if [[ -f "$env_file" ]]; then
  echo "infra-env: $env_file exists, left unchanged."
  exit 0
fi
(umask 077 && cp "$example" "$env_file")
chmod 600 "$env_file"
echo "infra-env: created $env_file (mode 600) from .env.example."
