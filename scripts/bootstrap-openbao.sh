#!/usr/bin/env bash
# Run the first OpenBao deployment and resume safely after an interrupted bootstrap.
# Use Bash even when the calling interactive shell is fish.
# Abort on failed commands, unset variables, and failed pipeline stages.
set -euo pipefail

# Keep initialization output and unseal prompts on an interactive terminal.
if [[ ! -t 0 || ! -t 1 ]]; then
  # Tell the operator why a redirected invocation cannot proceed.
  printf 'Run this script in an interactive terminal.\n' >&2
  # Refuse to create unseal shares that nobody can capture securely.
  exit 2
fi

# Require the local installation settings before touching the Incus remote.
if [[ ! -f site.auto.tfvars ]]; then
  # Point to the installation-specific settings file.
  printf 'Copy and edit site.auto.tfvars.example first.\n' >&2
  # Leave the remote and its state untouched.
  exit 2
fi

# Initialize the pinned provider for this checkout.
tofu init
# Create the persistent data, config, and workload secret volumes before starting OpenBao.
tofu apply -target=incus_storage_volume.openbao_data -target=incus_storage_volume.openbao_config -target=incus_storage_volume.workload_secrets

# Read the Incus remote from the same site settings that OpenTofu applies.
remote=$(printf 'var.site.incus_remote\n' | tofu console | python3 -c 'import json,sys; print(json.load(sys.stdin))')
# Read the configured storage pool without duplicating its name in the script.
pool=$(printf 'var.site.storage_pool\n' | tofu console | python3 -c 'import json,sys; print(json.load(sys.stdin))')
# Derive OpenBao's IP from the current Incus bridge CIDR and configured host number.
openbao_ip=$(printf 'local.private_ips.openbao\n' | tofu console | python3 -c 'import json,sys; print(json.load(sys.stdin))')
# Combine the remote and pool in the form expected by Incus volume commands.
volume="${remote}:${pool}"
# Show the address that will appear in the instance NIC and TLS certificate.
printf 'OpenBao address: %s\n' "$openbao_ip"

# Keep the certificate and temporary metadata on workstation memory-backed storage.
umask 077
# Allocate a private directory for the public certificate and non-secret API listings.
temporary=$(mktemp -d /dev/shm/openbao-bootstrap.XXXXXX)
# Remember the background forward's PID only after it starts.
port_forward_pid=
# Clean up the forward, root token, and temporary files on normal exit or failure.
cleanup() {
  # Stop forwarding the workstation port if this script started it.
  if [[ -n "$port_forward_pid" ]]; then
    # Ignore a forward that already exited during an earlier failure.
    kill "$port_forward_pid" 2>/dev/null || true
  fi
  # Remove the root token from the script environment.
  unset BAO_TOKEN
  # Remove the public certificate and API listings from tmpfs.
  rm -rf -- "$temporary"
}
# Run cleanup even when a later apply, connection, or OpenBao command fails.
trap cleanup EXIT

# Try to retrieve the existing certificate without reading any private key.
if incus storage volume file pull "$volume" openbao-data/tls/server.crt "$temporary/server.crt" >/dev/null 2>&1; then
  # Refuse to replace a certificate automatically if the bridge IP changed.
  if ! openssl x509 -in "$temporary/server.crt" -noout -checkip "$openbao_ip" >/dev/null 2>&1; then
    # Describe the non-destructive repair for an existing TLS key.
    printf 'Existing OpenBao certificate does not cover %s. Reissue it with: bash scripts/reissue-openbao-cert.sh %s %s %s\n' "$openbao_ip" "$remote" "$pool" "$openbao_ip" >&2
    # Keep the data volume, existing certificate, and OpenTofu state intact.
    exit 1
  fi
  # Tell the operator that the existing TLS identity is being reused.
  printf 'Reusing the existing OpenBao certificate and data volume.\n'
else
  # Require explicit confirmation before creating a new TLS identity on this volume.
  read -rp 'No TLS certificate found. Confirm openbao-data is new and empty (type NEW): ' confirmation
  # Refuse to invent a new key for any restored or uncertain data volume.
  if [[ "$confirmation" != NEW ]]; then
    # Explain why the operator must inspect the volume instead.
    printf 'Preserving the volume; inspect it or restore its original TLS files.\n' >&2
    # Leave the original volume and OpenTofu state in place.
    exit 1
  fi
  # Generate a key and certificate only when the volume has no certificate.
  bash scripts/bootstrap-openbao-tls.sh "$remote" "$pool" "$openbao_ip"
  # Retrieve the newly generated public certificate for local CLI trust.
  incus storage volume file pull "$volume" openbao-data/tls/server.crt "$temporary/server.crt"
