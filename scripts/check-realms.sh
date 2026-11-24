#!/usr/bin/env bash
# Checks the public dev Keycloak realm files in infra/keycloak/realms/.
# Usage: scripts/check-realms.sh
# Asserts realm names, the exact client list per realm, the public PKCE client, no users, no key material,
# no email addresses, no hosts besides local ones and the pinned dev extension id, and that every client
# secret equals the dev value. When infra/.env.example exists, the dev value must match its
# KC_BACKEND_SERVICE_SECRET default. Exit code: 0 ok, 1 a check failed, 2 jq missing or a file is not JSON.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/infra/keycloak/realms"
ENV_EXAMPLE="$ROOT/infra/.env.example"

# Dev-only value. Must equal KC_BACKEND_SERVICE_SECRET in infra/.env.example.
DEV_SECRET="dev-only-backend-service-secret-change-me"
# Hosts allowed in any string of the realm files.
ALLOWED_HOSTS='^(localhost|127\.0\.0\.1|lcnkfnijlogkgifbfhkcnmndhabnloco\.chromiumapp\.org)$'

command -v jq >/dev/null 2>&1 || { echo "check-realms: jq not installed" >&2; exit 2; }

fails=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }
# assert <file> <description> <jq filter that must output true>
assert() {
  if [[ "$(jq -r "$3" "$1")" == "true" ]]; then ok "$2"; else bad "$(basename "$1"): $2"; fi
}

expected_files=(udan-realm.json udan-plugin-realm.json)
for f in "${expected_files[@]}"; do
  jq empty "$DIR/$f" 2>/dev/null || { echo "check-realms: $f missing or not valid JSON" >&2; exit 2; }
done
# Only the two realm files (plus README.md and .gitkeep) belong in the folder.
for f in "$DIR"/*; do
  case "$(basename "$f")" in udan-realm.json|udan-plugin-realm.json|README.md) ;; *) bad "unexpected file $f" ;; esac
done

U="$DIR/udan-realm.json"
P="$DIR/udan-plugin-realm.json"

echo "udan-realm.json"
assert "$U" "realm is UDAN" '.realm == "UDAN"'
assert "$U" "clients are exactly backend-service" '[.clients[].clientId] == ["backend-service"]'

echo "udan-plugin-realm.json"
assert "$P" "realm is UDAN-Plugin" '.realm == "UDAN-Plugin"'
assert "$P" "clients are exactly backend-service, udan-extension" \
  '([.clients[].clientId] | sort) == ["backend-service", "udan-extension"]'
assert "$P" "udan-extension is public with PKCE S256, no secret, no direct grants" \
  '.clients[] | select(.clientId == "udan-extension")
   | .publicClient == true and .attributes["pkce.code.challenge.method"] == "S256"
     and (has("secret") | not) and .directAccessGrantsEnabled == false and .implicitFlowEnabled == false'
assert "$P" "udan-extension redirects only to chromiumapp.org" \
  '.clients[] | select(.clientId == "udan-extension")
   | (.redirectUris | length > 0) and all(.redirectUris[]; test("^https://[a-p]{32}\\.chromiumapp\\.org/\\*$"))'

for f in "$U" "$P"; do
  echo "$(basename "$f") (common)"
  assert "$f" "no react-app client" 'all(.clients[]; .clientId != "react-app")'
  assert "$f" "backend-service is confidential with service accounts" \
    '.clients[] | select(.clientId == "backend-service")
     | .publicClient == false and .serviceAccountsEnabled == true and .clientAuthenticatorType == "client-secret"'
  assert "$f" "no users" '(.users // []) | length == 0'
  assert "$f" "no key providers or components" '(has("components") | not)'
  assert "$f" "no smtp server, identity providers or federation" \
    '((.smtpServer // {}) | length == 0) and ((.identityProviders // []) | length == 0)
     and ((.userFederationProviders // []) | length == 0)'
  assert "$f" "no private keys, certificates or passwords" \
    '[.. | objects | keys[] | select(test("privateKey|certificate|^password$|^credentials$|^secretData$|^credentialData$"; "i"))] | length == 0'
  # The secret check needs --arg, so it runs outside assert.
  if [[ "$(jq -r --arg s "$DEV_SECRET" '[.. | objects | select(has("secret")) | .secret] | all(. == $s)' "$f")" == "true" ]]
  then ok "every secret equals the dev value"; else bad "$(basename "$f"): a secret differs from the dev value"; fi
  if jq -r '.. | strings' "$f" | grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'; then
    bad "$(basename "$f"): contains an email address"
  else
    ok "no email addresses"
  fi
  hosts_bad="$(jq -r '.. | strings' "$f" | grep -oE '[a-z]+://[^/:"*]+' | sed -E 's#^[a-z]+://##' \
    | grep -vE "$ALLOWED_HOSTS" || true)"
  if [[ -n "$hosts_bad" ]]; then bad "$(basename "$f"): host not allowed: ${hosts_bad//$'\n'/, }"; else ok "only local hosts"; fi
done

echo "dev secret vs infra/.env.example"
if [[ -f "$ENV_EXAMPLE" ]]; then
  env_value="$(sed -nE 's/^KC_BACKEND_SERVICE_SECRET=//p' "$ENV_EXAMPLE" | tail -n 1)"
  env_value="${env_value%\"}"; env_value="${env_value#\"}"
  if [[ "$env_value" == "$DEV_SECRET" ]]; then ok "KC_BACKEND_SERVICE_SECRET matches"; else
    bad "KC_BACKEND_SERVICE_SECRET in infra/.env.example differs from the realm files"; fi
else
  ok "infra/.env.example not present yet (skipped)"
fi

if (( fails > 0 )); then
  echo "check-realms: ${fails} check(s) failed." >&2
  exit 1
fi
echo "check-realms: all checks passed."
