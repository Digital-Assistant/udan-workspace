# Workspace docs

This folder holds the docs that cross UDAN repositories: the overview, how the parts connect, the flows across
them, the shared data model, the local infrastructure and the cross-repository decisions. Each repository keeps
its own docs for its internals; the pages here link to them and do not repeat them.

| Page | What it holds |
|---|---|
| [`00-overview.md`](00-overview.md) | The public parts, how they connect, and the facts that cross repositories |
| [`containers/server.md`](containers/server.md) | Server: role, interfaces, connections, links to its docs |
| [`containers/client.md`](containers/client.md) | Client (browser extension): role, interfaces, connections, links to its docs |
| [`containers/sdk.md`](containers/sdk.md) | SDK: role, interfaces, connections, links to its docs |
| [`containers/infra.md`](containers/infra.md) | Shared local infrastructure: services, ports, network, realms |
| [`data-model.md`](data-model.md) | Server tables, search indexes and the rules clients rely on |
| [`flows/auth-oidc.md`](flows/auth-oidc.md) | Sign-in, token checks and tenant selection |
| [`flows/record-sequence.md`](flows/record-sequence.md) | Recording a click sequence, and ownership |
| [`flows/search.md`](flows/search.md) | Searching recorded sequences |
| [`windows-setup.md`](windows-setup.md) | Running the workspace on Windows with WSL 2: setup, changes made, troubleshooting |
| [`adr/README.md`](adr/README.md) | Decisions that bind more than one repository |
| [`likec4/model.c4`](likec4/model.c4) | Architecture model of the public parts (LikeC4) |

## The LikeC4 model

`likec4/model.c4` models the public containers, the Server's main components and the shared infrastructure. Check
it and view it from the workspace root:

```bash
npx --yes likec4@1.61.1 validate docs/likec4
npx --yes likec4@1.61.1 start docs/likec4
```

An extra repository may add its own `.c4` file to the same model through a local LikeC4 configuration. Nothing in
this repository depends on such a file.

## Writing rules

Write for an engineer who knows Git but not UDAN. Put the bottom line first, keep sentences short, and validate
every Mermaid block (`scripts/check.sh` renders them). Keep one home for each fact: when a fact belongs to one
repository, link to that repository's page on `dev` instead of copying it.
