# infra

Compose files for the shared local services the Server needs. One folder per service, same names as the
established local setup, so container names, volumes and the `uda-network` network stay identical.

| Folder | Container | Image |
|---|---|---|
| `mariadb` | `mariadb-local` | mariadb 10.11 |
| `postgres` | `postgres-local` | postgres 14 |
| `keycloak` | `keycloak-local` | keycloak 23.0.0 |
| `elasticsearch` | `elasticsearch-local` | elasticsearch 7.17.16 |
| `nginx` | `nginx-local` | nginx 1.24.0 |

Each file is `<folder>/docker-compose-<folder>.yaml`. The compose project name comes from the folder name.
`./udan up infra` creates the network `uda-network` (bridge, 172.20.0.0/16) with `docker network create`.

## Settings and secrets

Credentials come from one untracked file, `infra/.env` (variables in the compose files, no literal secrets). Each
service gets only the variables it names in its compose file.
`scripts/infra-env.sh` creates it from `.env.example` (mode 600, never overwrites; `--check` lists missing variables).
The example values are invented dev-only placeholders. They only apply to a new data volume: a volume created
earlier keeps the passwords it was created with, so an existing local stack needs either its own values in the
gitignored `infra/.env` (put there by its owner) or a clean start.

### .env format

`./udan` reads `infra/.env` itself (to check logins and readiness) and gives each value to Docker Compose. Both must
read the same value, so `./udan` supports this subset of the Compose `.env` format and refuses a file outside it:

- One `KEY=VALUE` per line. An `export` prefix before the key and spaces around `=` are allowed. Lines that
  start with `#` are comments. Windows (CRLF) line ends work. When a key appears twice, the last line wins.
- Unquoted value: spaces around it are removed. A space followed by `#` starts a comment (`a#b` is a value,
  `a #b` is `a`).
- `'single-quoted'` value: taken as it is, including `$`, `#` and `\`. Use this form for any password with
  special characters.
- `"double-quoted"` value: taken as it is, but it must not contain `$` or `\`.
- Not supported: `$` in an unquoted or double-quoted value (Compose would expand it as a variable), `\` in a
  double-quoted value (Compose would read it as an escape), a quote that is not closed on the same line.
  `./udan up infra` stops and `./udan doctor` fails and names the variable; put the value in single quotes.

### Certificate

`scripts/infra-certs.sh` creates the self-signed dev certificate in `nginx/localhost/` and copies it to
`keycloak/certs/` (renews it when missing, expired or under 7 days left; `--force` regenerates). Certificates are
ignored by git. The names in the certificate are `localhost`, `127.0.0.1` and `udan-sdk.nistapp` (local dev name).
PostgreSQL creates the Keycloak database and user on first start from
`postgres/init/01-create-keycloak-db.sh`. The Keycloak realm files carry one dev-only client secret: see
[`keycloak/realms/README.md`](keycloak/realms/README.md).

## Extra routes

Nginx mounts `nginx/conf.d`. Put extra routes in `nginx/conf.d/extra/`; files there are ignored by git. Apply a
change with `./udan reload nginx` (it runs `nginx -t` first and reloads only a valid configuration).

## Start and stop

Use `./udan`, never raw `docker` or `docker compose` commands: it sets up the network, volumes and start order.
`./udan up infra` starts, `./udan down` stops, `./udan doctor` checks, `./udan clean` removes everything.
`./udan up infra` calls `docker compose -p <folder> -f <folder>/docker-compose-<folder>.yaml --env-file infra/.env
up -d` for each service, without `--remove-orphans`, so it never touches other containers of a project with the
same name. `./udan down` and `./udan clean` act only on the names this stack defines: the containers
`mariadb-local`, `postgres-local`, `keycloak-local`, `elasticsearch-local` and `nginx-local`, the network
`uda-network`, and the volumes `mariadb_mariadb_data`, `postgres_postgres_data`,
`elasticsearch_elasticsearch_data`, `nginx_nginx-tmp` and `nginx_nginx-cache`. These names are the same as the
original local setup, so an existing stack keeps its data. `./udan clean` first checks that no other container is
attached to `uda-network` or uses one of the volumes; if one is, it names it and changes nothing.
