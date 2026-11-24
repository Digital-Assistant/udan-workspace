#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # literal $, $(...) and ~ are test data here, never meant to expand
# Test for ./udan without Docker: a copy of the workspace in a temp folder (itself a git repository, like the real
# one), local git repositories as clone URLs, and fakes on PATH:
#   docker  keeps container, network and volume state in files and logs every call; never touches Docker
#   curl    answers the Keycloak and Elasticsearch URLs from state files (default: nothing listens)
#   ss      reports every port as free; java, node, npm report fixed versions; jq logs its arguments
# Covers argument parsing, the manifest parser and repos.local.yaml, the .env reader, bootstrap (clone, pull,
# dirty tree, other branch, ref, in-place, folders that are not checkouts, paths outside the workspace), and the
# real (non-dry) paths of up infra, down, clean, reload nginx, status and doctor against the fake docker.
# Usage: scripts/test-udan.sh. Needs: bash, git, jq, openssl. Exit code: 0 ok, 1 a case failed, 2 a tool missing.
set -uo pipefail

for t in git jq openssl; do
  command -v "$t" >/dev/null 2>&1 || { echo "test-udan: $t not installed" >&2; exit 2; }
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_JQ="$(command -v jq)"
tmp="$(mktemp -d)"
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

fails=0
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }
# check <description> <command...>: passes when the command succeeds.
check() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }

# Git must not read the user's settings (signing, hooks, default branch); every identity is set here.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# Under a git hook these point at the workspace repository and would break the test repositories.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_COMMON_DIR
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# --- fake tools -----------------------------------------------------------------------------------------------
bin="$tmp/bin"
mkdir -p "$bin"
export FAKE_DIR="$tmp/state" FAKE_LOG="$tmp/docker.log"
cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
# Fake docker. State in $FAKE_DIR (one name per line unless noted):
#   exists, running, restarting   stack containers
#   sticky                        containers that ignore "docker stop"
#   volumes                       existing volumes;  network: the file exists = uda-network exists
#   others                        containers outside the stack, "name|state|networks|volumes"
#   mariadb: ok|denied|down   postgres: ok|denied   keycloak-health: healthy|starting|unhealthy   nginx-t: ok|fail
#   fail                          one regex per line; a call whose arguments match fails
echo "$*" >>"$FAKE_LOG"
D="$FAKE_DIR"
has() { grep -qxF -- "$2" "$D/$1" 2>/dev/null; }
add() { has "$1" "$2" || echo "$2" >>"$D/$1"; }
del() { if [[ -f "$D/$1" ]]; then grep -vxF -- "$2" "$D/$1" >"$D/$1.new"; mv "$D/$1.new" "$D/$1"; fi; return 0; }
val() { cat "$D/$1" 2>/dev/null || echo "$2"; }
if [[ -f "$D/fail" ]]; then
  while IFS= read -r re; do
    [[ -n "$re" && "$*" =~ $re ]] && { echo "fake docker: forced failure of: $*" >&2; exit 1; }
  done <"$D/fail"
fi
vols_of() {
  case "$1" in
    mariadb-local) echo mariadb_mariadb_data ;;
    postgres-local) echo postgres_postgres_data ;;
    elasticsearch-local) echo elasticsearch_elasticsearch_data ;;
    nginx-local) echo nginx_nginx-tmp nginx_nginx-cache ;;
  esac
}
state_of() {
  if has running "$1"; then echo running; elif has restarting "$1"; then echo restarting
  elif has exists "$1"; then echo exited; else echo absent; fi
}
all() {
  local c
  if [[ -f "$D/exists" ]]; then
    while IFS= read -r c; do [[ -n "$c" ]] && echo "$c|$(state_of "$c")|uda-network|$(vols_of "$c")"; done <"$D/exists"
  fi
  [[ -f "$D/others" ]] && cat "$D/others"
  return 0
}
case "$1" in
  info) [[ ! -f "$D/daemon-down" ]] ;;
  context) echo default ;;
  compose)
    shift
    proj=""
    while (( $# )); do case "$1" in -p) proj="$2"; shift 2 ;; -f | --env-file) shift 2 ;; *) break ;; esac; done
    if [[ "$1" == up ]]; then
      c="$proj-local"
      add exists "$c"; del restarting "$c"; add running "$c"
      for v in $(vols_of "$c"); do add volumes "$v"; done
    fi
    ;;
  ps)
    shift
    all_flag=0 q=0 fmt='{{.Names}}' filters=()
    while (( $# )); do
      case "$1" in
        -a) all_flag=1; shift ;;
        -q) q=1; shift ;;
        -f | --filter) filters+=("$2"); shift 2 ;;
        --format) fmt="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    while IFS='|' read -r n st nets vols; do
      [[ -n "$n" ]] || continue
      (( all_flag )) || [[ "$st" == running || "$st" == restarting ]] || continue
      keep=1
      for f in "${filters[@]}"; do
        case "$f" in
          name=*) pat="${f#name=}"; [[ "/$n" =~ $pat ]] || keep=0 ;;
          status=*) [[ "$st" == "${f#status=}" ]] || keep=0 ;;
          network=*) [[ " $nets " == *" ${f#network=} "* ]] || keep=0 ;;
          volume=*) [[ " $vols " == *" ${f#volume=} "* ]] || keep=0 ;;
        esac
      done
      (( keep )) || continue
      if (( q )); then echo "id-$n"; elif [[ "$fmt" == *State* ]]; then printf '%s\t%s\n' "$n" "$st"; else echo "$n"; fi
    done < <(all)
    ;;
  network)
    case "$2" in
      inspect) [[ -f "$D/network" ]] ;;
      create) touch "$D/network" ;;
      rm)
        if all | awk -F'|' '$2 == "running" && $3 ~ /uda-network/' | grep -q .; then
          echo "Error response from daemon: network uda-network has active endpoints" >&2; exit 1
        fi
        rm -f "$D/network"
        ;;
    esac
    ;;
  volume)
    case "$2" in
      inspect) has volumes "$3" ;;
      rm)
        shift 2
        for v in "$@"; do
          if all | awk -F'|' -v v="$v" '{ n = split($4, a, " "); for (i = 1; i <= n; i++) if (a[i] == v) f = 1 } END { exit !f }'; then
            echo "Error response from daemon: remove $v: volume is in use" >&2; exit 1
          fi
          del volumes "$v"; echo "$v"
        done
        ;;
    esac
    ;;
  stop) has sticky "$2" || { del running "$2"; del restarting "$2"; }; echo "$2" ;;
  rm) if has running "$2"; then echo "Error: cannot remove a running container" >&2; exit 1; fi; del exists "$2"; echo "$2" ;;
  inspect)
    shift
    fmt=""
    [[ "$1" == -f ]] && { fmt="$2"; shift 2; }
    st="$(state_of "$1")"
    [[ "$st" != absent ]] || { echo "Error: No such object: $1" >&2; exit 1; }
    if [[ "$fmt" == *Health* ]]; then
      case "$1" in keycloak-local) h="$(val keycloak-health healthy)" ;; elasticsearch-local) h=- ;; *) h=healthy ;; esac
      echo "$st $h"
    else
      echo "$st"
    fi
    ;;
  port)
    has running "$2" || exit 1
    case "$2" in
      nginx-local) printf '80/tcp -> 0.0.0.0:80\n443/tcp -> 0.0.0.0:443\n' ;;
      mariadb-local) echo '3306/tcp -> 127.0.0.1:3306' ;;
      postgres-local) echo '5432/tcp -> 127.0.0.1:5432' ;;
      keycloak-local) printf '8080/tcp -> 0.0.0.0:8080\n8443/tcp -> 0.0.0.0:8443\n' ;;
      elasticsearch-local) echo '9200/tcp -> 0.0.0.0:9200' ;;
    esac
    ;;
  exec)
    shift
    while [[ "$1" == -e ]]; do shift 2; done
    c="$1"
    shift
    has running "$c" || { echo "Error: container $c is not running" >&2; exit 1; }
    case "$1" in
      mariadb)
        case "$(val mariadb ok)" in
          ok) ;;
          denied) echo "ERROR 1045 (28000): Access denied for user" >&2; exit 1 ;;
          *) echo "ERROR 2002 (HY000): Can't connect to local server" >&2; exit 1 ;;
        esac
        ;;
      psql) [[ "$(val postgres ok)" == ok ]] || { echo 'psql: error: FATAL:  password authentication failed for user "x"' >&2; exit 1; } ;;
      nginx) [[ "$2" == -t && "$(val nginx-t ok)" == fail ]] && { echo "nginx: [emerg] bad config" >&2; exit 1; } ;;
    esac
    exit 0
    ;;
  logs) echo "fake log line of ${!#}" ;;
  *) exit 0 ;;
