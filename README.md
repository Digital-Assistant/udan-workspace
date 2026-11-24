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
├── udan                        # the workspace command (coming in a later phase)
├── docs/                       # cross-repository docs (coming in a later phase)
├── infra/                      # shared local infrastructure (coming in a later phase)
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

You need `git`, Docker with Compose, JDK 21 and Node 22.

1. Clone the workspace:

   ```bash
   git clone https://github.com/Digital-Assistant/udan-workspace.git
   cd udan-workspace
   ```

2. Clone and build the repositories: `./udan bootstrap`. *Coming in a later phase.* Until then, clone each
   repository in `repos.yaml` into the workspace root with `git clone --branch dev <url> <path>`. Then run its
   `build` command in its directory.
3. Start the shared infrastructure: `./udan up infra`. *Coming in a later phase.*
4. Check that the infrastructure is ready: `./udan doctor`. *Coming in a later phase.*
5. Start a repository: run its `run` command from `repos.yaml` in its directory.

## Extra repositories

Your team may use repositories that are not public. List them in `repos.local.yaml`, in the same format as
`repos.yaml`. Git ignores that file. Copy [`repos.local.example.yaml`](repos.local.example.yaml) to start.

## Docs

| You want to | Read |
| --- | --- |
| Work here as an AI agent | [`AGENTS.md`](AGENTS.md) |
| Propose a change to the workspace | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| Change one repository | That repository's `README.md`, `AGENTS.md` and `CONTRIBUTING.md` |
| Read the architecture and cross-repository flows | `docs/` (coming in a later phase) |

## License

[GNU Affero General Public License v3.0](LICENSE), the same license as the Server.
