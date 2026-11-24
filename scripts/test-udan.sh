#!/usr/bin/env bash
# Test for ./udan without Docker: a copy of the workspace in a temp folder, a fake docker (and fake java, node,
# npm) on PATH that only logs its arguments, and local git repositories as clone URLs.
# Covers argument parsing and exit codes, the manifest parser and repos.local.yaml, bootstrap (clone, pull, dirty
# tree, other branch, in-place checkout), up infra --dry-run order and waits, clean confirmation and refusal,
# reload nginx and doctor exit codes. Usage: scripts/test-udan.sh. Needs: bash, git. Exit code: 0 ok, 1 a case failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fails=0
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }
# check <description> <command...>: passes when the command succeeds.
check() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }

# --- fake tools -----------------------------------------------------------------------------------------------
bin="$tmp/bin"
mkdir -p "$bin"
cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
# Fake docker: logs every call; containers listed in FAKE_RUNNING count as running; the network exists when
# FAKE_NETWORK=1. Every other call succeeds and does nothing.
echo "$*" >>"$FAKE_LOG"
case "$1" in
  info) exit 0 ;;
  context) echo default ;;
  compose) exit 0 ;;
  ps)
    for a in "$@"; do
      case "$a" in name=*) n="${a#name=^/}"; n="${n%\$}"; [[ " ${FAKE_RUNNING:-} " == *" $n "* ]] && echo "id-$n" ;; esac
    done
    ;;
  network) [[ "$2" == inspect ]] && { [[ "${FAKE_NETWORK:-0}" == 1 ]]; exit; }; exit 0 ;;
  inspect | port) exit 1 ;;
  exec) exit 1 ;;
  *) exit 0 ;;
esac
EOF
printf '#!/usr/bin/env bash\necho "openjdk version \\"21.0.2\\" 2024-01-16" >&2\n' >"$bin/java"
printf '#!/usr/bin/env bash\necho v22.1.0\n' >"$bin/node"
printf '#!/usr/bin/env bash\necho 10.0.0\n' >"$bin/npm"
chmod +x "$bin"/*
export PATH="$bin:$PATH" FAKE_LOG="$tmp/docker.log"
unset JAVA_HOME DOCKER_CONTEXT
export UDAN_KEYCLOAK_URL="http://127.0.0.1:9" UDAN_ES_URL="http://127.0.0.1:9" UDAN_SERVER_URL="http://127.0.0.1:9"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# --- workspace copy ---------------------------------------------------------------------------------------------
ws="$tmp/ws"
mkdir -p "$ws/scripts/lib" "$ws/infra"
cp "$ROOT/udan" "$ws/"
cp "$ROOT/scripts/lib/manifest.sh" "$ws/scripts/lib/"
cp "$ROOT/scripts/infra-env.sh" "$ROOT/scripts/infra-certs.sh" "$ws/scripts/"
cp "$ROOT/infra/.env.example" "$ws/infra/"
for d in "$ROOT"/infra/*/; do
  s="$(basename "$d")"
  [[ -f "$d/docker-compose-$s.yaml" ]] || continue
  mkdir -p "$ws/infra/$s"
  cp "$d/docker-compose-$s.yaml" "$ws/infra/$s/"
done
mkdir -p "$ws/infra/nginx/conf.d/extra"
udan() { "$ws/udan" "$@"; }

# rc <expected> <command...>: runs the command, output to $tmp/out, and compares the exit code.
rc() { local want="$1"; shift; "$@" >"$tmp/out" 2>&1; local got=$?; (( got == want )); }
out_has() { grep -qF -- "$1" "$tmp/out"; }
log_has() { grep -qE -- "$1" "$FAKE_LOG" 2>/dev/null; }