esac
EOF
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl. $FAKE_DIR/http-keycloak: up | admin-refused | backend-refused (missing = nothing listens);
# $FAKE_DIR/http-es exists = Elasticsearch green. Logs its arguments to $FAKE_DIR/argv.log.
echo "curl $*" >>"$FAKE_DIR/argv.log"
out="" wfmt="" url="" stdin=0
while (( $# )); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) wfmt="$2"; shift 2 ;;
    -m | -H) shift 2 ;;
    --data-binary) [[ "$2" == @- ]] && stdin=1; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
(( stdin )) && cat >/dev/null
kc="$(cat "$FAKE_DIR/http-keycloak" 2>/dev/null || echo down)"
code=000 body=""
case "$url" in
  */health/live) [[ "$kc" != down ]] && code=200 ;;
  */.well-known/openid-configuration) [[ "$kc" != down ]] && code=200 body='{}' ;;
  */realms/master/protocol/openid-connect/token)
    case "$kc" in up | backend-refused) code=200 body='{"access_token":"t"}' ;; admin-refused) code=401 body='{"error":"invalid_grant"}' ;; esac ;;
  */realms/UDAN/protocol/openid-connect/token)
    case "$kc" in up | admin-refused) code=200 body='{"access_token":"t"}' ;; backend-refused) code=401 body='{"error":"unauthorized_client"}' ;; esac ;;
  */_cluster/health) [[ -f "$FAKE_DIR/http-es" ]] && code=200 body='{"status":"green"}' ;;
esac
if [[ "$code" == 000 ]]; then
  [[ -n "$wfmt" ]] && printf "${wfmt//%\{http_code\}/000}"
  exit 7
fi
[[ "$out" == /dev/null ]] || printf '%s' "$body"
[[ -n "$wfmt" ]] && printf "${wfmt//%\{http_code\}/$code}"
exit 0
EOF
printf '#!/usr/bin/env bash\necho "ss $*" >>"$FAKE_DIR/argv.log"\n' >"$bin/ss"
printf '#!/usr/bin/env bash\necho "jq $*" >>"$FAKE_DIR/argv.log"\nexec %q "$@"\n' "$REAL_JQ" >"$bin/jq"
printf '#!/usr/bin/env bash\necho "openjdk version \\"21.0.2\\" 2024-01-16" >&2\n' >"$bin/java"
printf '#!/usr/bin/env bash\necho v22.1.0\n' >"$bin/node"
printf '#!/usr/bin/env bash\necho 10.0.0\n' >"$bin/npm"
chmod +x "$bin"/*
export PATH="$bin:$PATH" UDAN_WAIT_SCALE=0
unset JAVA_HOME DOCKER_CONTEXT
export UDAN_KEYCLOAK_URL="http://127.0.0.1:9" UDAN_ES_URL="http://127.0.0.1:9" UDAN_SERVER_URL="http://127.0.0.1:9"

reset_state() { rm -rf "$FAKE_DIR"; mkdir -p "$FAKE_DIR"; : >"$FAKE_LOG"; }
reset_state
st() { cat "$FAKE_DIR/$1" 2>/dev/null | sort | paste -sd ' '; }

# --- workspace copy (a git repository with an origin, like a real clone) ----------------------------------------
ws="$tmp/ws"
mkdir -p "$ws/scripts/lib" "$ws/infra"
cp "$ROOT/udan" "$ws/"
cp "$ROOT"/scripts/lib/*.sh "$ws/scripts/lib/"
cp "$ROOT/scripts/infra-env.sh" "$ROOT/scripts/infra-certs.sh" "$ws/scripts/"
cp "$ROOT/infra/.env.example" "$ws/infra/"
for d in "$ROOT"/infra/*/; do
  s="$(basename "$d")"
  [[ -f "$d/docker-compose-$s.yaml" ]] || continue
  mkdir -p "$ws/infra/$s"
  cp "$d/docker-compose-$s.yaml" "$ws/infra/$s/"
done
mkdir -p "$ws/infra/nginx/conf.d/extra"
printf '/*/\n!/scripts/\n!/infra/\n/infra/.env\n/infra/nginx/localhost/\n/infra/keycloak/certs/\n' >"$ws/.gitignore"
git init -q -b dev "$ws"
git -C "$ws" add -A && git -C "$ws" commit -qm workspace
git clone -q --bare "$ws" "$tmp/ws-origin.git"
git -C "$ws" remote add origin "$tmp/ws-origin.git"
git clone -q "$tmp/ws-origin.git" "$tmp/ws-other" && git -C "$tmp/ws-other" commit -q --allow-empty -m "upstream" \
  && git -C "$tmp/ws-other" push -q origin dev
