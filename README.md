# Homelab

OpenTofu manages measerve networking, OCI instances, persistent volumes, and private workload files. A KeePass database at `$HOME/.keychains/homelab.kdbx` holds application secrets and a separate state encryption passphrase. `scripts/homelab.py` unlocks it and invokes OpenTofu, which encrypts state and saved plans with AES-GCM. See [ADR 0002](docs/adr/0002-keepass-and-encrypted-state.md).

## Enter the Nix shell

On NixOS, start the repository's `shell.nix` from **fish**:

```fish
nix-shell --run fish
```

The Nix shell provides `tofu`, `incus`, `authelia`, `openssl`, and a Python interpreter with PyKeePass and `cryptography`; no pip installation is needed. Run the remaining commands inside it from this repository's root. Use the already authenticated `measerve` Incus remote. Copy `site.auto.tfvars.example` to ignored `site.auto.tfvars` and set your actual pool, bridge, LAN interface, MAC, host numbers, and domain. Remove the former `openbao` host number if updating an older site file. Check the current host:

```fish
incus storage list measerve:
incus network show measerve:incusbr0
```

Caddy's LAN MAC needs a DHCP reservation, public DNS for `auth.<base_domain>` and `grafana.<base_domain>`, and ports 80/443 forwarded to it. Grafana signs users in through Authelia OIDC: only members of the `admins` group with a second factor can complete authorization, and Grafana assigns them its server administrator role. The apex domain is not served. The private host numbers must be distinct and avoid the bridge gateway and broadcast address.

## Start with an empty OpenTofu state

This workflow deliberately starts a **new state**. Before using this checkout, finish any cleanup with the old checkout and state, then archive the old state outside the repository. The OpenBao retirement backup is a separate recovery copy. In fish:

```fish
mkdir -p $HOME/.keychains/retired-homelab-state
chmod 700 $HOME/.keychains $HOME/.keychains/retired-homelab-state
for file in terraform.tfstate terraform.tfstate.backup
    if test -f $file
        mv -n $file $HOME/.keychains/retired-homelab-state/
        chmod 600 $HOME/.keychains/retired-homelab-state/$file
    end
end
```

An empty OpenTofu state does **not** mean an empty Incus host. Inspect `incus list measerve:` and `incus storage volume list measerve:local` before applying. The earlier OpenBao bootstrap also created `authelia-secrets` and `grafana-secrets` volumes, and perhaps `prometheus-secrets`. If they still exist, reconcile them using the old state before archiving it, or import them into the new encrypted state. Never run a new-state apply against existing resources of the same names; it will try to create them again. Retain the old state archive privately for recovery.

## Create the KeePass database and application secrets

```fish
python3 scripts/homelab.py init-secrets
```

The script creates `$HOME/.keychains/homelab.kdbx` with owner-only permissions, prompts for a master password, and generates stable random application values, an RSA OIDC signing key, and a separate random state encryption passphrase. It also invokes the Authelia CLI to generate a matching Grafana OIDC client secret and PBKDF2 hash, and saves both directly in KeePass. Repeating the command retains existing values. If only one Grafana OIDC value exists from an interrupted setup, it replaces the partial pair with a fresh matching pair. It repairs permissions on a database made too permissive by older versions of the script. Back up the KDBX database and master password independently of state. Do not change `state_passphrase` while state or saved plans encrypted with it still exist.

Create a private `users.yml` based on the example. Generate an Argon2 hash for the account password, replace the example hash and email, and keep the `admins` group for a Grafana administrator:

```fish
authelia crypto hash generate argon2
cp authelia/users.yml.example $HOME/.keychains/users.yml
chmod 600 $HOME/.keychains/users.yml
# Edit $HOME/.keychains/users.yml privately, then import it:
python3 scripts/homelab.py set authelia/users_yml < $HOME/.keychains/users.yml
```

`set` also accepts redirected stdin for multiline values. Once the KeePass entry and backup are verified, remove the temporary `users.yml` file if it is no longer needed.

If SMTP is configured in `site.auto.tfvars`, add `authelia/smtp_password` with `set`. If Incus metrics are configured, add `prometheus/incus_server_cert`, `prometheus/incus_metrics_cert`, and `prometheus/incus_metrics_key` from private files. The file-based notifier and default Prometheus setup need no optional entries.

## Initialize and apply