echo "arguments and exit codes"
check "no command exits 2" rc 2 udan
check "unknown command exits 2" rc 2 udan frobnicate
check "unknown flag exits 2" rc 2 udan --frob status
check "up without target exits 2" rc 2 udan up
check "up with unknown target exits 2" rc 2 udan up everything
check "reload with unknown target exits 2" rc 2 udan reload keycloak
check "--json outside doctor exits 2" rc 2 udan --json status
check "--help exits 0" rc 0 udan --help
check "--help lists every command" bash -c "grep -q 'bootstrap' '$tmp/out' && grep -q 'up all' '$tmp/out' \
  && grep -q 'reload nginx' '$tmp/out' && grep -q 'doctor' '$tmp/out' && grep -q 'clean' '$tmp/out'"
check "works by absolute path from another directory" bash -c "cd / && '$ws/udan' --help >/dev/null"
ln -s "$ws/udan" "$tmp/udan-link"
check "works through a symlink" bash -c "cd / && '$tmp/udan-link' up infra --dry-run 2>&1 | grep -q 'compose -p mariadb'"

# --- manifest ---------------------------------------------------------------------------------------------------
echo "manifest"
cat >"$ws/repos.yaml" <<'EOF'
# comment
repos:
  - name: alpha
    path: alpha-dir
    url: https://example.invalid/alpha.git   # trailing comment
    branch: dev
    build: 'echo "a # not a comment"'   # quoted, so the first # stays
    run: npm start
  - name: beta
    path: beta-dir
    url: 'https://example.invalid/beta.git'
    branch: main
EOF
cat >"$ws/repos.local.yaml" <<'EOF'
repos:
  - name: beta
    url: ../beta-local
    branch: feature
  - name: gamma
    path: /abs/gamma
    url: /srv/git/gamma.git
    branch: dev
    in_place: true
EOF
m() { (source "$ws/scripts/lib/manifest.sh"; manifest_load "$ws" || exit 9; "$@"); }
# shellcheck disable=SC2016  # expanded inside the subshell by eval
check "names in order, local entry appended" [ "$(m eval 'echo "${MANIFEST_NAMES[*]}"')" == "alpha beta gamma" ]
check "inline comment stripped" [ "$(m manifest_get alpha url)" == "https://example.invalid/alpha.git" ]
check "# inside quotes kept" [ "$(m manifest_get alpha build)" == 'echo "a # not a comment"' ]
check "plain value read" [ "$(m manifest_get alpha run)" == "npm start" ]
check "local override of branch" [ "$(m manifest_get beta branch)" == "feature" ]
check "local override keeps base path" [ "$(m manifest_path beta)" == "$ws/beta-dir" ]
check "relative local url made absolute" [ "$(m manifest_url beta)" == "$ws/../beta-local" ]
check "absolute path kept" [ "$(m manifest_path gamma)" == "/abs/gamma" ]
check "in_place read" m manifest_in_place gamma
check "in_place unset is false" bash -c "! (source '$ws/scripts/lib/manifest.sh'; manifest_load '$ws'; manifest_in_place alpha)"
printf 'repos:\n  - path: x\n    url: y\n' >"$ws/repos.local.yaml"
check "entry without name is rejected" bash -c "! (source '$ws/scripts/lib/manifest.sh'; manifest_load '$ws') 2>/dev/null"
printf 'repos:\n  - name: delta\n    path: d\n' >"$ws/repos.local.yaml"
check "entry without url is rejected" bash -c "! (source '$ws/scripts/lib/manifest.sh'; manifest_load '$ws') 2>/dev/null"
rm -f "$ws/repos.local.yaml"

# --- bootstrap --------------------------------------------------------------------------------------------------
echo "bootstrap"
git init -q -b dev "$tmp/seed"
echo one >"$tmp/seed/file.txt"
echo built.txt >"$tmp/seed/.gitignore"
git -C "$tmp/seed" add file.txt .gitignore && git -C "$tmp/seed" commit -qm one
git clone -q --bare "$tmp/seed" "$tmp/origin.git"
git -C "$tmp/seed" remote add origin "$tmp/origin.git"
push() { echo "$1" >"$tmp/seed/file.txt"; git -C "$tmp/seed" commit -qam "$1"; git -C "$tmp/seed" push -q origin dev; }
git init -q -b main "$tmp/outside"
git -C "$tmp/outside" commit -q --allow-empty -m init
git -C "$tmp/outside" switch -q -c topic
cat >"$ws/repos.yaml" <<EOF
repos:
  - name: app
    path: app
    url: ../origin.git
    branch: dev
    build: touch built.txt
    run: ./run.sh