ws_head="$(git -C "$ws" rev-parse HEAD)"
udan() { "$ws/udan" "$@"; }

# rc <expected> <command...>: runs the command, output to $tmp/out, and compares the exit code.
rc() { local want="$1"; shift; "$@" >"$tmp/out" 2>&1; local got=$?; (( got == want )) || { echo "    (exit $got, want $want)" >&2; sed 's/^/    | /' "$tmp/out" | tail -n 8 >&2; return 1; }; }
out_has() { grep -qF -- "$1" "$tmp/out"; }
out_lacks() { ! grep -qF -- "$1" "$tmp/out"; }
log_has() { grep -qE -- "$1" "$FAKE_LOG" 2>/dev/null; }
log_lacks() { ! grep -qE -- "$1" "$FAKE_LOG" 2>/dev/null; }
# log_seq <regex>...: the docker log has lines matching the regexes in this order.
log_seq() { local re n=0 line; for re in "$@"; do line="$(tail -n +$((n + 1)) "$FAKE_LOG" | grep -nE -m1 -- "$re" | cut -d: -f1)"; [[ -n "$line" ]] || return 1; n=$((n + line)); done; }

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
check "--help documents -y and --" bash -c "grep -q -- '-y, --yes' '$tmp/out' && grep -qE -- '^  --  ' '$tmp/out'"
check "-- ends the flags" rc 2 udan -- --dry-run
check "-- ends the flags: the word after it is a command" out_has "unknown command: --dry-run"
check "bad UDAN_WAIT_SCALE exits 2" rc 2 env UDAN_WAIT_SCALE=x "$ws/udan" status
check "works by absolute path from another directory" bash -c "cd / && '$ws/udan' --help >/dev/null"
ln -s "$ws/udan" "$tmp/udan-link"
check "works through a symlink" bash -c "cd / && '$tmp/udan-link' up infra --dry-run 2>&1 | grep -q 'compose -p mariadb'"
mkdir -p "$tmp/nojq"
for t in bash readlink dirname; do ln -s "$(command -v "$t")" "$tmp/nojq/$t"; done
check "doctor --json without jq exits 1" rc 1 env PATH="$tmp/nojq" "$ws/udan" doctor --json
check "doctor --json without jq says so" out_has "doctor --json needs jq"

# --- .env reader ------------------------------------------------------------------------------------------------
echo ".env reader (expected values checked against docker compose config)"
cat >"$tmp/dot.env" <<'EOF'
A1=plain
export A2=val
A3=ab#x # note
A4='lit $x # y'
A5="dq # y"
A6="dq" # comment
A8=  spaced
A10 = v
A11=1
A11=2
A12=
A14=x	# c
A15=a#b
A19=a\b
A20="a\b"
A21=a$A1
A22="a$A1"
A25= #x
A28=a #b #c
A30=pa ss word
EOF
printf 'A31=crlf\r\n' >>"$tmp/dot.env"
dg() { (source "$ws/scripts/lib/dotenv.sh"; dotenv_get "$tmp/dot.env" "$1"); }
dg_is() { local v; v="$(dg "$1")" && [[ "$v" == "$2" ]]; }
dg_rc() { dg "$1" >/dev/null; [[ $? -eq "$2" ]]; }
check "plain value" dg_is A1 plain
check "export prefix" dg_is A2 val
check "' #' starts a comment, '#' inside a word does not" dg_is A3 'ab#x'
check "single quotes keep \$ and #" dg_is A4 'lit $x # y'
check "double quotes keep #" dg_is A5 'dq # y'
check "comment after a closing quote" dg_is A6 dq
check "spaces around an unquoted value removed" dg_is A8 spaced
check "spaces around = allowed" dg_is A10 v
check "last line wins" dg_is A11 2
check "empty value" dg_is A12 ""
check "tab then # is not a comment" dg_is A14 $'x\t# c'
check "backslash in an unquoted value kept" dg_is A19 'a\b'
check "leading # after = is a value" dg_is A25 '#x'
check "first ' #' ends the value" dg_is A28 a
check "inner spaces kept" dg_is A30 'pa ss word'
check "CRLF line" dg_is A31 crlf
check "backslash in double quotes is outside the subset (3)" dg_rc A20 3
check "\$ in an unquoted value is outside the subset (3)" dg_rc A21 3
check "\$ in double quotes is outside the subset (3)" dg_rc A22 3
check "unset name returns 1" dg_rc NOPE 1

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
# load_fails: manifest_load fails; its message is in $tmp/out.
load_fails() { ! (source "$ws/scripts/lib/manifest.sh"; manifest_load "$ws") >"$tmp/out" 2>&1; }
# shellcheck disable=SC2016  # expanded inside the subshell by eval
names() { m eval 'echo "${MANIFEST_NAMES[*]}"'; }
check "names in order, local entry appended" [ "$(names)" == "alpha beta gamma" ]
check "inline comment stripped" [ "$(m manifest_get alpha url)" == "https://example.invalid/alpha.git" ]
check "# inside quotes kept" [ "$(m manifest_get alpha build)" == 'echo "a # not a comment"' ]
check "plain value read" [ "$(m manifest_get alpha run)" == "npm start" ]
check "local override of branch" [ "$(m manifest_get beta branch)" == "feature" ]
check "local override keeps base path" [ "$(m manifest_path beta)" == "$ws/beta-dir" ]
check "relative local url made absolute" [ "$(m manifest_url beta)" == "$ws/../beta-local" ]
check "absolute path kept with in_place" [ "$(m manifest_path gamma)" == "/abs/gamma" ]
check "in_place read" m manifest_in_place gamma
check "in_place unset is false" bash -c "! (source '$ws/scripts/lib/manifest.sh'; manifest_load '$ws'; manifest_in_place alpha)"
sed 's/$/\r/' "$ws/repos.local.yaml" >"$tmp/crlf" && mv "$tmp/crlf" "$ws/repos.local.yaml"
check "CRLF repos.local.yaml: entries read" [ "$(names)" == "alpha beta gamma" ]
check "CRLF repos.local.yaml: values have no CR" [ "$(m manifest_get beta branch)" == "feature" ]
cp "$ws/repos.yaml" "$tmp/repos.yaml.keep"
sed 's/$/\r/' "$tmp/repos.yaml.keep" >"$ws/repos.yaml"
check "CRLF repos.yaml: entries read" [ "$(m manifest_get alpha run)" == "npm start" ]
cp "$tmp/repos.yaml.keep" "$ws/repos.yaml"
printf 'repos:\n' >"$ws/repos.local.yaml"
check "repos: without entries is an error" load_fails
check "repos: without entries is named" out_has '"repos:" has no entries'
printf -- '- name: x\n  path: x\n' >"$ws/repos.local.yaml"
check "content without repos: is an error" load_fails
printf '# only comments\n#repos:\n#  - name: x\n' >"$ws/repos.local.yaml"
check "a file with only comments adds nothing" [ "$(names)" == "alpha beta" ]
printf '# nothing\n' >"$ws/repos.yaml"
rm -f "$ws/repos.local.yaml"
check "a repos.yaml without entries is an error" load_fails
cp "$tmp/repos.yaml.keep" "$ws/repos.yaml"
cp "$ROOT/repos.local.example.yaml" "$ws/repos.local.yaml"
check "a plain copy of repos.local.example.yaml changes nothing" [ "$(names)" == "alpha beta" ]
cp "$ROOT/repos.yaml" "$ws/repos.yaml"
check "the real repos.yaml loads with the example copy" [ "$(names)" == "server client sdk" ]
cp "$tmp/repos.yaml.keep" "$ws/repos.yaml"
local_entry() { printf 'repos:\n  - name: %s\n    path: %s\n    url: /x.git\n    branch: dev\n%s' "$1" "$2" "${3:-}" >"$ws/repos.local.yaml"; }
for p in ../escaped /abs/x '~/x' . a/../b ./x; do
  local_entry esc "$p"
  check "path '$p' without in_place is rejected" load_fails
