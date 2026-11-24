# 0002. One workspace repository for cross-repository docs and local infrastructure

- **Status:** accepted
- **Date:** 2026-11-06 (rule 2, self-contained repositories: 2026-11-24)
- **Deciders:** project owner
- **Repositories affected:** this workspace, Server, Client, SDK

## Context

The repositories stay separate ([ADR 0001](0001-keep-separate-repos.md)). Some knowledge belongs to no single
repository: how the parts connect, the flows across them, the shared data model and the local infrastructure that
the Server needs. That knowledge had no public home.

## Decision

1. A public workspace repository, `udan-workspace`, holds the list of repositories (`repos.yaml`), the
   cross-repository docs (`docs/`), the shared local infrastructure (`infra/`) and the `./udan` command. It holds
   no product code.
2. Each repository stays self-contained. It keeps its own `README.md`, `AGENTS.md`, `CONTRIBUTING.md` and docs, and
   it can be cloned, built and changed alone.
3. Workspace docs cover only what crosses repositories. A component page here is thin: role, interfaces, ports,
   connections, and links to the repository's own docs. The workspace never restates a repository's own rules.
4. Links point one way. A repository may point up to the workspace. The workspace points down only to repositories
   in `repos.yaml`.

## Alternatives considered

| Alternative | Why it was rejected |
|---|---|
| Keep cross-repository docs in the Server repository | The Server would document parts it does not own |
| A monorepo | Rejected in [ADR 0001](0001-keep-separate-repos.md) |
| Copy the shared docs into every repository | The copies drift apart |

## Consequences

### Positive

- A new engineer clones one repository and gets the whole picture and a working local stack.
- Each fact has one home: component facts in the component's repository, cross-repository facts here.

### Negative and trade-offs

- A change to a component can make a workspace page stale. The workspace pages link to repository docs instead of
  copying them to keep this small.
- Extra repositories that are not public join only through the gitignored `repos.local.yaml`.
