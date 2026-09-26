# Homelab

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

Pick an address inside the bridge subnet that is neither the gateway nor
already allocated or leased. Prefer one outside the dynamic DHCP range when
that range is explicitly configured. An address absent from those lists can
still be used by an offline device with a manually set IP, so also check any
static address assignments you maintain separately. If migrating the existing
deployment, retain its current `authelia_ip` rather than selecting a new one.

Caddy has a macvlan NIC on `lan_parent` with `caddy_mac`, plus an internal NIC
on `private_bridge`. Reserve a LAN address for that MAC in your router's DHCP
configuration, then forward public HTTP and HTTPS traffic to the reserved
address. OpenTofu does not configure the router, public DNS, or Caddy's LAN IP.
The host cannot directly reach its own macvlan instance; the private bridge
provides an internal connection. Authelia uses `authelia_ip` on that bridge;
Caddy uses the same address as its upstream. Point DNS for `base_domain` and
`auth.<base_domain>` to your public address before testing browser login.

For the existing deployment, the router reserves `192.168.1.200` for the MAC
in the example site file; the existing private bridge uses `10.221.180.0/24`.
When moving to another installation, use its own bridge subnet, interface,
DHCP reservation, DNS records, and port forwards. Keep a separate OpenTofu
state for each installation.

## Prepare Authelia identity data

Keep these files **outside the Git checkout** in a private directory on the
workstation that runs OpenTofu. For example:

```sh
umask 077
mkdir -p "$HOME/.config/homelab/authelia/v1"
openssl rand -hex 32 > "$HOME/.config/homelab/authelia/v1/SESSION_SECRET"
openssl rand -hex 32 > "$HOME/.config/homelab/authelia/v1/STORAGE_ENCRYPTION_KEY"
openssl rand -hex 32 > "$HOME/.config/homelab/authelia/v1/RESET_PASSWORD_JWT_SECRET"
cp authelia/users.yml.example "$HOME/.config/homelab/authelia/v1/users.yml"
```

Generate the password hash **before deploying the service**. On your NixOS
workstation, open a temporary shell with the Authelia CLI and enter the
password at the interactive prompt:

```sh
nix shell nixpkgs#authelia --command authelia crypto hash generate argon2
```

Alternatively, if you have Docker, run the declared image version once:

```sh
docker run --rm -it authelia/authelia:4.39.28 authelia crypto hash generate argon2
```

Copy only the value after `Digest:` (beginning with `$argon2id$`) into the
single-quoted `password` value in the private `users.yml`, and replace the
example email with your real address. Keep the password out of command-line
arguments and shell history. The example hash and address cannot be used for
login. Back up the three keys and the user file privately.

The provider's `source_path` inputs read these files during `tofu apply`.
OpenTofu state holds the local paths but not their contents. On rotation, use
a new versioned directory, change `TF_VAR_authelia_secret_directory` and
apply; changing bytes at the same path alone does not trigger a re-upload.

## Prepare monitoring

Prometheus and Grafana each run as an OCI instance on the private Incus bridge.
Prometheus keeps its time series on a persistent volume and provisions Grafana's
Prometheus data source. Caddy serves `https://grafana.<base_domain>` and asks
Authelia to allow only members of the `admins` group with two factor
authentication. Grafana also uses Authelia OpenID Connect, independently checks
membership in `admins`, and grants those users the Grafana server administrator
role. Prometheus and the application metrics ports are not routed publicly.

Choose free `prometheus_ip` and `grafana_ip` values using the bridge checks
above. The existing example proposes `10.221.180.11` and `10.221.180.12`;
check them before applying. Ensure the private bridge resolves
`caddy.<private_dns_domain>` to Caddy's bridge NIC. If your bridge has a
different `dns.domain`, set `private_dns_domain` accordingly. Create a public
DNS record for `grafana.<base_domain>` pointing to the same address as Caddy.
The router only needs its existing HTTP and HTTPS forwards.

