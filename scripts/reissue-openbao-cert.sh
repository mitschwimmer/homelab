#!/usr/bin/env bash
# Repair a self-signed server certificate after changing the private bridge IP.
# Keep the existing private key and all Raft data.
set -euo pipefail

if (( $# != 3 )); then
  echo "usage: $0 <incus-remote> <storage-pool> <new-openbao-ip>" >&2
  exit 2
fi
remote=$1 pool=$2 address=$3
volume="${remote}:${pool}"

temporary=$(mktemp -d /dev/shm/openbao-cert.XXXXXX)
trap 'rm -rf -- "$temporary"' EXIT
umask 077
incus storage volume file pull "$volume" openbao-data/tls/server.key "$temporary/server.key"
openssl req -new -x509 -sha256 -days 3650 \
  -key "$temporary/server.key" -subj /CN=openbao \
  -addext "subjectAltName=IP:${address},IP:127.0.0.1" \
  -out "$temporary/server.crt"
openssl x509 -in "$temporary/server.crt" -noout -ext subjectAltName
incus storage volume file push "$temporary/server.crt" "$volume" \
  openbao-data/tls/server.crt --uid=900 --gid=900 --mode=0644
echo "Reissued the certificate; the existing private key and Raft data remain in place."
