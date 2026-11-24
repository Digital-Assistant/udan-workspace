#!/usr/bin/env bash
# Negative tests for check-realms.sh: each case changes a scratch copy of the realm files and expects a failure.
# Usage: scripts/test-check-realms.sh. Needs jq. Exit code: 0 ok, 1 a case failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fails=0
# case_ <description> <expected exit code> <realm file> <jq edit> [sed edit for .env.example]
case_() {
  rm -rf "${tmp:?}/ws"
  mkdir -p "$tmp/ws/scripts" "$tmp/ws/infra/keycloak"
  cp "$ROOT/scripts/check-realms.sh" "$tmp/ws/scripts/"
  cp -r "$ROOT/infra/keycloak/realms" "$tmp/ws/infra/keycloak/"
  cp "$ROOT/infra/.env.example" "$tmp/ws/infra/.env.example"
  local f="$tmp/ws/infra/keycloak/realms/$3"
  jq "$4" "$f" >"$tmp/edit.json" && mv "$tmp/edit.json" "$f"
  [[ -n "${5:-}" ]] && sed -i -E "$5" "$tmp/ws/infra/.env.example"
  "$tmp/ws/scripts/check-realms.sh" >/dev/null 2>&1
  local rc=$?
  if (( rc == $2 )); then echo "  ok    $1"; else echo "  FAIL  $1 (exit $rc, expected $2)" >&2; fails=$((fails + 1)); fi
}

U=udan-realm.json
P=udan-plugin-realm.json
be='.clients |= map(if .clientId == "backend-service"'

case_ "unchanged files pass" 0 "$U" '.'
case_ "wildcard redirect host fails" 1 "$U" "$be then .redirectUris += [\"https://*.example.org/*\"] else . end)"
case_ "wildcard webOrigin without path fails" 1 "$U" "$be then .webOrigins += [\"https://*.corp.example\"] else . end)"
case_ "upper-case scheme fails" 1 "$P" "$be then .attributes = {\"x\": \"HTTPS://kc.example.net\"} else . end)"
case_ "scheme-relative rootUrl fails" 1 "$P" "$be then .rootUrl = \"//cdn.example.com\" else . end)"
case_ "upper-case local host passes" 0 "$U" "$be then .rootUrl = \"HTTP://LOCALHOST:8080\" else . end)"
case_ "backend-service without secret fails (UDAN)" 1 "$U" "$be then del(.secret) else . end)"
case_ "backend-service without secret fails (UDAN-Plugin)" 1 "$P" "$be then del(.secret) else . end)"
case_ "backend-service with another secret fails" 1 "$U" "$be then .secret = \"other\" else . end)"
case_ "service accounts on in UDAN-Plugin fails" 1 "$P" "$be then .serviceAccountsEnabled = true else . end)"
case_ "service accounts off in UDAN fails" 1 "$U" "$be then .serviceAccountsEnabled = false else . end)"
case_ "udan-extension without standard flow fails" 1 "$P" \
  '.clients |= map(if .clientId == "udan-extension" then .standardFlowEnabled = false else . end)'
case_ "single-quoted .env.example value with comment and CR passes" 0 "$U" '.' \
  "s/^(KC_BACKEND_SERVICE_SECRET=)(.*)$/\\1'\\2' # dev\\r/"
case_ "different .env.example value fails" 1 "$U" '.' 's/^(KC_BACKEND_SERVICE_SECRET=).*$/\1other/'

if (( fails > 0 )); then echo "test-check-realms: ${fails} case(s) failed." >&2; exit 1; fi
echo "test-check-realms: all cases passed."
