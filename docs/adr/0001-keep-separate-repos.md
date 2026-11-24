# 0001. Keep the Server, the Client and the SDK in separate repositories

- **Status:** accepted
- **Date:** 2026-10-20
- **Deciders:** project owner
- **Repositories affected:** Server, Client, SDK, this workspace

## Context

UDAN used to live in one repository. The SDK was split out on purpose, so third parties can build their own
interface on it. The Client consumes the SDK as a published npm package, like any other consumer. A monorepo with
the SDK, the Client and the Server was considered.

## Decision

The Server, the Client and the SDK stay in separate repositories. The SDK stays independent, so an external
interface can depend on it the same way the Client does.

## Alternatives considered

| Alternative | Why it was rejected |
|---|---|
| One monorepo for the SDK, the Client and the Server | It mixes one product's interface with a library meant for other interfaces too |
| Merge only the Client and the SDK | The same reason: the SDK would no longer be a plain dependency of the Client |

## Consequences

### Positive

- Each repository builds, tests and releases on its own.
- The SDK has one release line that every consumer, including the Client, takes from npm.

### Negative and trade-offs

- A change to a shared fact (ports, realm names, the `/api` base path, an API contract) needs coordination. This
  workspace's `AGENTS.md` and `docs/` are the coordination point ([ADR 0002](0002-workspace-meta-repository.md)).
- A shared OpenAPI contract between the Server and the SDK could reduce this; it does not exist yet.
- Revisit the decision if cross-repository pull requests become frequent.