Run every OpenTofu command through the wrapper so it can supply the state passphrase and application secrets. It does not create plaintext tfvars or saved plans:

```fish
python3 scripts/homelab.py tofu init
python3 scripts/homelab.py tofu validate
python3 scripts/homelab.py tofu plan
python3 scripts/homelab.py tofu apply
```

Review the plan for only the resources you intend to create. The provider writes mode `0400` secret files with each application's UID/GID into private `0700` volumes, mounted read-only in each OCI instance. Encrypted state and saved plans still contain those values, and Incus volumes and their backups contain the plaintext. File encryption at rest does not hide values from an operator running `tofu show -json`, `tofu state pull`, verbose provider logging, or captured process environments. Treat such output as secret material.

## Collect Incus instance metrics

The Prometheus data source is already provisioned through `grafana/datasources.yml.tftpl`. This repository also provisions the **Dashboards → Homelab → Incus instances** dashboard from `grafana/incus.json`, showing scrape status and per-instance CPU, memory, network, and disk use. Grafana reads both definitions when OpenTofu applies this configuration; dashboard changes in the repository take effect after an apply. To troubleshoot an empty dashboard, query `up{job="incus"}` in Grafana Explore and wait for a scrape.

The IncusOS default Incus application listens on port 8443. Check the address of the `measerve` remote and confirm that its metrics endpoint responds with `incus_` metrics:

```fish
incus remote list
incus query measerve:/1.0/metrics | head -n 10
```

Create a dedicated metrics certificate and enroll only its public certificate with Incus. Do this once; keep the key private and backed up. The Nix shell includes OpenSSL:

```fish
mkdir -p $HOME/.keychains/incus-metrics
chmod 700 $HOME/.keychains/incus-metrics
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -sha384 -nodes -days 3650 -subj '/CN=homelab-prometheus' -keyout $HOME/.keychains/incus-metrics/metrics.key -out $HOME/.keychains/incus-metrics/metrics.crt
chmod 600 $HOME/.keychains/incus-metrics/metrics.key
incus config trust add-certificate measerve: $HOME/.keychains/incus-metrics/metrics.crt --type=metrics
```

The Incus client keeps the trusted server certificate at `$HOME/.config/incus/servercerts/measerve.crt` for a user-configured remote. Inspect its subject alternative names to choose `server_name` for the Prometheus TLS check:

```fish
openssl x509 -in $HOME/.config/incus/servercerts/measerve.crt -noout -ext subjectAltName
```

Import the three files into KeePass. The metrics certificate is public, but keeping the certificate and key together simplifies recovery:

```fish
python3 scripts/homelab.py set prometheus/incus_server_cert < $HOME/.config/incus/servercerts/measerve.crt
python3 scripts/homelab.py set prometheus/incus_metrics_cert < $HOME/.keychains/incus-metrics/metrics.crt
python3 scripts/homelab.py set prometheus/incus_metrics_key < $HOME/.keychains/incus-metrics/metrics.key
```

In ignored `site.auto.tfvars`, set `incus_metrics = { target = "<measerve LAN IP>:8443", server_name = "<DNS name in the certificate SAN>" }`. The target must be reachable from the Prometheus instance on the private bridge; `incus remote list` shows the management endpoint to start from. IncusOS may issue a certificate whose only non-loopback SAN is a UUID-shaped DNS name. In that case, use that exact DNS name for `server_name` while keeping the reachable LAN IP in `target`. The two values serve different purposes: Prometheus connects to `target` and checks the server certificate against `server_name`. The `127.0.0.1` and `::1` SANs are only suitable when connecting over loopback. Then run `python3 scripts/homelab.py tofu plan` and `python3 scripts/homelab.py tofu apply`. The plan should add the private `prometheus-secrets` volume and replace Prometheus to mount it. In Grafana Explore, query `up{job="incus"}`; it should return `1`. Then try `incus_cpu_seconds_total` to confirm instance data is present. Prometheus scrapes this endpoint over TLS every 60 seconds, so wait for a scrape after apply.

To rotate a value, update its KeePass entry with `set`, run `python3 scripts/homelab.py tofu plan` and `python3 scripts/homelab.py tofu apply`, then restart the affected workload if it does not reload the file. Back up the KeePass database, encrypted state, IncusOS pool keys, Incus application, and workload volumes as described in [recovery](docs/recovery.md). A push to GitHub does not deploy measerve.