done
check "path rejection explains in_place" out_has "Use in_place: true"
local_entry ok "~/x" "    in_place: true"$'\n'
check "path '~/x' with in_place is accepted" m true
local_entry ok nested/dir
check "nested relative path is accepted" m true
local_entry ok d "    in_place: yes"$'\n'
check "in_place: yes is rejected" load_fails
local_entry ok d "    in-place: true"$'\n'
check "a dashed key warns as unknown" bash -c "(source '$ws/scripts/lib/manifest.sh'; manifest_load '$ws') 2>&1 | grep -q \"unknown field 'in-place'\""
local_entry 'bad|name' d
check "a name with | is rejected" load_fails
local_entry '$(touch '"$tmp"'/pwned)' d
check "a name with \$(...) is rejected" load_fails
check "a name with \$(...) runs nothing" [ ! -e "$tmp/pwned" ]
printf 'repos:\n  - name: a\n    path: a\n    url: /a\n    branch: dev\n  - name: a\n    path: b\n' >"$ws/repos.local.yaml"
check "a name listed twice in one file is rejected" load_fails
local_entry ok d "    ref: --orphan"$'\n'
check "a ref that starts with - is rejected" load_fails
printf 'repos:\n  - path: x\n    url: y\n' >"$ws/repos.local.yaml"
check "entry without name is rejected" load_fails
printf 'repos:\n  - name: delta\n    path: d\n' >"$ws/repos.local.yaml"
check "entry without url is rejected" load_fails
rm -f "$ws/repos.local.yaml"

# --- bootstrap --------------------------------------------------------------------------------------------------
echo "bootstrap"
git init -q -b dev "$tmp/seed"
echo one >"$tmp/seed/file.txt"
echo built.txt >"$tmp/seed/.gitignore"
git -C "$tmp/seed" add file.txt .gitignore && git -C "$tmp/seed" commit -qm one
git -C "$tmp/seed" tag v1
git clone -q --bare "$tmp/seed" "$tmp/origin.git"
git -C "$tmp/seed" remote add origin "$tmp/origin.git"
push() { echo "$1" >"$tmp/seed/file.txt"; git -C "$tmp/seed" commit -qam "$1"; git -C "$tmp/seed" push -q origin dev; }
git init -q -b main "$tmp/outside"
git -C "$tmp/outside" commit -q --allow-empty -m init
git -C "$tmp/outside" switch -q -c topic
write_repos() {
  cat >"$ws/repos.yaml" <<EOF
repos:
  - name: app
    path: app
    url: ../origin.git
    branch: dev
    build: touch built.txt
    run: ./run.sh
    needs: java
$*
EOF
}
write_repos
cat >"$ws/repos.local.yaml" <<EOF
repos:
  - name: mine
    path: $tmp/outside
    url: https://example.invalid/never-used.git
    branch: main
    build: touch built-in-place.txt
    in_place: true
EOF
mkdir "$ws/app"
check "empty folder: bootstrap clones into it" rc 0 udan bootstrap
check "empty folder: said so" out_has "is empty; cloning into it"
check "clone has the first commit" [ "$(cat "$ws/app/file.txt" 2>/dev/null)" == "one" ]
check "build ran in the clone" [ -f "$ws/app/built.txt" ]
check "the workspace itself was not pulled" [ "$(git -C "$ws" rev-parse HEAD)" == "$ws_head" ]
check "in-place checkout built" [ -f "$tmp/outside/built-in-place.txt" ]
check "in-place checkout kept its branch" [ "$(git -C "$tmp/outside" branch --show-current)" == "topic" ]
check "in-place checkout not cloned again" [ ! -e "$ws/never-used" ]
rm -f "$tmp/outside/built-in-place.txt"
push two
check "second bootstrap pulls" rc 0 udan bootstrap app --no-build
check "clone fast-forwarded" [ "$(cat "$ws/app/file.txt")" == "two" ]
check "--no-build skipped the in-place build" [ ! -f "$tmp/outside/built-in-place.txt" ]
echo scratch >"$ws/app/untracked-note.txt"
push three
check "untracked file: bootstrap still pulls" rc 0 udan bootstrap app --no-build
check "untracked file: fast-forwarded and kept" bash -c "[ \"\$(cat '$ws/app/file.txt')\" == three ] && [ -f '$ws/app/untracked-note.txt' ]"
rm -f "$ws/app/untracked-note.txt"
echo local >"$ws/app/file.txt"
push four
check "dirty tree: bootstrap still succeeds" rc 0 udan bootstrap app --no-build
check "dirty tree: warned" out_has "uncommitted changes, not updated"
check "dirty tree: local change kept" [ "$(cat "$ws/app/file.txt")" == "local" ]
check "dirty tree: --dry-run warns the same way" rc 0 udan bootstrap app --no-build --dry-run
check "dirty tree: --dry-run prints no pull" bash -c "grep -q 'uncommitted changes' '$tmp/out' && ! grep -q 'DRY-RUN: git' '$tmp/out'"
git -C "$ws/app" checkout -q -- file.txt
git -C "$ws/app" switch -q -c other
check "other branch: bootstrap succeeds" rc 0 udan bootstrap app --no-build
check "other branch: warned and left" bash -c "grep -q \"on 'other'\" '$tmp/out' && [ \"\$(git -C '$ws/app' branch --show-current)\" == other ]"
git -C "$ws/app" switch -q dev
check "bootstrap of an unknown repo exits 2" rc 2 udan bootstrap nope
check "bootstrap --dry-run changes nothing" rc 0 udan bootstrap app --dry-run
check "bootstrap --dry-run prints the pull" out_has "DRY-RUN: git -C $ws/app pull --ff-only origin dev"
check "dry-run did not pull" [ "$(cat "$ws/app/file.txt")" == "three" ]

