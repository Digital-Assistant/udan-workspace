#!/bin/bash
# Runs once, on an empty data volume (docker-entrypoint-initdb.d).
# The image already creates the superuser (POSTGRES_USER). Keycloak needs its own database and user:
# this script creates them from KC_DB_USERNAME and KC_DB_PASSWORD (from infra/.env). No password is stored here.
set -euo pipefail

: "${KC_DB_USERNAME:?KC_DB_USERNAME is not set}"
: "${KC_DB_PASSWORD:?KC_DB_PASSWORD is not set}"

# psql variables are quoted by psql itself (:"name" for identifiers, :'name' for literals).
psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname postgres \
  -v kc_user="${KC_DB_USERNAME}" -v kc_pass="${KC_DB_PASSWORD}" <<'SQL'
CREATE ROLE :"kc_user" WITH LOGIN PASSWORD :'kc_pass';
CREATE DATABASE keycloak OWNER :"kc_user";
SQL