Your **private**, existing Authelia `users.yml` must list `admins` under
`groups` for each person who should administer Grafana. The example already
uses this name; no change is needed if your private file also uses it.

Create another private directory **outside this checkout** and generate the
OIDC signing key, HMAC secret, Grafana encryption key, and bootstrap password:

```sh
umask 077
mkdir -p "$HOME/.config/homelab/monitoring/v1"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
  -out "$HOME/.config/homelab/monitoring/v1/OIDC_JWKS"
openssl rand -hex 32 > "$HOME/.config/homelab/monitoring/v1/OIDC_HMAC_SECRET"
openssl rand -hex 32 > "$HOME/.config/homelab/monitoring/v1/GRAFANA_SECRET_KEY"
openssl rand -hex 32 > "$HOME/.config/homelab/monitoring/v1/GRAFANA_ADMIN_PASSWORD"
```

Generate one client secret and its PBKDF2 digest using the declared Authelia
image (Docker example; the same CLI can run from a local installation):

```sh
docker run --rm authelia/authelia:4.39.28 \
  authelia crypto hash generate pbkdf2 --variant sha512 \
  --random --random.length 72 --random.charset rfc3986
```

Store the printed plaintext secret, without a label or trailing spaces, in
`GRAFANA_CLIENT_SECRET` in that private directory and the printed digest in
`GRAFANA_CLIENT_SECRET_HASH`. These **must match**. Keep both out of shell
history and Git. The digest is loaded by Authelia from its secret volume at
startup; Grafana reads the plaintext using its `__FILE` setting. Back up this
directory and the Grafana data volume privately. Preserve the OIDC signing key
and Grafana encryption key across instance replacements.