EOF
cat >"$ws/repos.local.yaml" <<EOF
repos:
  - name: mine
    path: $tmp/outside
    url: https://example.invalid/never-used.git
    branch: main
    build: touch built-in-place.txt
    in_place: true
EOF
check "bootstrap clones and builds" rc 0 udan bootstrap
check "clone has the first commit" [ "$(cat "$ws/app/file.txt" 2>/dev/null)" == "one" ]
check "build ran in the clone" [ -f "$ws/app/built.txt" ]
check "in-place checkout built" [ -f "$tmp/outside/built-in-place.txt" ]
check "in-place checkout kept its branch" [ "$(git -C "$tmp/outside" branch --show-current)" == "topic" ]
check "in-place checkout not cloned again" [ ! -e "$ws/never-used" ]
rm -f "$tmp/outside/built-in-place.txt"
push two
check "second bootstrap pulls" rc 0 udan bootstrap app --no-build
check "clone fast-forwarded" [ "$(cat "$ws/app/file.txt")" == "two" ]
check "--no-build skipped the in-place build" [ ! -f "$tmp/outside/built-in-place.txt" ]
echo local >"$ws/app/file.txt"
push three
check "dirty tree: bootstrap still succeeds" rc 0 udan bootstrap app --no-build
check "dirty tree: warned" out_has "uncommitted changes, not updated"
check "dirty tree: local change kept" [ "$(cat "$ws/app/file.txt")" == "local" ]
git -C "$ws/app" checkout -q -- file.txt
git -C "$ws/app" switch -q -c other
check "other branch: bootstrap succeeds" rc 0 udan bootstrap app --no-build
check "other branch: warned and left" bash -c "grep -q \"on 'other'\" '$tmp/out' && [ \"\$(git -C '$ws/app' branch --show-current)\" == other ]"
git -C "$ws/app" switch -q dev
check "bootstrap of an unknown repo exits 2" rc 2 udan bootstrap nope
check "bootstrap --dry-run changes nothing" rc 0 udan bootstrap app --dry-run
check "bootstrap --dry-run prints the pull" out_has "DRY-RUN: git -C $ws/app pull --ff-only origin dev"
check "dry-run did not pull" [ "$(cat "$ws/app/file.txt")" == "two" ]
mv "$bin/java" "$bin/java.off"
printf '#!/usr/bin/env bash\necho "openjdk version \\"17.0.1\\"" >&2\n' >"$bin/java"
chmod +x "$bin/java"
mv "$bin/node" "$bin/node.off"
printf '#!/usr/bin/env bash\necho v18.0.0\n' >"$bin/node"
chmod +x "$bin/node"
check "old java and old node: exit 1" rc 1 udan bootstrap app
check "all missing tools reported at once" bash -c "grep -q 'java 21 (found 17)' '$tmp/out' && grep -q 'node 22+ (found 18)' '$tmp/out'"
mv "$bin/java.off" "$bin/java"
mv "$bin/node.off" "$bin/node"
check "up all prints run commands" rc 0 udan up all --dry-run
check "up all prints the run command with its folder" out_has "app: (cd $ws/app && ./run.sh)"
rm -f "$ws/repos.local.yaml"

# --- up infra --dry-run -----------------------------------------------------------------------------------------
echo "up infra --dry-run"
: >"$FAKE_LOG"
check "up infra --dry-run exits 0" rc 0 udan up infra --dry-run
order="$(grep -oE 'compose -p [a-z]+|wait [0-9]+s|poll docker exec mariadb-local|network create' "$tmp/out" | tr '\n' ',')"
check "order and waits as the original setup" [ "$order" == \
  "network create,compose -p mariadb,wait 10s,poll docker exec mariadb-local,compose -p postgres,wait 5s,compose -p keycloak,wait 15s,compose -p elasticsearch,wait 10s,compose -p nginx,wait 2s," ]
