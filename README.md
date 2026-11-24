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

## Quick start

You need `git`, Docker with the Compose plugin, `openssl`, `jq`, `curl`, JDK 21 (on `JAVA_HOME` or `PATH`),
Node 22 and `npm`. `./udan bootstrap` checks them all and lists every missing one.

1. Clone the workspace:

   ```bash
   git clone https://github.com/Digital-Assistant/udan-workspace.git
   cd udan-workspace
   ```

2. Clone and build the repositories: `./udan bootstrap`. It clones each repository in `repos.yaml` into the
   workspace root and runs its `build` command. On a second run it fast-forwards each checkout that is clean and
   on its branch, and leaves the others as they are. `./udan bootstrap server` limits it to one repository.
3. Start the shared infrastructure: `./udan up infra`. The first run creates `infra/.env` from
   `infra/.env.example` and a self-signed dev certificate.
4. Check that everything is ready: `./udan doctor`. It exits non-zero and names the fix when a check fails.
5. Start a repository: run its `run` command from `repos.yaml` in its directory. `./udan up all` starts the
   infrastructure and prints these commands. It does not start the dev servers itself, because each one runs in
   the foreground.

### Commands

| Command | What it does |
| --- | --- |
| `./udan bootstrap [name] [--no-build]` | Check tools, clone or update the repositories, build them |
| `./udan up infra` | Create `infra/.env` and the certificate if missing, then start the network, MariaDB, Postgres, Keycloak, Elasticsearch and Nginx in that order |
| `./udan up all` | `up infra`, then print each repository's `run` command |
| `./udan down` | Stop the containers in reverse order; data stays |
| `./udan clean [--yes]` | Ask, stop, then remove the containers, their volumes and the network (all local data) |
| `./udan status` | Container state and health; each repository's branch and changes |
| `./udan doctor [--json]` | Tools, Docker, `.env`, certificates, containers, ports, logins, realms, Elasticsearch, Server |
| `./udan reload nginx` | Test the nginx configuration, then reload it |

Every command works from any directory (`/path/to/udan-workspace/udan status`). `--dry-run` prints the
commands that would change something instead of running them.

## Extra repositories and local overrides

Your team may use repositories that are not public. List them in `repos.local.yaml`, in the same format as
`repos.yaml`. Git ignores that file. Copy [`repos.local.example.yaml`](repos.local.example.yaml) to start.

The same file overrides fields of a listed repository: `url` (also a local folder), `path`, `branch`, `build`,
`run` and `ref`. With `in_place: true`, `./udan bootstrap` uses an existing checkout as it is: no clone, no pull
and no branch switch.

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