echo "bootstrap: folders that are not checkouts, paths"
write_repos "  - name: junk
    path: junk
    url: ../origin.git
    branch: dev
    build: touch built.txt"
mkdir -p "$ws/junk" && echo x >"$ws/junk/keep.txt"
check "non-empty folder inside the workspace repo: exit 1" rc 1 udan bootstrap junk
check "non-empty folder: named as not a git checkout" out_has "junk exists but is not a git checkout"
check "non-empty folder: no build ran in it" [ ! -e "$ws/junk/built.txt" ]
check "non-empty folder: the workspace was not pulled" [ "$(git -C "$ws" rev-parse HEAD)" == "$ws_head" ]
check "non-empty folder: --dry-run stops the same way" rc 1 udan bootstrap junk --dry-run
check "status shows the folder as not a checkout" bash -c "'$ws/udan' status 2>&1 | grep -q 'junk/* *is not a git checkout\|junk is not a git checkout'"
rm -rf "$ws/junk"
mkdir -p "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$ws/linked"
write_repos "  - name: linked
    path: linked
    url: ../origin.git
    branch: dev"
check "path that is a symlink out of the workspace: exit 1" rc 1 udan bootstrap linked
check "symlink escape named" out_has "resolves outside the workspace"
check "nothing cloned outside" [ -z "$(ls -A "$tmp/elsewhere")" ]
rm -f "$ws/linked"
write_repos
printf 'repos:\n  - name: self\n    path: %s\n    url: /x.git\n    branch: dev\n    build: touch built-self.txt\n    in_place: true\n' "$ws" >"$ws/repos.local.yaml"
check "in_place path = the workspace: exit 1" rc 1 udan bootstrap self
check "in_place workspace: no build in the workspace" [ ! -e "$ws/built-self.txt" ]
printf 'repos:\n  - name: sub\n    path: %s/infra\n    url: /x.git\n    branch: dev\n    build: touch built-sub.txt\n    in_place: true\n' "$ws" >"$ws/repos.local.yaml"
check "in_place folder inside another checkout: exit 1" rc 1 udan bootstrap sub
check "in_place folder inside another checkout: no build" [ ! -e "$ws/infra/built-sub.txt" ]
rm -f "$ws/repos.local.yaml"

echo "bootstrap: ref"
git -C "$ws/app" switch -q -c myfeature
write_repos "    ref: v1"
check "ref on a clean feature branch: exit 0" rc 0 udan bootstrap app --no-build
check "ref on a feature branch: warned, branch kept" bash -c "grep -q \"on 'myfeature', not 'dev'; not switching to ref v1\" '$tmp/out' \
  && [ \"\$(git -C '$ws/app' branch --show-current)\" == myfeature ]"
check "ref on a feature branch: --dry-run prints no checkout" bash -c "'$ws/udan' bootstrap app --no-build --dry-run 2>&1 | grep -q 'not switching' \
  && ! '$ws/udan' bootstrap app --no-build --dry-run 2>&1 | grep -q 'DRY-RUN: git .*checkout'"
git -C "$ws/app" switch -q dev
echo dirty >"$ws/app/file.txt"
check "ref and a dirty tree: --dry-run warns and prints no checkout" rc 0 udan bootstrap app --no-build --dry-run
check "ref and a dirty tree: --dry-run output" bash -c "grep -q 'ref v1 not checked out' '$tmp/out' && ! grep -q 'checkout' <(grep DRY-RUN '$tmp/out')"
check "ref and a dirty tree: real run the same" rc 0 udan bootstrap app --no-build
check "ref and a dirty tree: still on dev" [ "$(git -C "$ws/app" branch --show-current)" == dev ]
git -C "$ws/app" checkout -q -- file.txt
check "ref on the manifest branch: checked out" rc 0 udan bootstrap app --no-build
check "ref on the manifest branch: says it leaves the branch" out_has "leaving branch 'dev' for ref v1"
check "ref on the manifest branch: HEAD at v1" [ "$(git -C "$ws/app" rev-parse HEAD)" == "$(git -C "$ws/app" rev-parse 'v1^{commit}')" ]
git -C "$ws/app" commit -q --allow-empty -m "work on a detached HEAD"
check "detached HEAD with its own commit: exit 0" rc 0 udan bootstrap app --no-build
check "detached HEAD with its own commit: not left" bash -c "grep -q 'on no branch or tag' '$tmp/out' && [ \"\$(git -C '$ws/app' log -1 --format=%s)\" == 'work on a detached HEAD' ]"
git -C "$ws/app" switch -q dev
rm -rf "$ws/app"
check "fresh clone with ref: exit 0" rc 0 udan bootstrap app --no-build
check "fresh clone with ref: at v1" [ "$(cat "$ws/app/file.txt")" == one ]
rm -rf "$ws/app"
check "fresh clone with ref --dry-run prints clone and checkout" rc 0 udan bootstrap app --no-build --dry-run
check "fresh clone with ref --dry-run output" bash -c "grep -q 'DRY-RUN: git clone --branch dev --' '$tmp/out' && grep -q 'checkout -q --detach v1' '$tmp/out'"
write_repos

echo "bootstrap: build tools per repository"
mv "$bin/java" "$bin/java.off"
printf '#!/usr/bin/env bash\necho "openjdk version \\"17.0.1\\"" >&2\n' >"$bin/java"
chmod +x "$bin/java"
write_repos "  - name: web
    path: web
    url: ../origin.git
    branch: dev
    build: touch built-web.txt
    needs: node npm"
check "old java: exit 1" rc 1 udan bootstrap
check "old java: the repository that needs it is named" out_has "app: not built; missing java 21 (found 17)"
check "old java: the other repository still built" [ -f "$ws/web/built-web.txt" ]
check "old java: --dry-run fails the same way" rc 1 udan bootstrap app --dry-run
mv "$bin/java.off" "$bin/java"
rm -rf "$ws/web"
write_repos
check "up all prints run commands" rc 0 udan up all --dry-run
check "up all prints the run command with its folder and UDAN_WORKSPACE" \
  out_has "app: (cd $ws/app && export UDAN_WORKSPACE=$ws && ./run.sh)"

