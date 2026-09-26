#!/usr/bin/env bash
# First installation only. Never run against a restored OpenBao data volume.
set -euo pipefail

if (( $# != 3 )); then
  echo "usage: $0 <incus-remote> <storage-pool> <openbao-ip>" >&2
  exit 2
fi
remote=$1 pool=$2 address=$3
volume="${remote}:${pool}"
incus storage volume show "$volume" openbao-data >/dev/null

# Create without --force: an existing TLS directory stops accidental key rotation.
temporary=$(mktemp -d /dev/shm/openbao-tls.XXXXXX)
trap 'rm -rf -- "$temporary"' EXIT
umask 077
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -sha256 -nodes -days 3650 -subj /CN=openbao \
  -addext "subjectAltName=IP:${address},IP:127.0.0.1" \
  -keyout "$temporary/server.key" -out "$temporary/server.crt"
incus storage volume file create "$volume" openbao-data/tls \
  --type=directory --uid=900 --gid=900 --mode=0700
incus storage volume file push "$temporary/server.crt" "$volume" \
  openbao-data/tls/server.crt --uid=900 --gid=900 --mode=0644
incus storage volume file push "$temporary/server.key" "$volume" \
  openbao-data/tls/server.key --uid=900 --gid=900 --mode=0600
echo "OpenBao TLS files installed; back up openbao-data before starting the server."
