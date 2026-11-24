# Contributing to the UDAN workspace

This repository holds the workspace files only: `repos.yaml`, the docs, the shared local infrastructure and the
`./udan` command. To change the Server, the Client or the SDK, follow the `CONTRIBUTING.md` of that repository.

## Steps

1. Branch from `dev`. `dev` is the only long-lived branch.
2. Make one change per pull request.
3. Write each commit subject as a [Conventional Commit](https://www.conventionalcommits.org/), for example
   `docs: explain the realm header`. Allowed types: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`,
   `ci`, `chore`, `revert`.
4. Run the local checks (see below).
5. Open a pull request to `dev`. Give it a Conventional Commit title, because the squash merge uses it.

## Local checks

The checks run through `lefthook` and in CI: shell lint, Markdown lint, a secret scan and a check that no
tracked file names a repository missing from `repos.yaml`. *They come in the next phase.* Until then, run
`gitleaks detect --source . --no-banner` before you push.

## Rules for this public repository

- Never add a file that names a repository missing from `repos.yaml`. List extra repositories in your own
  gitignored `repos.local.yaml`.
- Never commit credentials, hostnames of deployed systems or personal data.
- Keep local agent rules in the gitignored `AGENTS.local.md`, not in `AGENTS.md`.
