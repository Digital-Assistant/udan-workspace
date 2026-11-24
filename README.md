# UDAN workspace

This repository sets up the whole UDAN product on one machine. It holds the list of UDAN repositories
(`repos.yaml`), the cross-repository docs, the shared local infrastructure and a `./udan` command. It holds no
product code: each part of UDAN keeps its own repository and its own history.

UDAN (Universal Digital Assistant) records and replays click sequences on web pages. Its public parts are:

- **Server**: the REST API (Quarkus, Java). It stores click sequences and serves search, votes and status.
- **Client**: the browser extension. It embeds the SDK and adds the panel users see.
- **SDK**: the browser library that records and replays sequences and talks to the Server. It is published to npm.

## Layout

The workspace clones each repository into its own root, beside the workspace files:

```text
udan-workspace/
├── README.md, AGENTS.md, CONTRIBUTING.md, LICENSE
├── repos.yaml                  # the public repositories, their branch and build/run commands
├── repos.local.example.yaml    # format for your own extra repositories (copy to repos.local.yaml)
├── udan                        # the workspace command (./udan --help)
├── docs/                       # cross-repository docs
├── infra/                      # shared local infrastructure (compose files, realms, nginx)
├── Digital-Assistant-Server/   # cloned, not tracked here
├── Digital_Assistant_Client/   # cloned, not tracked here
└── Digital-Assistant-SDK/      # cloned, not tracked here
```

The `.gitignore` is an allow-list. Git tracks only the workspace files above. Every cloned repository is ignored
without being named.

## Repositories

