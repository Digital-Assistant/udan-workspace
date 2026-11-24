#!/usr/bin/env bash
# Test for infra-env.sh and infra-certs.sh. Works in a temporary folder only; never touches the real infra/.
# Usage: scripts/test-infra-env-certs.sh. Needs: bash, openssl. Exit code: 0 ok, 1 a check failed, 2 openssl missing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v openssl >/dev/null 2>&1 || { echo "test-infra-env-certs: openssl not installed" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
infra="$tmp/infra"
mkdir -p "$infra"
cp "$ROOT/infra/.env.example" "$infra/"

fails=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }
expect() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }

enddate() { openssl x509 -in "$1" -noout -enddate; }

# --- env ---
"$ROOT/scripts/infra-env.sh" --dir "$infra" >/dev/null
expect "env: .env created" test -f "$infra/.env"
expect "env: mode 600" test "$(stat -c %a "$infra/.env")" = "600"
echo "EXTRA_KEEP=1" >>"$infra/.env"
"$ROOT/scripts/infra-env.sh" --dir "$infra" >/dev/null
expect "env: second run does not overwrite" grep -q '^EXTRA_KEEP=1$' "$infra/.env"
expect "env: --check passes on a full file" bash -c "'$ROOT/scripts/infra-env.sh' --dir '$infra' --check >/dev/null"
grep -v '^KC_DB_PASSWORD=' "$infra/.env" >"$tmp/env.cut" && mv "$tmp/env.cut" "$infra/.env"
expect "env: --check fails on a missing variable" bash -c "! '$ROOT/scripts/infra-env.sh' --dir '$infra' --check >'$tmp/check.out'"
expect "env: --check names the missing variable" grep -q '^missing: KC_DB_PASSWORD$' "$tmp/check.out"

# --- certs ---
crt="$infra/nginx/localhost/localhost.crt"
"$ROOT/scripts/infra-certs.sh" --dir "$infra" >/dev/null
for f in nginx/localhost/localhost.crt nginx/localhost/localhost.key nginx/localhost/cert.pem nginx/localhost/privkey.pem \
  keycloak/certs/cert.pem keycloak/certs/privkey.pem keycloak/certs/localhost/localhost.crt keycloak/certs/localhost/localhost.key; do
  expect "certs: $f exists" test -f "$infra/$f"
done
expect "certs: SANs are the local names" bash -c "openssl x509 -in '$crt' -noout -ext subjectAltName | grep -q 'localhost' && openssl x509 -in '$crt' -noout -ext subjectAltName | grep -q '127.0.0.1'"
first="$(enddate "$crt")"
sleep 1
"$ROOT/scripts/infra-certs.sh" --dir "$infra" >/dev/null
expect "certs: second run keeps a valid certificate" test "$first" = "$(enddate "$crt")"
expect "certs: --force regenerates" bash -c "'$ROOT/scripts/infra-certs.sh' --dir '$infra' --force | grep -q forced"

# Expiry branch: replace the certificate with one that is valid for 1 day only (under the 7 day limit).
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 -subj "/CN=localhost" \
  -keyout "$infra/nginx/localhost/localhost.key" -out "$crt" 2>/dev/null
short="$(enddate "$crt")"
"$ROOT/scripts/infra-certs.sh" --dir "$infra" >"$tmp/renew.out"
expect "certs: short-lived certificate is regenerated" grep -q 'expiring in' "$tmp/renew.out"
expect "certs: renewed certificate has a new end date" test "$short" != "$(enddate "$crt")"
expect "certs: keycloak copy follows the renewal" cmp -s "$crt" "$infra/keycloak/certs/localhost/localhost.crt"

# Unreadable certificate.
echo "not a certificate" >"$crt"
"$ROOT/scripts/infra-certs.sh" --dir "$infra" >"$tmp/bad.out"
expect "certs: unreadable certificate is regenerated" grep -q 'unreadable' "$tmp/bad.out"

if (( fails > 0 )); then
  echo "test-infra-env-certs: ${fails} check(s) failed." >&2
  exit 1
fi
echo "test-infra-env-certs: all checks passed."
