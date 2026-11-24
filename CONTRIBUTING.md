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

`scripts/check.sh` is the one entry point. The git hooks and CI both call it. It prints PASS, SKIP or FAIL for
each step and exits non-zero on any FAIL:

- shellcheck on `./udan`, `scripts/*.sh` and `scripts/lib/*.sh`
- markdownlint (`.markdownlint-cli2.yaml`)
- a render check of every Mermaid block under `docs/`
- `likec4 validate docs/likec4`, once that folder exists
- a link check (`lychee` if installed, else `markdown-link-check`; external URLs are not fetched)
- `scripts/check-unknown-repos.sh`: no tracked file may name a repository that `repos.yaml` does not list
- `scripts/check-realms.sh` and its negative tests `scripts/test-check-realms.sh` (needs `jq`)
- `scripts/test-infra-env-certs.sh` (needs `openssl`)
- `scripts/test-udan.sh`: `./udan` against a fake `docker` and local git repositories (needs `jq`)
- gitleaks, if installed

You need `shellcheck`, `gitleaks` and Node 22 with `npx`. The Node tools run through `npx` at pinned versions, so
nothing else is installed. Install the hooks once per clone:

```bash
npx --yes lefthook@2.2.2 install
```

The pre-commit hook refuses a commit on `dev` or `main`, runs `scripts/check.sh --staged` and scans the staged
change with gitleaks. The commit-msg hook refuses a subject that is not a Conventional Commit. Do not bypass
the hooks with `--no-verify`: CI runs the same checks.

## Rules for this public repository

- Never add a file that names a repository missing from `repos.yaml`. List extra repositories in your own
  gitignored `repos.local.yaml`.
- Never commit credentials, hostnames of deployed systems or personal data.
- Keep local agent rules in the gitignored `AGENTS.local.md`, not in `AGENTS.md`.