By default Prometheus scrapes itself, Caddy, Authelia, and Grafana. IncusOS
instance and host metrics require a separate authenticated TLS connection.
To add it, first check whether your authenticated Incus remote already exposes
`/1.0/metrics` on its HTTPS address. Otherwise, configure the server's
`core.metrics_address` on a reachable internal address (see the [Incus metrics
guide](https://linuxcontainers.org/incus/docs/main/metrics/)). Create a metrics
certificate and register it as **type metrics**, not a general client:

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -sha384 \
  -keyout "$HOME/.config/homelab/monitoring/v1/INCUS_METRICS_KEY" -nodes \
  -out "$HOME/.config/homelab/monitoring/v1/INCUS_METRICS_CERT" -days 3650 \
  -subj "/CN=homelab-metrics"
incus config trust add-certificate IncusOS: \
  "$HOME/.config/homelab/monitoring/v1/INCUS_METRICS_CERT" --type=metrics
```

Copy the Incus server certificate already trusted by the Incus client to
`INCUS_SERVER_CERT` in that private directory (commonly
`$HOME/.config/incus/servercerts/IncusOS.crt`). Check its subject alternative
names with `openssl x509 -in INCUS_SERVER_CERT -noout -text` to select
`incus_metrics.server_name`. Add `incus_metrics` with its reachable host:port
to `site.auto.tfvars`, as shown in the example. TLS server verification and
client certificate authentication remain enabled. If IncusOS already exposes
the HTTPS API to your workstation, do not open a second listener just for this.

Later, after enabling `IMMICH_TELEMETRY_INCLUDE=all` in an Immich deployment,
add its API and microservices `:8081` and `:8082` exporters through
`prometheus_extra_targets`; the example site file shows both jobs. Add other
private HTTP exporters the same way. Do not add targets until they exist.

## Apply

From the repository root, on the authenticated workstation:

```sh
test -e site.auto.tfvars || cp site.auto.tfvars.example site.auto.tfvars
# Review the site values; preserve any existing local settings.
export TF_VAR_authelia_secret_directory="$HOME/.config/homelab/authelia/v1"
export TF_VAR_monitoring_secret_directory="$HOME/.config/homelab/monitoring/v1"
tofu init
tofu plan
tofu apply
```

For an existing deployment, preserve its original site values and inspect
`tofu plan` before applying. This addition creates Prometheus and Grafana,
updates Caddy's configuration, and replaces the Authelia instance to enable
metrics and OIDC while retaining its data and secrets volumes. The plan should
not replace Caddy or destroy existing data volumes. On another IncusOS
installation, use a separate state and site file. Do not commit either.

Check both services and the public endpoints:

```sh
INCUS_REMOTE=IncusOS # use the remote in your site file
BASE_DOMAIN=mitschwimmer.de # use the domain in your site file
CADDY_LAN_IP=192.168.1.200 # use your router's DHCP reservation
incus list "$INCUS_REMOTE:"
curl --resolve "$BASE_DOMAIN:443:$CADDY_LAN_IP" "https://$BASE_DOMAIN/health"
curl --resolve "auth.$BASE_DOMAIN:443:$CADDY_LAN_IP" "https://auth.$BASE_DOMAIN/api/health"
curl -I --resolve "$BASE_DOMAIN:443:$CADDY_LAN_IP" "https://$BASE_DOMAIN/private"
curl -I --resolve "grafana.$BASE_DOMAIN:443:$CADDY_LAN_IP" "https://grafana.$BASE_DOMAIN/"
```

Check `incus list "$INCUS_REMOTE:"` for Prometheus and Grafana and validate
the configuration with:

```sh
incus exec "$INCUS_REMOTE:prometheus" -- promtool check config /etc/prometheus/prometheus.yml
```

An unauthenticated Grafana request should
redirect to Authelia, and only an `admins` group member should reach Grafana
and see server administration. In Grafana Explore, query `up` and inspect the
Prometheus targets; every configured target should become `1`. For Incus,
also query an `incus_` metric to verify instance data. If Grafana's OIDC
callback fails, check that Grafana can resolve and reach the public
`auth.<base_domain>` URL from its private bridge (the split DNS setup must
work there as well).

The unauthenticated `/private` request must redirect to login or be denied;
it must never return `200`. The root site's health route stays public.

## Enrollment messages and SMTP

The default notifier **does not send email**. It writes enrollment and reset
links to `/data/notification.txt` inside the Authelia instance. For immediate
enrollment, read it privately with:

```sh
incus exec "$INCUS_REMOTE:authelia" -- cat /data/notification.txt
```

To receive those messages in your inbox, create a private file named
`SMTP_PASSWORD` in the same directory as the three keys. Put the SMTP login
password or app password in that file, with mode `0600`. Then create a local
`smtp.auto.tfvars` in the checkout (ignored by Git) containing only the
nonsecret settings supplied by your mail provider:

```hcl
authelia_smtp = {
  address               = "submission://smtp.example.org:587"
  username              = "login@example.org"
  sender                = "Authelia <login@example.org>"
  startup_check_address = "login@example.org"
}
```

Use your provider's actual server, port, account, and permitted sender.
Authelia requires TLS by default. The `submission` scheme uses STARTTLS on
port 587; `submissions` uses implicit TLS on port 465. The SMTP password is
uploaded from the private file and is not embedded in HCL or OpenTofu state.
Run `tofu plan` and `tofu apply` again. Changing the notifier recreates the
Authelia instance so it reads the new configuration, while its data and secret
volumes persist. Trigger a fresh enrollment message after applying; previous
links may have expired. Check the Authelia instance logs if SMTP startup fails.

## Sensitive data

Do not commit passwords, encryption keys, private keys, user databases, or
OpenTofu plans and state. State is local to the operator's workstation and must
be backed up privately; `.gitignore` only prevents accidental staging. Caddy's
ACME data stays in the persistent `caddy-data` Incus volume. Authelia's SQLite
database and filesystem notifications stay in the `authelia-data` volume, and
its secret files in a separate read-only mounted volume. Back up the Authelia data volume
together with its secret files: losing the storage encryption key makes stored
data unusable.

`tofu apply` changes the Incus server and requires an authenticated remote.
Committing this repository does not deploy anything.