| Directory | Role | Stack | Default branch |
| --- | --- | --- | --- |
| [`Digital-Assistant-Server`](https://github.com/Digital-Assistant/Digital-Assistant-Server) | REST API, port 11081, base path `/api` | Quarkus, Java 21, Gradle | `dev` |
| [`Digital_Assistant_Client`](https://github.com/Digital-Assistant/Digital_Assistant_Client) | Browser extension | TypeScript, webpack, Node 22 | `dev` |
| [`Digital-Assistant-SDK`](https://github.com/Digital-Assistant/Digital-Assistant-SDK) | Browser SDK, published to npm | TypeScript, webpack, Node 22 | `dev` |

The build and run commands for each repository are in [`repos.yaml`](repos.yaml). The Client takes the SDK from
npm, so the two build on their own. There is no local linking between them.

## Status

State on 2026-11-24. The workspace is not published yet: the clone URL in step 1 below is where it will live.
The Server's `./start-server.sh` on `dev` still checks for an older local setup; the matching Server change
(reading the workspace `infra/`) is pending. Until it lands, `./udan bootstrap`, `./udan up infra`,
`./udan status`, `./udan doctor`, `./udan down` and `./udan clean` work as described here, but step 5 cannot
start the Server from this workspace without a `branch` override for the Server in `repos.local.yaml`.
Remove this note when the Server change is on `dev`.

## Requirements

- Linux, or Windows with WSL2. macOS is not supported: `./udan` needs bash 4.4 or later and GNU coreutils
  (`date -d`, `readlink -f`, `stat -c`).
- For the infrastructure (`up`, `down`, `clean`, `status`, `doctor`, `reload`): Docker with the Compose v2
  plugin (`docker compose`), `git`, `jq`, `openssl` and `curl`.
- For `./udan bootstrap`: `git`, plus the build tools each repository lists under `needs` in `repos.yaml`:
  JDK 21 for the Server (`JAVA_HOME` wins over `PATH`; if the `java` on `PATH` is older, run
  `export JAVA_HOME=/path/to/jdk-21` first, in the shell where you run `./udan`),
  Node 22 and `npm` for the Client and the SDK. A repository whose tools are missing is still cloned, but not
  built, and `bootstrap` names the missing tool and exits 1. `./udan doctor` reports missing build tools as
  warnings only.

## Quick start

1. Clone the workspace (see [Status](#status)):

   ```bash
   git clone https://github.com/Digital-Assistant/udan-workspace.git
   cd udan-workspace
   ```

2. Clone and build the repositories: `./udan bootstrap`. It clones each repository in `repos.yaml` into the
   workspace root and runs its `build` command. On a second run it fast-forwards each checkout that is clean and
   on its branch, and leaves the others as they are, with a warning. It never switches a branch silently and never
   discards changes. `./udan bootstrap server` limits it to one repository. The SDK and Client builds create
   `environments/local.env` from the repository's example file when it is missing, and never overwrite an
   existing one; edit it for your own settings.
3. Start the shared infrastructure: `./udan up infra`. The first run creates `infra/.env` from
   `infra/.env.example` and a self-signed dev certificate. It exits 1, with the container's last log lines, when
   MariaDB or Keycloak does not become ready. The first run takes several minutes (image pulls, first Keycloak
   start, about 6 minutes on a clean machine); later runs are much faster.
4. Check that everything is ready: `./udan doctor`. It exits non-zero and names the fix when a check fails.
5. Start a repository: run its `run` command from `repos.yaml` in its directory. `./udan up all` starts the
   infrastructure and prints these commands. It does not start the dev servers itself, because each one runs in
   the foreground. Before the first `./start-server.sh`, run `./sync-credentials.sh` once in the Server
   directory (it writes `src/main/resources/local-secrets.properties`).
6. Check that the Server answers (it listens on port 11081). Every request needs the `UDAN-Realm` header
   (`UDAN` or `UDAN-Plugin`): `curl -i -H 'UDAN-Realm: UDAN' http://localhost:11081/api/search/all`. HTTP 401
   without a token is the expected sign of life; HTTP 400 "UDAN-Realm header is required" means the header is
   missing. `./udan doctor` does the same check.

### Commands

| Command | What it does |
| --- | --- |
| `./udan bootstrap [name] [--no-build]` | Check tools, clone or update the repositories, build them |
| `./udan up infra` | Create `infra/.env` and the certificate if missing, then start the network, MariaDB, Postgres, Keycloak, Elasticsearch and Nginx in that order |
| `./udan up all` | `up infra`, then print each repository's `run` command |
| `./udan down` | Stop the stack's containers in reverse order; data stays |
| `./udan clean [--yes]` | Check that no other container uses the stack's network or volumes, ask, stop, then remove the five containers, the network and the named volumes (all local data) |
| `./udan status` | Container state and health; each repository's branch and changes |
| `./udan doctor [--json]` | Tools, Docker, `.env`, certificates, containers, ports, logins, realms, Elasticsearch, Server |
| `./udan reload nginx` | Test the nginx configuration, then reload it |

Every command works from any directory (`/path/to/udan-workspace/udan status`). `--dry-run` prints the
commands that would change something instead of running them; it makes the same checks as a real run, so it
stops where a real run would.

## Extra repositories and local overrides

Your team may use repositories that are not public. List them in `repos.local.yaml`, in the same format as
`repos.yaml`. Git ignores that file. Copy [`repos.local.example.yaml`](repos.local.example.yaml) to start.

The same file overrides fields of a listed repository: `url` (also a local folder), `path`, `branch`, `build`,
`run`, `ref` and `needs`. A `path` must be a folder inside the workspace. With `in_place: true`, the path may be
anywhere and `./udan bootstrap` uses that existing checkout as it is: no clone, no pull and no branch switch.

A `ref` (tag or commit) is checked out right after a clone, or later when the checkout is clean and on its
`branch`. On another branch `./udan bootstrap` warns and leaves it.

### Trust model

- `repos.yaml` and `repos.local.yaml` are code. `./udan bootstrap` runs each `build` line as a shell command on
  your machine, and `./udan up all` prints each `run` line for you to paste into a shell.
- `repos.yaml` is reviewed code: review a change to a `build` or `run` line like a change to a script.
- `repos.local.yaml` is your own file. Only use one that you wrote or reviewed yourself.

An extra repository can add its own nginx routes: it drops `*.conf` files with whole `server` blocks into
`infra/nginx/conf.d/extra/` (ignored by git) and runs `./udan reload nginx`. See
[`infra/nginx/README.md`](infra/nginx/README.md).

## Docs

Each repository is self-contained: it has its own `README.md`, `AGENTS.md`, `CONTRIBUTING.md` and docs, and you
can work in it alone. The workspace docs add the cross-repository picture and never replace a repository's own
rules. Start at [`docs/README.md`](docs/README.md).

| You want to | Read |
| --- | --- |
| Work here as an AI agent | [`AGENTS.md`](AGENTS.md) |
| Propose a change to the workspace | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| Change one repository | That repository's `README.md`, `AGENTS.md` and `CONTRIBUTING.md` |
| Read the architecture and cross-repository flows | [`docs/README.md`](docs/README.md) |

## License

[GNU Affero General Public License v3.0](LICENSE), the same license as the Server.
