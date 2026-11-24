# Keycloak realms (dev only)

Keycloak imports these files at start (`--import-realm`, mounted at `/opt/keycloak/data/import`). An import only
seeds a fresh Keycloak: a realm that already exists in the database is skipped. To pick up a change, wipe the
Keycloak data or change the running realm through the admin API.

| File | Realm | Clients in the file |
|---|---|---|
| `udan-realm.json` | `UDAN` | `backend-service` (confidential, service accounts) |
| `udan-plugin-realm.json` | `UDAN-Plugin` | `backend-service` (confidential, no service accounts), `udan-extension` (public, PKCE S256) |

Keycloak adds its own built-in clients (`account`, `account-console`, `admin-cli`, `broker`,
`realm-management`, `security-admin-console`), default client scopes, roles and signing keys at import. The files
hold no users, no email server, no identity providers and no keys. The `master` realm is not shipped: Keycloak
creates it with its defaults and the admin user from `KEYCLOAK_ADMIN` and `KEYCLOAK_ADMIN_PASSWORD`.

`udan-extension` redirects to `https://lcnkfnijlogkgifbfhkcnmndhabnloco.chromiumapp.org/*`, the extension id that
the Client's `manifest.json` key pins for unpacked builds. Add other ids through the admin API.

## Dev secret

These values are for local development only. Never use them on a shared or public server.

| Variable | Dev value | Where it is used |
|---|---|---|
| `KC_BACKEND_SERVICE_SECRET` | `dev-only-backend-service-secret-change-me` | `secret` of `backend-service` in both realms |

The value is written literally in both JSON files and must equal the default in `infra/.env.example`.
`scripts/check-realms.sh` checks both. After the Server's cutover to this workspace, the Server reads the secret
from the `backend-service` client of `udan-realm.json` (its `sync-credentials.sh`), so a literal value keeps that
working.

To use another value, change it in both JSON files and in `infra/.env`, then re-import on a fresh Keycloak.

## Service accounts

`backend-service` has service accounts (the client-credentials grant) in `UDAN` only. The Server's pre-flight
check and `./udan doctor` request a client-credentials token there. In `UDAN-Plugin` nothing uses that grant, so
it is off, as in the original realm export. `scripts/check-realms.sh` checks both settings.

## Test users

There are none. Create a local test user through the admin console or the admin API after start.
