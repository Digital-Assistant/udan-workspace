# Decision records

This folder holds the decisions that bind more than one UDAN repository. A decision about one component lives in
that component's repository: see the Server's [`docs/adr/`][server-adr] and the SDK's [`docs/adr/`][sdk-adr].

Start a new record from [`0000-template.md`](0000-template.md). Name it `NNNN-short-title.md` with the next free
number, and add it to the table below in the same change.

| Number | Title | Status | Summary |
|---|---|---|---|
| [0000](0000-template.md) | Template | n/a | Starting point for new records |
| [0001](0001-keep-separate-repos.md) | Keep the Server, the Client and the SDK in separate repositories | accepted | The SDK stays a plain npm dependency of the Client |
| [0002](0002-workspace-meta-repository.md) | One workspace repository for cross-repository docs and local infrastructure | accepted | Repositories stay self-contained; the workspace adds the cross-repository layer |

[server-adr]: https://github.com/Digital-Assistant/Digital-Assistant-Server/blob/dev/docs/adr/README.md
[sdk-adr]: https://github.com/Digital-Assistant/Digital-Assistant-SDK/blob/dev/docs/adr/README.md