check "network options as the original" out_has "network create --driver bridge --subnet 172.20.0.0/16 --gateway 172.20.0.1 --opt com.docker.network.bridge.name=uda-network --opt com.docker.network.bridge.enable_icc=true uda-network"
check "env and certs printed, not run" bash -c "grep -q 'DRY-RUN: .*infra-env.sh' '$tmp/out' && grep -q 'DRY-RUN: .*infra-certs.sh' '$tmp/out' && [ ! -f '$ws/infra/.env' ]"
check "up -d --remove-orphans with the shared env file" out_has "--env-file $ws/infra/.env up -d --remove-orphans"
check "nothing changed through docker" bash -c "! grep -vE '^compose version' '$FAKE_LOG' | grep -qE '^(compose|network create|network rm|exec|run|start|stop)'"
check "extra/ mentioned" out_has "conf.d/extra/*.conf"
FAKE_RUNNING="postgres-local" FAKE_NETWORK=1 rc 0 udan up infra --dry-run
check "running container skipped" bash -c "grep -q 'postgres-local is already running' '$tmp/out' && ! grep -q 'compose -p postgres' '$tmp/out'"
check "existing network kept" bash -c "! grep -q 'network create' '$tmp/out'"

# --- clean, down, reload, doctor ---------------------------------------------------------------------------------
echo "clean, down, reload, doctor"
"$ws/scripts/infra-env.sh" >/dev/null
: >"$FAKE_LOG"
check "clean without --yes and no tty exits 1" bash -c "'$ws/udan' clean </dev/null >'$tmp/out' 2>&1; [ \$? -eq 1 ]"
check "clean without --yes asked for confirmation" out_has "pass --yes"
check "clean without --yes removed nothing" bash -c "! grep -qE 'down|stop|network rm' '$FAKE_LOG'"
check "clean --yes --dry-run exits 0" rc 0 udan clean --yes --dry-run
rm_order="$(grep -oE 'compose -p [a-z]+ .* down -v --remove-orphans|docker network rm' "$tmp/out" \
  | grep -oE 'compose -p [a-z]+|network rm' | tr '\n' ',')"
check "clean removes in reverse order, then the network" [ "$rm_order" == \
  "compose -p nginx,compose -p elasticsearch,compose -p keycloak,compose -p postgres,compose -p mariadb,network rm," ]
check "clean --dry-run changed nothing" bash -c "! grep -vE '^compose version' '$FAKE_LOG' | grep -qE '^(compose|network rm)'"
: >"$FAKE_LOG"
check "clean refuses when a container still runs after down" \
  bash -c "FAKE_RUNNING=mariadb-local '$ws/udan' clean --yes >'$tmp/out' 2>&1; [ \$? -eq 1 ]"
check "refusal names the container" out_has "still running after down: mariadb-local"
check "refusal removed nothing" bash -c "grep -q 'compose.* stop' '$FAKE_LOG' && ! grep -q 'down -v' '$FAKE_LOG'"
FAKE_RUNNING="nginx-local mariadb-local" rc 0 udan down --dry-run
check "down stops in reverse order" [ "$(grep -oE 'compose -p [a-z]+' "$tmp/out" | tr '\n' ',')" == "compose -p nginx,compose -p mariadb," ]
check "reload nginx when nginx is down exits 1" rc 1 udan reload nginx
check "reload nginx --dry-run prints test then reload" bash -c "FAKE_RUNNING=nginx-local '$ws/udan' reload nginx --dry-run \
  | tr '\n' ' ' | grep -q 'docker exec nginx-local nginx -t .*docker exec nginx-local nginx -s reload'"
check "doctor exits 1 when the stack is down" rc 1 udan doctor
check "doctor --json is valid JSON with ok false" bash -c "'$ws/udan' doctor --json 2>/dev/null | jq -e '.ok == false and (.checks | length > 5)' >/dev/null"
check "status exits 0" rc 0 udan status

if (( fails > 0 )); then echo "test-udan: ${fails} case(s) failed." >&2; exit 1; fi
echo "test-udan: all cases passed."
