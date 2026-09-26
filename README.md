# Homelab

OpenTofu defines an IncusOS homelab with Caddy, Authelia, Prometheus, Grafana,
and a private OpenBao server. OpenTofu handles instances, networking, persistent
application data, and non-secret destination declarations. OpenBao holds application
credentials. A deployment command copies selected fields into private Incus
volumes, mounted read-only at `/var/lib/homelab-secrets` in non-root OCI
workloads. The workloads do not authenticate to OpenBao.

This configuration is for a **new deployment**. It intentionally has no import
or state migration from the previous workstation-file secret volumes.

## Reset an existing IncusOS installation

A reset is destructive: it erases the main system drive, including installed
applications, their data and configuration, and system-level state. IncusOS
says user-created storage pools are not wiped, but cannot be imported after
reboot without their encryption keys. Make any backups you need first, and
preserve those keys separately. The workstation's old OpenTofu state does not
describe a fresh IncusOS installation; move it out of this checkout and start
with a new state. Do not apply the old state to the reset machine.

From an authenticated Incus client, substitute your remote name (here
`measerve`) and run:

```sh
incus admin os system factory-reset measerve: -d '{"wipe_existing_seeds":true}'
```

The command prompts for confirmation and reboots the system. The explicit
`wipe_existing_seeds` prevents an existing installation seed from
reinstalling applications or applying old configuration on first boot. Set up
IncusOS and its Incus application again, authenticate a new client remote,
and create/select a storage pool and a private managed bridge. Check their
names with `incus storage list measerve:` and `incus network list measerve:`.
See the [IncusOS factory reset reference](https://linuxcontainers.org/incus-os/docs/main/reference/system/backup/#factory-reset).

## Prepare the workstation and site

Install OpenTofu, the Incus client, OpenBao CLI, OpenSSL, and GnuPG. Copy
`site.auto.tfvars.example` to ignored `site.auto.tfvars` and set every value.
The example describes the original host; verify its parent NIC, MAC, bridge
subnet, addresses, storage pool, domain, and DNS before using it. Reserve a
LAN address for Caddy's macvlan MAC and forward public HTTP/HTTPS to it.
Configure public DNS for the base domain, `auth`, and `grafana`. No public route
to OpenBao or the monitoring ports is required.

Inspect the bridge before assigning the four workload IPs:

```sh
incus network show measerve:incusbr0
incus network list-allocations measerve: --all-projects
incus network list-leases measerve:incusbr0
```

Pick unused addresses, ideally outside a configured DHCP range. For IncusOS
metrics, the optional `incus_metrics` site variable names the authenticated
TLS endpoint and its certificate SAN; see [Incus metrics](https://linuxcontainers.org/incus/docs/main/metrics/).

## Publish a pinned OpenBao binary

The server uses a pinned OpenBao 2.7.0 binary from a read-only Incus volume.
Download the release archive and checksum/signature
from [OpenBao's release](https://github.com/openbao/openbao/releases/tag/v2.7.0),
verify the checksum and signature using the [official installation
instructions](https://openbao.org/docs/install/), and extract `bao` into an
**absolute versioned directory outside this checkout**. Check `bao version`.
Use the binary matching the IncusOS CPU architecture, not necessarily the
workstation architecture. Never replace it in place beneath the running server.

Set `TF_VAR_platform_tools_directory` to that directory. A future upgrade
should publish a new versioned volume and deliberately roll the server. The
OpenTofu `source_path` records the path, not the binary contents.

## Provision and initialize OpenBao

```sh
export TF_VAR_platform_tools_directory="$HOME/.local/share/homelab/openbao/2.7.0-linux-amd64"
tofu init
# Bootstrap only OpenBao and the empty secret volumes. Application instances
# are created after their files have been installed.
tofu apply -target=incus_instance.openbao -target=incus_storage_volume.workload_secrets
incus exec measerve:openbao -- cloud-init status --wait
incus exec measerve:openbao -- systemctl status openbao
```

The Debian system container creates its own private TLS key and self-signed
server certificate on the persistent `openbao-data` volume. It listens only
on its private bridge NIC. It uses single-node integrated Raft storage; this
is **not** a highly available server. Its initial unseal requires an operator:

```sh
incus exec measerve:openbao -- sh -c 'BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/var/lib/openbao/tls/server.crt /opt/platform/bao operator init -key-shares=3 -key-threshold=2'
```

Store the three unseal shares and initial root token securely outside the
checkout, the host, and OpenTofu state. Use two distinct shares to unseal:

```sh
incus exec measerve:openbao -- sh -c 'BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/var/lib/openbao/tls/server.crt /opt/platform/bao operator unseal'
```

Run the unseal command twice, entering one share at each prompt. Repeat after
an OpenBao server reboot. This recovery path does not depend on Authelia.
Retrieve the public CA certificate into a private temporary directory on the
workstation. In a separate terminal, tunnel the server through the authenticated
Incus connection; this listens on **workstation loopback only**:

```sh
incus port-forward measerve:openbao 8200 18200
```

Then, in the terminal running `bao`:

```sh
umask 077
tmp=$(mktemp -d /dev/shm/openbao-admin.XXXXXX)
incus file pull measerve:openbao/var/lib/openbao/tls/server.crt "$tmp/server.crt"
export BAO_ADDR=https://127.0.0.1:18200
export BAO_CACERT="$tmp/server.crt"
# In a Bash shell, read the recovery token without putting it in history or
# OpenBao's persistent token helper. Use a scoped token for later deployments.
read -rsp 'OpenBao token: ' BAO_TOKEN; printf '\n'; export BAO_TOKEN
bao token lookup
```

The certificate includes loopback and the private bridge IP as subject
alternative names. Keep the tunnel and this terminal open through enrollment.
Remove the temporary certificate copy when finished. Do not pass the root
token in a shell argument or export it as `TF_VAR_*`. Clear `BAO_TOKEN` when
the administrative session is over.

Enable an audit file on the persistent data volume and create the KV v2 engine
once:

```sh
bao audit enable file file_path=/var/lib/openbao/audit.log
bao secrets enable -path=kv -version=2 kv
bao policy write deploy-secrets openbao/policies/deploy-secrets.hcl
```

Back up the OpenBao Raft data with `bao operator raft snapshot save` to a
private, off-host location. Protect the snapshot and unseal shares, and test
restoration. Preserve the server TLS key/certificate or reenroll all clients
with the restored server CA. Do not reset OpenBao just to rotate a workload
credential.

## Store application secrets

Create the Authelia session, storage encryption, and reset-password keys with
`openssl rand -hex 32`. Prepare `authelia/users.yml.example` privately and
replace its example hash with an Argon2 hash generated by the interactive
Authelia CLI:

```sh
nix shell nixpkgs#authelia --command authelia crypto hash generate argon2
```

Generate an RSA OIDC JWKS, HMAC key, matching Grafana OIDC client
secret and PBKDF2 digest, Grafana secret key, and initial admin password.
A private workstation directory can serve as a temporary staging area for
initial values; OpenTofu never reads it. Remove it after verifying the values
in OpenBao and keep long-term recovery material in a protected backup. Store each field at
its exact path using `bao kv put -mount=kv`, with `field=@/private/file` so
secret bytes do not appear in a command argument. Do not print or commit them.

| KV v2 key | Field | Source and consumer |
| --- | --- | --- |
| `kv/authelia` | `session_secret`, `storage_encryption_key`, `reset_password_jwt_secret` | Authelia's three `*_FILE` settings |
| `kv/authelia` | `users_yml`, `oidc_hmac_secret`, `oidc_jwks`, `grafana_client_secret_hash` | Authelia configuration and file users |
| `kv/authelia` | `smtp_password` | Optional SMTP notifier |
| `kv/grafana` | `client_secret`, `admin_password`, `secret_key` | Grafana's `__FILE` settings |
| `kv/prometheus` | `incus_server_cert`, `incus_metrics_cert`, `incus_metrics_key` | Optional Incus TLS metrics scrape |

For example, `bao kv put -mount=kv authelia
session_secret=@/private/SESSION_SECRET ...` creates the Authelia record;
include **all its fields in one write**, because `kv put` replaces the current
version. Use `bao kv patch` to alter a single field later. Preserve the OIDC
signing key and Authelia storage encryption key for database recovery. The
Grafana client secret's plaintext goes to `kv/grafana` and its **matching
PBKDF2 hash** goes to `kv/authelia`.

The declared Authelia image can generate the matching client secret and hash:

```sh
docker run --rm authelia/authelia:4.39.28 \
  authelia crypto hash generate pbkdf2 --variant sha512 \
  --random --random.length 72 --random.charset rfc3986
```

Store the printed plaintext and digest privately before uploading them to
their separate OpenBao fields. Keep both out of shell history. Ensure each
person who should administer Grafana has `admins` in their `users.yml` groups.

To enable SMTP, set the non-secret `authelia_smtp` object in an ignored local
`*.tfvars` file with `address`, `username`, `sender`, and
`startup_check_address`, and add `smtp_password` to `kv/authelia`. Otherwise,
Authelia writes enrollment links to `/data/notification.txt`; retrieve them
privately with `incus exec measerve:authelia -- cat /data/notification.txt`.
Use `submission://host:587` for STARTTLS or `submissions://host:465` for
implicit TLS. An SMTP configuration change recreates Authelia but preserves
its data volume.

For authenticated Incus metrics, register the metrics certificate with Incus
as **type metrics**, store its private key and the trusted Incus server
certificate in `kv/prometheus`, and then set `incus_metrics` in local tfvars.
For example, generate a separate key/certificate pair in private staging and
register the public certificate:

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -sha384 \
  -keyout /private/INCUS_METRICS_KEY -nodes \
  -out /private/INCUS_METRICS_CERT -days 3650 -subj /CN=homelab-metrics
incus config trust add-certificate measerve: \
  /private/INCUS_METRICS_CERT --type=metrics
```

Prometheus and Grafana's data volumes stay persistent. Extra exporters can be
listed in `prometheus_extra_targets` once reachable on the private network.

## Deploy secret files and application instances

For routine deployments, issue a short-lived token limited to the
`deploy-secrets` policy. After populating KV, while authenticated as the
bootstrap administrator, run:

```sh
bao token create -policy=deploy-secrets -ttl=1h -no-default-policy
unset BAO_TOKEN
read -rsp 'Deployment token: ' BAO_TOKEN; printf '\n'; export BAO_TOKEN
```

Enter the token printed by the first command at the prompt. The initial root
token is for bootstrap and emergency recovery. Issue a new scoped token for
later deployments; keep it out of tfvars files and command arguments.

The `secret_deployment` OpenTofu output maps destination filenames to KV fields
and lists the Incus
volume names, and numeric file owners. Inspect it with
`tofu output -json secret_deployment`; it contains no secret values. The
private volumes are owned by the application UID and mode `0700`; the
individual files are mode `0400`. Authelia runs as UID/GID 1000, Grafana as
UID 472/GID 0, and Prometheus as UID/GID 65534. The secret mounts inside
the containers are read-only.

Once the KV records above exist, keep the authenticated `bao` terminal and
loopback tunnel open, then run from this repository:

```sh
python3 scripts/deploy-secrets.py
# With all required files already present, create the remaining instances.
tofu plan
tofu apply
```

The command invokes `bao kv get -field=...` and pipes its result to
`incus storage volume file push` through process memory. It does not print
values or write workstation files. The `bao` CLI authenticates using your
operator session; it needs read access to the three KV keys. A failed read
stops before writing that service's files. A failed push stops deployment;
check the affected service before starting or restarting it. Re-run the
command safely after correcting the issue. No secret bytes enter OpenTofu
input, plan, output, or state. Treat the Incus control plane and backups of
these volumes as trusted secret storage.

To deploy just one service after updating its KV record, then restart it so
it reads the new values:

```sh
python3 scripts/deploy-secrets.py authelia
incus restart measerve:authelia
```

If a newly created OCI instance is stopped, use `incus start` instead. For
optional authenticated Incus metrics, set `incus_metrics` in your local
`*.tfvars`, put the three Prometheus fields in OpenBao, apply the storage
volume first, deploy `prometheus`, and apply the full configuration:

```sh
tofu apply -target='incus_storage_volume.workload_secrets["prometheus"]'
python3 scripts/deploy-secrets.py prometheus
tofu apply
```

Targeted applies above are only for first-boot ordering. Run a normal
`tofu plan` and `tofu apply` afterward to reconcile the full configuration.
If the application field list changes, update the KV record and redeploy its
files before restarting the service. Removing a field from the manifest does
not delete its old file automatically; remove obsolete secret files manually
from their Incus volume after confirming the application no longer needs them.

## Verify and operate

Inspect `incus list measerve:` and the workload logs. Verify the application
runs under its declared non-root UID, the volume directory has mode `0700`,
and only its intended files exist with UID/GID and mode `0400`. Check from
within each container that the app can read its own secret files. Reboot the
host and verify the files survive and workloads start without OpenBao being
available. Rotate one test field in OpenBao, redeploy it, restart the service,
and verify it consumes the new value. Authelia watches `users.yml` itself;
for other changes, use an explicit restart.

Caddy serves `https://grafana.<base_domain>` through Authelia forward auth.
Grafana additionally requires Authelia OIDC membership in `admins` and grants
that group Grafana server administration. An unauthenticated request to
`/private` must redirect or be denied; `/health` stays public. In Grafana
Explore, query `up` and inspect the configured Prometheus targets. Ensure
private bridge DNS resolves `caddy.<private_dns_domain>`; Grafana must also
reach the public `auth.<base_domain>` URL for OIDC callbacks.

Keep OpenTofu plan/state, OpenBao snapshots, unseal shares, and Incus secret
volume backups private. Search a saved **canary** secret after apply in raw
state, `tofu show -json`, Incus instance configuration, and provisioning logs;
it must not be there. The canary intentionally appears in its Incus volume.
Caddy ACME data, application databases, Prometheus series, secret volumes,
and OpenBao Raft data require backups. A snapshot can retain older secret
values after rotation, so protect and expire backups deliberately.
Committing this repository does not deploy anything.
