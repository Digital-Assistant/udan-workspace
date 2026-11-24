# AGENTS.md - UDAN workspace

Entry point for AI agents started in the workspace root. This file explains how the UDAN repositories fit
together. Each repository has its own `AGENTS.md`: read the one for the repository you change.

**Each repository is self-contained.** It has its own `AGENTS.md`, `CONTRIBUTING.md` and docs, and you can work in
it alone. The workspace docs in [`docs/`](docs/README.md) add the cross-repository picture: overview, flows, data
model, local infrastructure and cross-repository decisions. They never replace a repository's own rules; when the
two differ on a repository's internals, the repository wins.

**If `AGENTS.local.md` exists in the workspace root, read it too.** It holds local rules for this machine and
for any extra repositories. Git ignores it.

## Repositories

| Directory | Role | Stack |
| --- | --- | --- |
| `Digital-Assistant-Server` | Core REST API: click sequences, search, votes, status. Port 11081 | Quarkus, Java 21, Gradle |
| `Digital_Assistant_Client` | Browser extension. Holds the UI code and builds from the npm SDK | TypeScript, webpack |
| `Digital-Assistant-SDK` | Browser SDK, published to npm as `@udan/digital-assistant-sdk` | TypeScript, webpack |

`repos.yaml` lists each repository's URL, branch, and build and run commands. Extra repositories join through
the gitignored `repos.local.yaml`. Never name an extra repository in a tracked file.

## How they connect

- The SDK calls the Server over REST and signs in against Keycloak (OIDC).
- The Server picks the OIDC tenant (realm) from the `UDAN-Realm` request header (`CustomTenantResolver`).
- The Server's REST base path is `/api`, for example `http://localhost:11081/api/search/all`.
- Server data: MariaDB (JDBC, Flyway migrations) and Elasticsearch (Hibernate Search). Keycloak data: Postgres.
- Nginx fronts Keycloak and static assets on local hostnames. The Server runs on the host, not in Docker.
- The Client takes the SDK from npm at a fixed version. There is no local linking.
- Cross-repository docs (overview, flows, data model, local infrastructure) are in [`docs/`](docs/README.md).

## Local stack

Use `./udan` to start, stop and check the local stack: `./udan up infra`, `./udan down`, `./udan status`,
`./udan doctor`. `./udan clean` deletes all local data: ask the owner first. `--dry-run` prints the commands
without running them. See `./udan --help`.

- Never create, start, stop or remove containers with raw `docker` or `docker compose` commands.
- Read-only commands are fine: `docker ps`, `docker logs`, `docker inspect`.
- Reason: ad hoc containers skip the network, volumes and credentials that the scripts set up. A half-started
  stack (for example Keycloak without its network) crash-loops.

## Working across repositories

1. Branch from `dev` in every repository. Never touch `master` or `main`.
2. Do not commit or push unless asked.
3. Never merge a pull request. Open it and stop. Do not use `gh pr merge`, the merge API or any workaround.
4. Keep each task inside one repository where possible. If a change affects ports, hostnames, realm names or
   environment variable names, list the other repositories it affects in your summary.
5. This workspace is public. Never copy content, configuration values or credentials from a repository that is
   not in `repos.yaml` into a tracked file here or into a public repository.

## Agent-agnostic rule

Instructions live in `AGENTS.md` only, so every agent (opencode, Claude Code, Codex, Cursor) and every model gets
the same rules. Do not put content in tool-specific files. `CLAUDE.md` only imports `AGENTS.md` and
`AGENTS.local.md`, because Claude Code does not read `AGENTS.md` by itself. Write every rule that matters in
`AGENTS.md` (or `AGENTS.local.md` for local rules). Tool settings and hooks are extra enforcement, not the only
place.
