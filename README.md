# Homelab

OpenTofu defines an IncusOS homelab with Caddy, Authelia, Prometheus, Grafana,
and a private OpenBao server. OpenTofu handles instances, networking, persistent
application data, and non-secret configuration. OpenBao holds application
credentials. Each of Authelia, Grafana, and Prometheus runs its own OpenBao
Agent and renders its own credentials to `/run/secrets` (tmpfs).

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

From an authenticated Incus client, substitute your remote name and run:

```sh
incus admin os system factory-reset IncusOS: -d '{"wipe_existing_seeds":true}'
```

The command prompts for confirmation and reboots the system. The explicit
`wipe_existing_seeds` prevents an existing installation seed from
reinstalling applications or applying old configuration on first boot. Set up
IncusOS and its Incus application again, authenticate a new client remote,
and create/select a storage pool and a private managed bridge. Check their
names with `incus storage list IncusOS:` and `incus network list IncusOS:`.
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
OpenTofu definitions for the IncusOS homelab: Caddy serves public HTTPS and
consults Authelia over the private Incus bridge for protected routes.

The [Caddy and Authelia architecture decision](docs/adr/0001-caddy-and-authelia.md)
records the reasons for this arrangement and its tradeoffs.

## Prerequisites

Use a workstation with OpenTofu and an authenticated Incus client remote.
Copy `site.auto.tfvars.example` to `site.auto.tfvars` and adjust its `site`
values for your installation. The example contains the values of the original
deployment, so copying it unchanged preserves those settings. The local file
is ignored by Git. The specified storage pool and private bridge must already
exist; the provider references them but does not create them. The example
file documents how to identify each value. For an existing deployment, add
`prometheus_ip`, `grafana_ip`, and `private_dns_domain` to the local site file;
choose unused private bridge addresses for the first two. The provider defines the public
Docker Hub image remote in HCL and uses your existing Incus client authentication.

Before choosing `authelia_ip` for a new deployment, inspect the bridge's
`ipv4.address` and any `ipv4.dhcp.ranges`, then check its allocations and
DHCP leases (substitute your remote and bridge names):

```sh
incus network show IncusOS:incusbr0
incus network list-allocations IncusOS: --all-projects
incus network list-leases IncusOS:incusbr0
```

