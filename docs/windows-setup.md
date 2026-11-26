# Running UDAN on Windows (WSL 2)

Bottom line: UDAN runs on Windows through WSL 2. Use `.\udan.ps1` in PowerShell instead of `./udan`. It runs the
same bash command inside the Ubuntu distribution and installs the missing Linux toolchain on first use. This page
records the setup, every change made to get it running, and the fixes for the problems a Windows checkout hits.

## Why WSL 2 and not native Windows

`./udan`, `start-server.sh` and the repository build commands are bash scripts that need GNU coreutils and a
POSIX shell. The stack was tested on Linux. WSL 2 runs those scripts unchanged, next to Docker Desktop, so the
workspace keeps one source of truth instead of a second PowerShell implementation. `.\udan.ps1` is a thin wrapper;
it does not reimplement any command.

## Prerequisites

1. Windows 10/11 with WSL 2 and an Ubuntu distribution (`wsl -d Ubuntu -- true` must work).
2. Docker Desktop, running, with **Settings > Resources > WSL Integration > Ubuntu** enabled. Without it, `docker`
   inside Ubuntu answers "The command 'docker' could not be found in this WSL 2 distro".
3. Enough memory for the Docker VM. Elasticsearch, Keycloak, MariaDB, Postgres and Nginx together need more than
   the old 2 GB default. 8 GB is safe on a 16 GB machine. Set it in **Settings > Resources > Advanced > Memory**
   (or `"memoryMiB"` in `%APPDATA%\Docker\settings.json` while Docker Desktop is stopped), then restart Docker
   Desktop.
4. `jq`, JDK 21 and Node 22 inside Ubuntu. You do not install these by hand: the first `.\udan.ps1` run calls
   `scripts/setup-wsl-toolchain.sh`, which installs them into `~/.local/udan` without `sudo`.

## First run

From PowerShell in the workspace folder:

```powershell
.\udan.ps1 bootstrap        # clone + build Server, Client and SDK
.\udan.ps1 up infra         # MariaDB, Postgres, Keycloak, Elasticsearch, Nginx
.\udan.ps1 doctor           # every check should pass
```

If PowerShell blocks the script, allow it for the current session:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

`.\udan.ps1` accepts the same arguments as `./udan` (`bootstrap server`, `up infra`, `up all`, `down`, `clean`,
`status`, `doctor`, `reload nginx`, `--dry-run`, `--json`).

## Start the applications

The infrastructure containers and the Server are the long-running servers. After `up infra` and `doctor`:

```powershell
# One time per machine: write the Server's local secrets from infra/.env.
wsl -d Ubuntu -- bash -lc 'source ~/.config/udan/env.sh; cd "<workspace>/Digital-Assistant-Server" && ./sync-credentials.sh'

# Start the Server (Quarkus dev mode, port 11081). Foreground; Ctrl+C stops it.
wsl -d Ubuntu -- bash -lc 'source ~/.config/udan/env.sh; cd "<workspace>/Digital-Assistant-Server" && ./start-server.sh'
```

Replace `<workspace>` with the WSL path of the workspace, for example
`/mnt/d/nistapp/projects/UDAN/udan-workspace`. The Client and SDK `run` commands are webpack watch builds, not
servers; start them the same way with `npm start` when you work on the extension or the SDK:

```powershell
wsl -d Ubuntu -- bash -lc 'source ~/.config/udan/env.sh; cd "<workspace>/Digital-Assistant_SDK" && npm start'
wsl -d Ubuntu -- bash -lc 'source ~/.config/udan/env.sh; cd "<workspace>/Digital_Assistant_Client" && npm start'
```

A healthy Server answers HTTP 401 on `/api` without a token, and the `UDAN-Realm` header is required:

```powershell
curl.exe -i -H "UDAN-Realm: UDAN" http://localhost:11081/api/search/all
```

Stop the infrastructure with `.\udan.ps1 down`. `.\udan.ps1 clean` deletes all local data; ask the owner first.

## Changes made to get this running

### Changes in this repository (tracked)

