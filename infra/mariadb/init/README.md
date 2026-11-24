# MariaDB init scripts

Files here run in name order on the first start only, when the data volume is empty
(`/docker-entrypoint-initdb.d`).

- `01-create-databases.sh` creates the databases `keycloak` and `udan` and the user `udan` with all rights on both.
  It reads `MYSQL_ROOT_PASSWORD` and `UDAN_DB_PASSWORD` from the compose environment.
- The Server creates its own tables in `udan` with Flyway, so no schema script ships here.
- Extra init scripts for other apps go in this folder: any `*.sql` or `*.sh` file runs on first start.
