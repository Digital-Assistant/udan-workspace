#!/usr/bin/env bash
# Create or renew the self-signed dev certificate for nginx, Keycloak and MariaDB.
# Usage: scripts/infra-certs.sh [--dir INFRA_DIR] [--force]
#   --dir DIR   infra folder to write into (default: <repo>/infra)
#   --force     regenerate even when the certificate is still valid
# Writes DIR/nginx/localhost/{localhost.crt,localhost.key,cert.pem,privkey.pem,fullchain.pem} and copies the
# files Keycloak needs to DIR/keycloak/certs/ and DIR/keycloak/certs/localhost/. The certificate is
# regenerated when it is missing, unreadable, expired or has fewer than 7 days left. Validity: 825 days.
# All generated files are ignored by git. Needs: bash, openssl.
set -euo pipefail

CERT_MIN_VALID_DAYS=7
CERT_VALID_DAYS=825
# Local names only. udan-sdk.nistapp is a local dev host name (no public DNS).
SANS="DNS:localhost,IP:127.0.0.1,DNS:udan-sdk.nistapp"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
infra="$ROOT/infra"
force=0
while (( $# > 0 )); do
  case "$1" in
    --dir)
      infra="${2:?--dir needs a directory}"
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    -h | --help)
      sed -n '2,9p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

command -v openssl >/dev/null 2>&1 || { echo "infra-certs: openssl not installed" >&2; exit 2; }

# Prints the seconds the certificate is still valid for; fails if it is unreadable.
cert_valid_for() {
  local crt=$1 end epoch now
  end=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d'=' -f2) || return 1
  [[ -n "$end" ]] || return 1
  epoch=$(date -d "$end" +%s 2>/dev/null) || return 1
  now=$(date +%s)
  echo $((epoch - now))
}

# generate_cert <dir> <common_name> <file prefix> <sans>
generate_cert() {
  local dir=$1 cn=$2 prefix=$3 sans=$4 reason="" remaining
  if (( force )); then
    reason="forced"
  elif [[ ! -f "$dir/${prefix}.crt" || ! -f "$dir/${prefix}.key" ]]; then
    reason="missing"
  elif ! remaining=$(cert_valid_for "$dir/${prefix}.crt"); then
    reason="unreadable"
  elif (( remaining <= 0 )); then
    reason="expired"
  elif (( remaining < CERT_MIN_VALID_DAYS * 86400 )); then
    reason="expiring in $((remaining / 86400)) day(s)"
  fi

  if [[ -z "$reason" ]]; then
    echo "Certificate for ${cn} in ${dir} exists and is valid."
    return 0
  fi
  echo "Generating certificate for ${cn} in ${dir} (${reason})..."
  # openssl prints progress dots on stderr: keep its output and show it only when it fails.
  local out
  if ! out=$(openssl req -x509 -out "$dir/${prefix}.crt" -keyout "$dir/${prefix}.key" \
    -newkey rsa:2048 -nodes -sha256 -days "$CERT_VALID_DAYS" \
    -subj "/CN=${cn}" -extensions EXT -config <(
      printf '[dn]\nCN=%s\n[req]\ndistinguished_name = dn\n[EXT]\nsubjectAltName=%s\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\n' \
        "$cn" "$sans"
    ) 2>&1); then
    echo "infra-certs: openssl could not write the certificate to ${dir}:" >&2
    printf '%s\n' "$out" | grep -vE '^[.+*]*$' >&2 || true
    echo "infra-certs: check that ${dir} exists and that you own it (a folder that Docker created belongs to root)." >&2
    return 1
  fi
  # .pem aliases (Keycloak and MariaDB read these names).
  cp "$dir/${prefix}.crt" "$dir/cert.pem"
  cp "$dir/${prefix}.key" "$dir/privkey.pem"
  cp "$dir/${prefix}.crt" "$dir/fullchain.pem"
  # World-readable on purpose: the containers run as other users. Dev certificate only.
  chmod 644 "$dir/${prefix}.crt" "$dir/${prefix}.key" "$dir/cert.pem" "$dir/privkey.pem" "$dir/fullchain.pem"
}

nginx_dir="$infra/nginx/localhost"
kc_dir="$infra/keycloak/certs"
mkdir -p "$nginx_dir" "$kc_dir/localhost"

generate_cert "$nginx_dir" "localhost" "localhost" "$SANS"

# Sync to Keycloak (same relative layout as the established setup).
cp "$nginx_dir/localhost.crt" "$nginx_dir/localhost.key" "$kc_dir/localhost/"
cp "$nginx_dir/cert.pem" "$nginx_dir/privkey.pem" "$kc_dir/"
chmod 644 "$kc_dir/localhost/localhost.crt" "$kc_dir/localhost/localhost.key" "$kc_dir/cert.pem" "$kc_dir/privkey.pem"
echo "Certificates ready in $nginx_dir and $kc_dir."