| File | Change | Why |
| --- | --- | --- |
| `.gitattributes` | New: `* text=auto eol=lf`, with `*.cmd`/`*.bat` as CRLF | The global `core.autocrlf=true` checked the repo out with CRLF, so `#!/usr/bin/env bash` became `bash\r` and `./udan` failed in WSL. This matches `.editorconfig` (`end_of_line = lf`) and makes every Windows clone use LF. |
| `.gitignore` | Allow `/.gitattributes` and `/udan.ps1` | The allow-list hid the new files; without this they would not be tracked. |
| `scripts/fix-line-endings.sh` | New | One-time repair for a checkout that already has CRLF (rewrites tracked files to LF and refreshes the index). |
| `scripts/setup-wsl-toolchain.sh` | New | Installs jq, JDK 21 (Temurin) and Node 22 into `~/.local/udan` without sudo, and writes `~/.config/udan/env.sh`. |
| `udan.ps1` | New | PowerShell wrapper: translates the workspace path to `/mnt/<drive>/...`, installs the toolchain on first run, then executes `./udan` in Ubuntu WSL. |
| `docs/windows-setup.md` | New (this page) | Setup guide and change log. |
| `README.md`, `docs/README.md` | Windows section and doc link | Point Windows users at the wrapper and this page. |

### Changes to this machine (not in the repository)

| Where | Change | Why |
| --- | --- | --- |
| `%APPDATA%\Docker\settings.json` | `integratedWslDistros` includes `Ubuntu`; `memoryMiB` raised from 2048 to 8192 | Docker is reachable inside Ubuntu, and Elasticsearch has enough memory. |
| WSL `~/.local/udan` | jq 1.8.2, Temurin JDK 21.0.13, Node 22.23.5 (with npm) | JDK 21 and Node 22 are the versions the repositories require; the host had only Java 11. |
| WSL `~/.config/udan/env.sh` | Exports `JAVA_HOME` and `PATH` | `bash -c` build commands inherit it; `udan.ps1` sources it. |
| WSL `~/.bashrc` | Sources `~/.config/udan/env.sh` | Interactive WSL shells get the same tools. |
| Workspace git config | `core.autocrlf=false`, `core.eol=lf` | Keep the Linux-first checkout on LF. |
| WSL git config | `core.checkStat=minimal`, `core.trustctime=false` | The `/mnt/d` (drvfs) stat data made git report clean files as modified. |
| Working tree | CRLF rewritten to LF, then `git add -u` | Undo the CRLF checkout; this is what `scripts/fix-line-endings.sh` does. |
| `infra/.env`, `infra/nginx/localhost/`, `infra/keycloak/certs/` | Generated by `./udan up infra` | Local dev secrets and the self-signed certificate. Gitignored; never commit them. |
| `Digital-Assistant-Server/src/main/resources/local-secrets.properties` | Generated by `./sync-credentials.sh` | Holds the DB password and Keycloak client secret. Gitignored; never commit it. |
| Docker volumes | `mariadb_mariadb_data`, `postgres_postgres_data`, `elasticsearch_elasticsearch_data`, `nginx_nginx-tmp`, `nginx_nginx-cache` | Local data, created by the stack. `./udan clean` removes them. |

The running Server, when started in the background for setup, logs to `/tmp/udan-server.log` with its PID in
`/tmp/udan-server.pid` inside WSL. That is temporary and gone after a reboot; start it with `start-server.sh` as
shown above.

## Troubleshooting

- **`/usr/bin/env: 'bash\r': No such file or directory`** - the checkout has CRLF line endings. Run
  `bash scripts/fix-line-endings.sh` in WSL, then retry. A fresh clone with `.gitattributes` is already LF.
- **`The command 'docker' could not be found in this WSL 2 distro`** - enable Docker Desktop's WSL integration for
  Ubuntu and restart Docker Desktop. Check with `wsl -d Ubuntu -- docker ps`.
- **`./udan doctor` says a port is in use** - another process on Windows owns it (for example IIS on 80/443, or a
  local MySQL on 3306). Stop it, or change the published port in the matching `infra/*/docker-compose-*.yaml`.
- **Keycloak is slow the first time** - the first start imports the realms and can take 2-4 minutes. `up infra`
  waits for it; run `.\udan.ps1 doctor` again afterwards.
- **Elasticsearch exits or is killed** - the Docker VM is too small. Raise `memoryMiB` and restart Docker Desktop.
- **MariaDB/Postgres login refused** - the data volumes keep the passwords they were created with. Put those
  values in `infra/.env`, or run `.\udan.ps1 clean` (deletes all local data) then `.\udan.ps1 up infra`.
- **Server fails pre-flight** - the infrastructure must be up and `./sync-credentials.sh` must have run once. The
  script names the failed check and the fix.