# --- compose files and the stack table --------------------------------------------------------------------------
echo "compose files"
services="$(grep -oE '^  "[A-Za-z]+\|[a-z]+\|[a-z-]+\|[0-9]+\|[^"]*"' "$ROOT/udan" | tr -d '"' | sed 's/^ *//')"
check "the stack table has five services" [ "$(wc -l <<<"$services")" -eq 5 ]
while IFS='|' read -r _ folder container _ vols; do
  f="$ROOT/infra/$folder/docker-compose-$folder.yaml"
  check "$folder: container_name is $container" grep -qE "^ +container_name: $container( |$)" "$f"
  want="$(awk -v p="$folder" '/^volumes:/ { v = 1; next } /^[^ #]/ { v = 0 } v && /^  [A-Za-z0-9_-]+:/ { k = $1; sub(/:$/, "", k); print p "_" k }' "$f" | sort | paste -sd ' ')"
  check "$folder: named volumes are '$vols'" [ "$want" == "$(tr ' ' '\n' <<<"$vols" | sort | paste -sd ' ')" ]
  check "$folder: restart policy set" grep -qE '^ +restart: unless-stopped' "$f"
  check "$folder: no env_file (only named variables)" bash -c "! grep -qE '^ +env_file:' '$f'"
done <<<"$services"
check "no --remove-orphans anywhere in udan" bash -c "! grep -q -- '--remove-orphans' '$ROOT/udan'"
check "MariaDB health check does not interpolate the password" bash -c "! grep -q '\${UDAN_DB_PASSWORD}' <(grep -A2 'healthcheck:' '$ROOT/infra/mariadb/docker-compose-mariadb.yaml')"

# --- up infra --dry-run -----------------------------------------------------------------------------------------
echo "up infra --dry-run"
reset_state
check "up infra --dry-run exits 0" rc 0 udan up infra --dry-run
order="$(grep -oE 'compose -p [a-z]+|wait [0-9]+s|poll docker (exec mariadb|inspect keycloak)-local|network create' "$tmp/out" | tr '\n' ',')"
check "order and waits as the original setup, plus the readiness polls" [ "$order" == \
  "network create,compose -p mariadb,wait 10s,poll docker exec mariadb-local,compose -p postgres,wait 5s,compose -p keycloak,wait 15s,poll docker inspect keycloak-local,compose -p elasticsearch,wait 10s,compose -p nginx,wait 2s," ]
check "network options as the original" out_has "network create --driver bridge --subnet 172.20.0.0/16 --gateway 172.20.0.1 --opt com.docker.network.bridge.name=uda-network --opt com.docker.network.bridge.enable_icc=true uda-network"
check "env and certs printed, not run" bash -c "grep -q 'DRY-RUN: .*infra-env.sh' '$tmp/out' && grep -q 'DRY-RUN: .*infra-certs.sh' '$tmp/out' && [ ! -f '$ws/infra/.env' ]"
check "up -d with the shared env file, no --remove-orphans" bash -c "grep -q -- '--env-file $ws/infra/.env up -d\$' '$tmp/out'"
check "nothing changed through docker" bash -c "! grep -vE '^compose version' '$FAKE_LOG' | grep -qE '^(compose|network create|network rm|exec|run|start|stop|rm|volume rm)'"
check "extra/ mentioned" out_has "conf.d/extra/*.conf"
echo postgres-local >"$FAKE_DIR/exists"; echo postgres-local >"$FAKE_DIR/running"; touch "$FAKE_DIR/network"
rc 0 udan up infra --dry-run
check "running container skipped" bash -c "grep -q 'postgres-local is already running' '$tmp/out' && ! grep -q 'compose -p postgres' '$tmp/out'"
check "existing network kept" bash -c "! grep -q 'network create' '$tmp/out'"

# --- up infra, real run against the fake docker ---------------------------------------------------------------
echo "up infra (fake docker)"
reset_state
rm -f "$ws/infra/.env"
check "up infra exits 0" rc 0 udan up infra
check "infra/.env created with mode 600" [ "$(stat -c %a "$ws/infra/.env" 2>/dev/null)" == 600 ]
check "certificate created" [ -f "$ws/infra/nginx/localhost/localhost.crt" ]
check "start order: network, MariaDB, readiness, Postgres, Keycloak, health, Elasticsearch, Nginx" log_seq \
  '^network create' '^compose -p mariadb .* up -d$' '^exec .*mariadb-local mariadb' '^compose -p postgres .* up -d$' \
  '^compose -p keycloak .* up -d$' '^inspect .*keycloak-local' '^compose -p elasticsearch .* up -d$' '^compose -p nginx .* up -d$'
check "five containers run" [ "$(st running)" == "elasticsearch-local keycloak-local mariadb-local nginx-local postgres-local" ]
check "no --remove-orphans" log_lacks 'remove-orphans'
: >"$FAKE_LOG"
check "second up infra exits 0" rc 0 udan up infra
check "second up infra starts nothing" log_lacks '^compose .* up'
check "a running MariaDB gets one login try" [ "$(grep -c 'mariadb-local mariadb' "$FAKE_LOG")" -eq 1 ]
sed -i '/postgres-local/d' "$FAKE_DIR/running"; echo postgres-local >"$FAKE_DIR/restarting"
: >"$FAKE_LOG"
check "a restarting container is not 'already running'" rc 0 udan up infra
check "the restarting container was started" log_has '^compose -p postgres .* up -d$'
echo denied >"$FAKE_DIR/mariadb"
: >"$FAKE_LOG"
check "running MariaDB refuses the login: exit 1" rc 1 udan up infra
check "refusal: one try, then the volume hint" bash -c "[ \$(grep -c 'mariadb-local mariadb' '$FAKE_LOG') -eq 1 ] && grep -q 'keep the passwords' '$tmp/out'"
check "refusal: stops before Postgres" log_lacks 'postgres'
echo down >"$FAKE_DIR/mariadb"
sed -i '/mariadb-local/d' "$FAKE_DIR/running"
check "MariaDB never ready: exit 1" rc 1 udan up infra
check "MariaDB never ready: last log lines shown" bash -c "grep -q 'did not accept connections' '$tmp/out' && grep -q 'fake log line of mariadb-local' '$tmp/out'"
check "MariaDB never ready: no clean hint" out_lacks "./udan clean"
rm -f "$FAKE_DIR/mariadb"
echo unhealthy >"$FAKE_DIR/keycloak-health"
check "Keycloak unhealthy: exit 1" rc 1 udan up infra
check "Keycloak unhealthy: state and last log lines shown" bash -c "grep -q 'Keycloak is not ready (state: running unhealthy)' '$tmp/out' && grep -q 'fake log line of keycloak-local' '$tmp/out'"
echo starting >"$FAKE_DIR/keycloak-health"
check "Keycloak still starting after the polls: exit 1" rc 1 udan up infra
rm -f "$FAKE_DIR/keycloak-health"
cp "$ws/infra/.env" "$tmp/env.keep"
sed -i 's/^UDAN_DB_PASSWORD=.*/UDAN_DB_PASSWORD=ab$cd/' "$ws/infra/.env"
: >"$FAKE_LOG"
check "a \$ in an unquoted .env value: exit 1" rc 1 udan up infra
check "a \$ value: named, with the fix" bash -c "grep -q 'UDAN_DB_PASSWORD uses' '$tmp/out' && grep -q 'single quotes' '$tmp/out'"
check "a \$ value: nothing started" log_lacks '^(compose -p|network create)'
sed -i "s/^UDAN_DB_PASSWORD=.*/UDAN_DB_PASSWORD='ab\$cd'/" "$ws/infra/.env"
check "the same value in single quotes is accepted" rc 0 udan up infra
cp "$tmp/env.keep" "$ws/infra/.env"
if (( EUID != 0 )); then
  rm -f "$ws/infra/nginx/localhost/"*
  chmod 555 "$ws/infra/nginx/localhost"
  : >"$FAKE_LOG"
  check "certificate folder not writable: exit 1" rc 1 udan up infra
  check "certificate failure: openssl's error is shown" out_has "Permission denied"
  check "certificate failure: clear message" out_has "could not create the dev certificate"
  check "certificate failure: nothing started" log_lacks '^(compose -p|network create)'
  chmod 755 "$ws/infra/nginx/localhost"
fi
printf 'repos:\n  - name: broken\n' >"$ws/repos.local.yaml"
: >"$FAKE_LOG"
check "up all with a broken repos.local.yaml: exit 1" rc 1 udan up all
check "up all with a broken repos.local.yaml: nothing started" log_lacks '^(compose -p|network create)'
rm -f "$ws/repos.local.yaml"
check "up infra after the failures: exit 0" rc 0 udan up infra

# --- reload, down ------------------------------------------------------------------------------------------------
echo "reload nginx, down (fake docker)"
: >"$FAKE_LOG"
check "reload nginx exits 0" rc 0 udan reload nginx
check "reload nginx tests, then reloads" log_seq '^exec nginx-local nginx -t' '^exec nginx-local nginx -s reload'
echo fail >"$FAKE_DIR/nginx-t"
: >"$FAKE_LOG"
check "reload nginx with a bad config: exit 1" rc 1 udan reload nginx
check "bad config: not reloaded" log_lacks 'nginx -s reload'
rm -f "$FAKE_DIR/nginx-t"
check "reload nginx --dry-run prints test then reload" bash -c "'$ws/udan' reload nginx --dry-run \
  | tr '\n' ' ' | grep -q 'docker exec nginx-local nginx -t .*docker exec nginx-local nginx -s reload'"
mv "$ws/infra/.env" "$tmp/env.keep"
: >"$FAKE_LOG"
check "down without infra/.env exits 0" rc 0 udan down
check "down stops by name in reverse order" log_seq '^stop nginx-local' '^stop elasticsearch-local' '^stop keycloak-local' \
  '^stop postgres-local' '^stop mariadb-local'
check "down stopped everything" [ -z "$(st running)" ]
check "down kept containers and volumes" bash -c "[ \$(wc -l <'$FAKE_DIR/exists') -eq 5 ] && [ \$(wc -l <'$FAKE_DIR/volumes') -eq 5 ]"
mv "$tmp/env.keep" "$ws/infra/.env"
check "reload nginx when nginx is down exits 1" rc 1 udan reload nginx
check "reload nginx --dry-run when nginx is down exits 1 too" rc 1 udan reload nginx --dry-run

# --- clean ---------------------------------------------------------------------------------------------------------
echo "clean (fake docker)"
stack_up() { reset_state; UDAN_WAIT_SCALE=0 "$ws/udan" up infra >/dev/null 2>&1; : >"$FAKE_LOG"; }
changed() { grep -qE '^(stop|rm|network rm|volume rm|compose)' "$FAKE_LOG"; }
stack_up
check "clean without --yes and no tty exits 1" bash -c "'$ws/udan' clean </dev/null >'$tmp/out' 2>&1; [ \$? -eq 1 ]"
check "clean without --yes asked for confirmation" out_has "pass --yes"
check "clean without --yes changed nothing" bash -c "! grep -qE '^(stop|rm|network rm|volume rm)' '$FAKE_LOG'"
check "the question names the volumes and the shared names" bash -c "grep -q 'mariadb_mariadb_data, postgres_postgres_data' '$tmp/out' \
  && grep -q 'Any other local setup' '$tmp/out'"
echo "other-app|running|uda-network|" >"$FAKE_DIR/others"
check "another container on the network: exit 1" rc 1 udan clean --yes
check "another container on the network: named" bash -c "grep -q 'other-app (running, attached to uda-network)' '$tmp/out' && grep -q 'Stop them first' '$tmp/out'"
check "another container on the network: nothing changed" bash -c "! grep -qE '^(stop|rm|network rm|volume rm)' '$FAKE_LOG'"
check "another container on the network: stack still runs" [ "$(wc -w <<<"$(st running)")" -eq 5 ]
check "another container on the network: --dry-run stops the same way" rc 1 udan clean --yes --dry-run
echo "old-db|exited||mariadb_mariadb_data" >"$FAKE_DIR/others"
check "another container uses a stack volume: exit 1" rc 1 udan clean --yes
check "another container uses a stack volume: named" out_has "old-db (exited, uses volume mariadb_mariadb_data)"
check "another container uses a stack volume: nothing changed" bash -c "! grep -qE '^(stop|rm|network rm|volume rm)' '$FAKE_LOG'"
rm -f "$FAKE_DIR/others"
check "clean --yes --dry-run exits 0" rc 0 udan clean --yes --dry-run
check "clean --dry-run changed nothing" bash -c "! grep -qE '^(stop|rm|network rm|volume rm)' '$FAKE_LOG' && [ \$(wc -l <'$FAKE_DIR/volumes') -eq 5 ]"
check "clean --dry-run prints the removals" bash -c "grep -q 'DRY-RUN: docker rm mariadb-local' '$tmp/out' \
  && grep -q 'DRY-RUN: docker network rm uda-network' '$tmp/out' && grep -q 'DRY-RUN: docker volume rm nginx_nginx-cache' '$tmp/out'"
echo mariadb-local >"$FAKE_DIR/sticky"
check "clean refuses when a container still runs after down" rc 1 udan clean --yes
check "refusal names the container" out_has "still running after down: mariadb-local"
check "refusal removed nothing" bash -c "grep -q '^stop' '$FAKE_LOG' && ! grep -qE '^(rm|network rm|volume rm)' '$FAKE_LOG'"
stack_up
echo '^volume rm nginx_nginx-tmp' >"$FAKE_DIR/fail"
check "a failing step: exit 1" rc 1 udan clean --yes
check "a failing step: says where it stopped and what was done" bash -c "grep -q 'clean stopped: could not remove volume nginx_nginx-tmp' '$tmp/out' \
  && grep -q 'already done: remove network uda-network' '$tmp/out'"
rm -f "$FAKE_DIR/fail"
check "clean again after the failure: exit 0" rc 0 udan clean --yes
check "clean again: skips what is gone" out_has "container mariadb-local does not exist"
stack_up
check "clean --yes exits 0" rc 0 udan clean --yes
check "clean order: stop, containers, network, volumes" log_seq '^stop nginx-local' '^stop mariadb-local' '^rm nginx-local' \
  '^rm mariadb-local' '^network rm uda-network' '^volume rm nginx_nginx-cache' '^volume rm mariadb_mariadb_data'
check "clean acts on names only (no compose down)" log_lacks '^compose -p'
check "clean removed the stack" bash -c "[ -z \"\$(cat '$FAKE_DIR/exists' '$FAKE_DIR/volumes' 2>/dev/null)\" ] && [ ! -e '$FAKE_DIR/network' ]"
check "clean kept infra/.env and the certificate" bash -c "[ -f '$ws/infra/.env' ] && [ -f '$ws/infra/nginx/localhost/localhost.crt' ]"

# --- doctor, status ------------------------------------------------------------------------------------------------
echo "doctor and status (fake docker)"
doc_line() { grep -qE "^$1 +$2" "$tmp/out"; }
reset_state
check "doctor with the stack down exits 1" rc 1 udan doctor
check "stack down: tools pass" doc_line ok tools
check "stack down: FAIL mariadb-local absent" doc_line FAIL 'mariadb-local +absent'
check "stack down: FAIL network absent" doc_line FAIL 'network uda-network +absent'
check "stack down: FAIL Keycloak health" doc_line FAIL 'Keycloak health .*answered 000'
check "stack down: no clean hint" out_lacks "./udan clean"
stack_up
echo up >"$FAKE_DIR/http-keycloak"; touch "$FAKE_DIR/http-es"
check "doctor with the stack up exits 0" rc 0 udan doctor
check "stack up: all required checks passed" out_has "doctor: all required checks passed."
check "stack up: logins accepted" bash -c "grep -qE '^ok +MariaDB login udan' '$tmp/out' && grep -qE '^ok +Keycloak admin login' '$tmp/out'"
check "stack up: Server is a warning only" doc_line warn Server
check "doctor --json is valid JSON with ok true" bash -c "'$ws/udan' doctor --json 2>/dev/null | '$REAL_JQ' -e '.ok == true and (.checks | length > 20)' >/dev/null"
mv "$bin/java" "$bin/java.off"
check "java missing: doctor still exits 0" rc 0 udan doctor
check "java missing: a build tools warning that names the repository" doc_line warn 'build tools +missing: java 21 .*to build app'
mv "$bin/java.off" "$bin/java"
echo denied >"$FAKE_DIR/mariadb"
check "MariaDB refuses: exit 1" rc 1 udan doctor
check "MariaDB refuses: FAIL line" doc_line FAIL 'MariaDB login udan +UDAN_DB_PASSWORD from infra/.env refused'
check "MariaDB refuses: clean hint" out_has "./udan clean"
echo down >"$FAKE_DIR/mariadb"
check "MariaDB not ready: exit 1" rc 1 udan doctor
check "MariaDB not ready: could not check" doc_line FAIL 'MariaDB login udan +could not check'
check "MariaDB not ready: no clean hint" out_lacks "./udan clean"
rm -f "$FAKE_DIR/mariadb"
echo admin-refused >"$FAKE_DIR/http-keycloak"
check "Keycloak admin refused: exit 1 with FAIL line and hint" bash -c "'$ws/udan' doctor >'$tmp/out' 2>&1; [ \$? -eq 1 ] \
  && grep -qE '^FAIL +Keycloak admin login +KEYCLOAK_ADMIN/KEYCLOAK_ADMIN_PASSWORD refused' '$tmp/out' && grep -q './udan clean' '$tmp/out'"
echo up >"$FAKE_DIR/http-keycloak"
cp "$ws/infra/.env" "$tmp/env.keep"
sed -i 's/^KC_DB_PASSWORD=.*/KC_DB_PASSWORD="a$b"/' "$ws/infra/.env"
check "a \$ in .env: doctor exits 1" rc 1 udan doctor
check "a \$ in .env: FAIL infra/.env names the variable" doc_line FAIL 'infra/.env +value of KC_DB_PASSWORD uses'
check "a \$ in .env: logins skipped, no clean hint" bash -c "grep -qE '^FAIL +database logins +skipped' '$tmp/out' && ! grep -q './udan clean' '$tmp/out'"
cp "$tmp/env.keep" "$ws/infra/.env"
rc 0 udan doctor
secrets="$(grep -E '^(MYSQL_ROOT_PASSWORD|UDAN_DB_PASSWORD|POSTGRES_PASSWORD|KEYCLOAK_ADMIN_PASSWORD|KC_DB_PASSWORD|KC_BACKEND_SERVICE_SECRET)=' "$ws/infra/.env" | cut -d= -f2-)"
check "the .env secrets are the long example values" [ "$(wc -l <<<"$secrets")" -eq 6 ]
leak=0
while IFS= read -r s; do
  grep -qF -- "$s" "$tmp/out" "$FAKE_LOG" "$FAKE_DIR/argv.log" 2>/dev/null && leak=1
done <<<"$secrets"
check "no secret in doctor output or on any docker, curl, jq or ss command line" [ "$leak" -eq 0 ]
check "status exits 0" rc 0 udan status
check "status shows the containers" bash -c "grep -qE 'mariadb-local +running healthy' '$tmp/out'"

if (( fails > 0 )); then echo "test-udan: ${fails} case(s) failed." >&2; exit 1; fi
echo "test-udan: all cases passed."