fi

# Create or reconcile only the OpenBao instance after TLS exists on the volume.
tofu apply -target=incus_instance.openbao
# Point the local CLI at the forwarded port and the volume's public certificate.
export BAO_ADDR=https://127.0.0.1:18200 BAO_CACERT="$temporary/server.crt"
# Forward OpenBao to loopback while this script initializes and configures it.
incus port-forward "${remote}:openbao" 8200 18200 &
# Record the forwarding process so the exit trap can stop it.
port_forward_pid=$!
# Start with a failed readiness status until the OpenBao API responds.
init_status=1
# Allow the server a short time to start before reporting a connection failure.
for attempt in {1..30}; do
  # An exit status of zero means the storage is already initialized.
  if bao operator init -status >/dev/null 2>&1; then
    # Record the initialized state and stop polling.
    init_status=0
    # Leave the readiness loop once the API answers.
    break
  else
    # Preserve OpenBao's status code before the next shell command changes it.
    init_status=$?
    # Exit code two means the API is reachable but its storage is uninitialized.
    if (( init_status == 2 )); then
      # Leave the readiness loop so initialization can begin.
      break
    fi
  fi
  # Give the forwarded API one second before checking again.
  sleep 1
done
# Refuse to initialize anything if the API never returned a known state.
if (( init_status != 0 && init_status != 2 )); then
  # Indicate which connection should be checked before retrying the script.
  printf 'OpenBao API did not become ready on 127.0.0.1:18200; inspect the instance and port forward.\n' >&2
  # Preserve all volumes and state for diagnosis.
  exit 1
fi

# Initialize the Raft storage only if OpenBao explicitly reports it uninitialized.
if (( init_status == 2 )); then
  # Remind the operator where the shares and root token must be stored.
  printf 'Store the three unseal shares and root token separately off-host. They appear once below.\n'
  # Print the shares and root token directly to the operator's terminal.
  bao operator init -key-shares=3 -key-threshold=2
  # Wait for the operator to secure the one-time credentials before continuing.
  read -rp 'After securing the shares and root token off-host, press Enter: ' _
fi

# Query whether the initialized server still requires manual unsealing.
if bao status >/dev/null 2>&1; then
  # State that the existing unsealed server can proceed to configuration.
  printf 'OpenBao is already unsealed.\n'
else
  # Capture the sealed status without relying on a printed secret.
  status=$?
  # Exit code two is the documented sealed state; other codes mean an error.
  if (( status != 2 )); then
    # Keep the data volume intact if status cannot be determined.
    printf 'Could not determine OpenBao seal status.\n' >&2
    # Stop rather than attempting configuration against an unknown server.
    exit 1
  fi
  # Prompt for the first share without putting it in a command argument.
  bao operator unseal
  # Prompt for a different share to reach the configured threshold of two.
  bao operator unseal
  # Confirm the server really became unsealed before requesting a token.
  bao status >/dev/null
fi

# Ask for the initial or another authorized root token without echoing it.
read -rsp 'OpenBao root token: ' BAO_TOKEN
# Restore the terminal line after the hidden token prompt.
printf '\n'
# Make the token available only to commands launched by this script.
export BAO_TOKEN
# Confirm that the token works before configuring audit and KV.
bao token lookup >/dev/null
# Fetch the existing audit backends to support resuming an interrupted setup.
bao audit list -format=json > "$temporary/audits.json"
# Enable the persistent audit log only if it is not already enabled.
if ! python3 -c 'import json,sys; sys.exit("file/" not in json.load(open(sys.argv[1])))' "$temporary/audits.json"; then
  # Store audit entries on the OpenBao data volume.
  bao audit enable file file_path=/var/lib/openbao/audit.log
fi
# Fetch the existing secrets engines to support resuming an interrupted setup.
bao secrets list -format=json > "$temporary/secrets.json"
# Enable the intended KV v2 engine only if the mount does not already exist.
if ! python3 -c 'import json,sys; sys.exit("kv/" not in json.load(open(sys.argv[1])))' "$temporary/secrets.json"; then
  # Create the KV v2 mount used by the workload deployment manifest.
  bao secrets enable -path=kv -version=2 kv
fi
# Install or refresh the scoped deployment policy from the checked-in file.
bao policy write deploy-secrets openbao/policies/deploy-secrets.hcl
# Remind the operator to back up Raft and the TLS-bearing volume off-host.
printf 'OpenBao bootstrapped. Back up Raft, openbao-data, shares, and OpenTofu state before deploying workloads.\n'
