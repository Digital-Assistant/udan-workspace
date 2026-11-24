# infra

Compose files for the shared local services the Server needs. One folder per service, same names as the
established local setup, so container names, volumes and the `uda-network` network stay identical.

| Folder | Container | Image |
|---|---|---|
| `network` | (creates `uda-network`, 172.20.0.0/16) | |
| `mariadb` | `mariadb-local` | mariadb 10.11 |
| `postgres` | `postgres-local` | postgres 14 |
| `keycloak` | `keycloak-local` | keycloak 23.0.0 |
| `elasticsearch` | `elasticsearch-local` | elasticsearch 7.17.16 |
| `nginx` | `nginx-local` | nginx 1.24.0 |

Each file is `<folder>/docker-compose-<folder>.yaml`. The compose project name comes from the folder name.

## Settings and secrets

Credentials come from one untracked file, `infra/.env` (variables in the compose files, no literal secrets). Copy
`.env.example` to `infra/.env` once it exists. Certificates live in `*/certs/` and `nginx/localhost/`; they are
ignored by git. The Keycloak realm files carry one dev-only client secret: see
[`keycloak/realms/README.md`](keycloak/realms/README.md).

## Extra routes

Nginx mounts `nginx/conf.d`. Put extra routes in `nginx/conf.d/extra/`; files there are ignored by git.

## Start and stop

Start with `./udan`, never raw `docker` or `docker compose` commands: the script sets up the network, volumes and
start order.