Pick unused addresses, ideally outside a configured DHCP range. For IncusOS
metrics, the optional `incus_metrics` site variable names the authenticated
TLS endpoint and its certificate SAN; see [Incus metrics](https://linuxcontainers.org/incus/docs/main/metrics/).

## Publish a pinned OpenBao binary

The server and all agents use the same pinned OpenBao 2.7.0 binary from a
read-only Incus volume. Download the release archive and checksum/signature
from [OpenBao's release](https://github.com/openbao/openbao/releases/tag/v2.7.0),
verify the checksum and signature using the [official installation
instructions](https://openbao.org/docs/install/), and extract `bao` into an
**absolute versioned directory outside this checkout**. Check `bao version`.
Use the binary matching the IncusOS CPU architecture, not necessarily the
workstation architecture. Never replace it in place beneath running services.

Set `TF_VAR_platform_tools_directory` to that directory. A future upgrade
should publish a new versioned volume and deliberately roll the server and
agents. The OpenTofu `source_path` records the path, not the binary contents.

## Provision and initialize OpenBao

```sh
export TF_VAR_platform_tools_directory="$HOME/.local/share/homelab/openbao/2.7.0-linux-amd64"
tofu init
tofu plan
tofu apply
incus exec IncusOS:openbao -- cloud-init status --wait
incus exec IncusOS:openbao -- systemctl status openbao
```

The Debian system container creates its own private TLS key and self-signed
server certificate on the persistent `openbao-data` volume. It listens only
on its private bridge NIC. It uses single-node integrated Raft storage; this
is **not** a highly available server. Its initial unseal requires an operator:

```sh
incus exec IncusOS:openbao -- sh -c 'BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/var/lib/openbao/tls/server.crt /opt/platform/bao operator init -key-shares=3 -key-threshold=2'
```

Store the three unseal shares and initial root token securely outside the
checkout, the host, and OpenTofu state. Use two distinct shares to unseal:

```sh
incus exec IncusOS:openbao -- sh -c 'BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/var/lib/openbao/tls/server.crt /opt/platform/bao operator unseal'
```

Run the unseal command twice, entering one share at each prompt. Repeat after
an OpenBao server reboot. This recovery path does not depend on Authelia.
Retrieve the public CA certificate into a private temporary directory on the
workstation. In a separate terminal, tunnel the server through the authenticated
Incus connection; this listens on **workstation loopback only**:

```sh
incus port-forward IncusOS:openbao 8200 18200
```

Then, in the terminal running `bao`:

```sh
umask 077
tmp=$(mktemp -d /dev/shm/openbao-admin.XXXXXX)
incus file pull IncusOS:openbao/var/lib/openbao/tls/server.crt "$tmp/server.crt"
export BAO_ADDR=https://127.0.0.1:18200
export BAO_CACERT="$tmp/server.crt"
bao login
```

The certificate includes loopback and the private bridge IP as subject
alternative names. Keep the tunnel and this terminal open through enrollment.
Remove the temporary certificate copy when finished. Do not pass the root
token in a shell argument or export it as `TF_VAR_*`.

Enable an audit file on the persistent data volume and create the KV v2 engine
and AppRole authentication once:

```sh
bao audit enable file file_path=/var/lib/openbao/audit.log
bao secrets enable -path=kv -version=2 kv
bao auth enable approle
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
The previous README's workstation directories can serve as a **private staging
area** for these values; OpenTofu no longer reads them. Store each field at
its exact path using `bao kv put -mount=kv`, with `field=@/private/file` so
secret bytes do not appear in a command argument. Do not print or commit them.

| KV v2 key | Field | Source and consumer |
| --- | --- | --- |
| `kv/authelia` | `session_secret`, `storage_encryption_key`, `reset_password_jwt_secret` | Authelia's three `*_FILE` settings |
| `kv/authelia` | `users_yml`, `oidc_hmac_secret`, `oidc_jwks`, `grafana_client_secret_hash` | Authelia configuration and file users |
| `kv/authelia` | `smtp_password` | Optional SMTP notifier |
| `kv/grafana` | `client_secret`, `admin_password`, `secret_key` | Grafana's `__FILE` settings |
| `kv/prometheus` | `agent_ready` | Set to `ready`; identity readiness marker |
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
privately with `incus exec IncusOS:authelia -- cat /data/notification.txt`.
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
incus config trust add-certificate IncusOS: \
  /private/INCUS_METRICS_CERT --type=metrics
```

Prometheus and Grafana's data volumes stay persistent. Extra exporters can be
listed in `prometheus_extra_targets` once reachable on the private network.

## Enroll each workload

OpenTofu contains only policy names, KV paths, and file destinations. Apply
these narrow policies directly to OpenBao, outside OpenTofu:

```sh
bao policy write authelia openbao/policies/authelia.hcl
bao policy write grafana openbao/policies/grafana.hcl
bao policy write prometheus openbao/policies/prometheus.hcl
```

For each of `authelia`, `grafana`, and `prometheus`, configure one AppRole,
create its role ID and SecretID, and deliver them **directly** into that
workload's dedicated protected Incus volume. Substitute the workload name,
UID, remote, and pool in the example. The UIDs are `0`, `472`, and `65534`
respectively:

```sh
service=authelia
uid=0
remote=IncusOS
pool=local
bao write "auth/approle/role/$service" "token_policies=$service" \
  token_no_default_policy=true token_ttl=1h token_max_ttl=4h \
  secret_id_num_uses=0 secret_id_ttl=0
umask 077
tmp=$(mktemp -d /dev/shm/openbao-enroll.XXXXXX)
bao read -field=role_id "auth/approle/role/$service/role-id" > "$tmp/role-id"
bao write -field=secret_id -f "auth/approle/role/$service/secret-id" > "$tmp/secret-id"
incus file pull "$remote:openbao/var/lib/openbao/tls/server.crt" "$tmp/server.crt"
for file in role-id secret-id server.crt; do
  incus storage volume file push "$tmp/$file" "$remote:$pool" \
    "$service-openbao-auth/$file" --uid="$uid" --gid="$uid" --mode=0400
done
rm -rf "$tmp"
```

Restart the three instances after enrollment so each Agent loads its new
credential and CA; a failed first boot can exhaust Incus's restart attempts:

```sh
incus restart IncusOS:authelia
incus restart IncusOS:grafana
incus restart IncusOS:prometheus
```

Never pass a SecretID through HCL, Incus instance config, `user.*`, or
cloud-init. The `secret-id` persists in the individual auth volume so Agent
can authenticate after a reboot. It is a long-lived bootstrap credential:
back up and protect it as such, revoke it when an instance is retired, and
issue a new one for replacement. The Agent token and application secrets
stay only in tmpfs. At startup the wrapper waits for every required file;
if Agent fails, it stops the application and Incus retries the instance.

The AppRole policy permits exactly one `kv/data/<service>` path. Confirm an
allowed read and a denied cross-service read with a test token. A leaked
SecretID must be revoked via the AppRole SecretID accessor; rotate the
application secrets separately. The server must be unsealed before clients
can acquire new tokens; they retry while it is unavailable.

## Verify and operate

After enrollment, inspect `incus list IncusOS:` and the workload logs.
Confirm `/run/secrets` is a tmpfs, files are owned by the service UID and
mode `0400`, and only its own fields are present. Check that the application
starts, then restart each instance to test reacquisition. Stop OpenBao,
restart a workload, bring OpenBao back and unseal it: the application should
start after Agent succeeds. Restart each application after changing a KV v2
value to make it consume the new file. Authelia watches `users.yml` itself;
other application configuration and key changes require a deliberate restart.

Caddy serves `https://grafana.<base_domain>` through Authelia forward auth.
Grafana additionally requires Authelia OIDC membership in `admins` and grants
that group Grafana server administration. An unauthenticated request to
`/private` must redirect or be denied; `/health` stays public. In Grafana
Explore, query `up` and inspect the configured Prometheus targets. Ensure
private bridge DNS resolves `caddy.<private_dns_domain>`; Grafana must also
reach the public `auth.<base_domain>` URL for OIDC callbacks.

Keep OpenTofu plan/state, OpenBao snapshots, the unseal shares, and bootstrap
credentials private. Search a saved **canary** secret after apply in raw
state, `tofu show -json`, Incus instance configuration, and provisioning logs;
it must not be there. Caddy's ACME data, application databases, Prometheus
series, and OpenBao Raft data are persistent and require separate backups.
Committing this repository does not deploy anything.
