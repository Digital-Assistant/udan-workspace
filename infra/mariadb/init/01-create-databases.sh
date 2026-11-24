#!/bin/bash
# Runs once, on an empty data volume (docker-entrypoint-initdb.d).
# Creates the databases and the application user. Passwords come from the compose environment
# (MYSQL_ROOT_PASSWORD, UDAN_DB_PASSWORD); nothing is stored in this file.
set -euo pipefail

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is not set}"
: "${UDAN_DB_PASSWORD:?UDAN_DB_PASSWORD is not set}"

# Escape single quotes and backslashes for the SQL string literal.
pw=${UDAN_DB_PASSWORD//\\/\\\\}
pw=${pw//\'/\\\'}

mariadb -uroot -p"${MYSQL_ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS keycloak;
CREATE DATABASE IF NOT EXISTS udan;

CREATE USER IF NOT EXISTS 'udan'@'%' IDENTIFIED BY '${pw}';
CREATE USER IF NOT EXISTS 'udan'@'localhost' IDENTIFIED BY '${pw}';

GRANT ALL PRIVILEGES ON \`keycloak\`.* TO 'udan'@'%';
GRANT ALL PRIVILEGES ON \`keycloak\`.* TO 'udan'@'localhost';

GRANT ALL PRIVILEGES ON \`udan\`.* TO 'udan'@'%';
GRANT ALL PRIVILEGES ON \`udan\`.* TO 'udan'@'localhost';

FLUSH PRIVILEGES;
SQL
