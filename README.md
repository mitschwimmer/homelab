# Homelab

OpenTofu manages IncusOS networking, OCI instances, and persistent volumes. OpenBao holds application credentials. An operator copies selected KV fields into private, read-only mounted files; workloads run without OpenBao identities or Agents. See [ADR 0002](docs/adr/0002-openbao-deployment-secrets.md).

## Before applying

This is a fresh-deployment recipe. If the host or any data already exists, **inventory and back it up first**; use the [recovery guide](docs/recovery.md) rather than resetting or wiping drives. In particular, an IncusOS system backup does not include installed application data. Do not apply old OpenTofu state to a different Incus installation, or apply empty state over restored resources without importing them.

On NixOS, enter a shell with the tools used below (`incus.client` provides the CLI without the Incus server):

```sh
nix-shell -p opentofu incus.client openbao openssl gnupg python3
```

The commands are `tofu`, `incus`, `bao`, `openssl`, `gpg`, and `python3`. Use your already authenticated Incus remote. Copy `site.auto.tfvars.example` to ignored `site.auto.tfvars` and verify the pool, bridge, physical NIC, MAC, addresses, and DNS against the **current** host:

```sh
incus storage list measerve:
incus network show measerve:incusbr0
incus network list-allocations measerve: --all-projects
incus network list-leases measerve:incusbr0
```

Set all four `*_ip` values in `site.auto.tfvars` to free addresses **inside** the bridge's `ipv4.address` CIDR, ideally outside its DHCP range. The addresses in the example file describe an earlier host and may not fit a rebuilt bridge. Reserve Caddy's LAN MAC in the router; configure public DNS for the base domain, `auth`, and `grafana`, and forward HTTP/HTTPS to Caddy. OpenBao stays on the private bridge. Replace `measerve` and `local` below with your site values.

## Bootstrap OpenBao

The pinned official `openbao/openbao:2.7.0` image runs as UID/GID 900. Incus overrides its development-mode command with `bao server -config=/etc/openbao/server.hcl`. Its Raft data, audit log, and TLS files live in `openbao-data`, separate from the image. A restored volume already has TLS files: **do not generate a new key or initialize it again**.

```sh
tofu init
# Provision volumes only; the server cannot start until TLS exists.
tofu apply -target=incus_storage_volume.openbao_data \
  -target=incus_storage_volume.openbao_config \
  -target=incus_storage_volume.workload_secrets
# Once on a new, empty volume only; enter the openbao_ip from site.auto.tfvars:
read -rp 'OpenBao IP: ' openbao_ip
bash scripts/bootstrap-openbao-tls.sh measerve local "$openbao_ip"
tofu apply -target=incus_instance.openbao
incus port-forward measerve:openbao 8200 18200
```

If Incus rejects the instance because its IP is outside the bridge subnet, inspect `incus network get measerve:incusbr0 ipv4.address` and the allocations/leases above, then correct `openbao_ip` in `site.auto.tfvars`. If you already ran the TLS bootstrap with the old IP, update **only its certificate** using the existing key before retrying; do not delete `openbao-data` or run initialization:

```sh
read -rp 'Corrected OpenBao IP: ' openbao_ip
bash scripts/reissue-openbao-cert.sh measerve local "$openbao_ip"
tofu apply -target=incus_instance.openbao
```

Enter the same corrected address you put in `site.auto.tfvars`. The reissue command keeps the private key. If the server has already been initialized, preserve its Raft data and unseal shares; reissuing its self-signed certificate changes the trust anchor clients must enroll.

Keep `incus port-forward` running in one terminal. In another, copy the public certificate to workstation **tmpfs** and use the CLI over loopback:

```sh
umask 077
bao_tmp=$(mktemp -d /dev/shm/openbao-admin.XXXXXX)
incus storage volume file pull measerve:local openbao-data/tls/server.crt "$bao_tmp/server.crt"
export BAO_ADDR=https://127.0.0.1:18200 BAO_CACERT="$bao_tmp/server.crt"
bao operator init -key-shares=3 -key-threshold=2
bao operator unseal
bao operator unseal
```

Store the three shares and initial root token **off-host**, separately from OpenTofu state; enter a different share at each unseal prompt. Unseal again after a server restart. If CLI status is sealed, that is expected before unseal. Read the root token without shell history or the CLI token helper:

```sh
read -rsp 'OpenBao token: ' BAO_TOKEN; printf '\n'; export BAO_TOKEN
bao token lookup
bao audit enable file file_path=/var/lib/openbao/audit.log
bao secrets enable -path=kv -version=2 kv
bao policy write deploy-secrets openbao/policies/deploy-secrets.hcl
```

Take an off-host `bao operator raft snapshot save` and export the `openbao-data` volume, which includes the TLS key. Check that both are restorable before depending on this server. Clear `BAO_TOKEN` and remove `$bao_tmp` when finished. Use short-lived scoped tokens for routine deployments.

## Store and deliver application secrets

Generate Authelia's session, storage, and reset keys (`openssl rand -hex 32`); prepare `authelia/users.yml.example` privately with an Argon2 hash (`authelia crypto hash generate argon2`). Generate OIDC JWKS and HMAC keys, the Grafana client secret and matching PBKDF2 hash, Grafana's secret key, and an initial admin password. Put users who administer Grafana in the `admins` group. Do not place values in Git, tfvars, plans, or state.

| KV key | Fields |
| --- | --- |
| `kv/authelia` | `session_secret`, `storage_encryption_key`, `reset_password_jwt_secret`, `users_yml`, `oidc_hmac_secret`, `oidc_jwks`, `grafana_client_secret_hash`; optional `smtp_password` |
| `kv/grafana` | `client_secret`, `admin_password`, `secret_key` |
| `kv/prometheus` | Optional `incus_server_cert`, `incus_metrics_cert`, `incus_metrics_key` |

Use `bao kv put -mount=kv authelia field=@/private/file ...` with **all** fields for that key in one write: `put` replaces the current version. Use `bao kv patch` for one-field changes. The Grafana client plaintext belongs in `kv/grafana`; its matching hash belongs in `kv/authelia`. Authelia's signing and encryption keys are needed for database recovery. The Authelia image can make the pair with `authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986`. Keep temporary source files private and remove them after verification.

With a root session, issue a scoped token, then replace the root token in the environment using the prompt:

```sh
bao token create -policy=deploy-secrets -ttl=1h -no-default-policy
unset BAO_TOKEN
read -rsp 'Deployment token: ' BAO_TOKEN; printf '\n'; export BAO_TOKEN
python3 scripts/deploy-secrets.py
tofu plan
tofu apply
```

The script reads `tofu output -json secret_deployment`, fetches KV fields and streams them to Incus volumes. Values never enter OpenTofu. Files are mode `0400`, owned by their non-root application UID, in private `0700` volumes mounted read-only. A failed transfer stops deployment; recopy all fields for that service before restarting. Targeted applies above only establish first-boot order; the final full apply reconciles the configuration.

For rotation, update KV, then `python3 scripts/deploy-secrets.py authelia` and `incus restart measerve:authelia` (substitute the service). KV changes do not automatically update files. Remove obsolete files from the volume after removing their manifest entries.

Optional SMTP uses non-secret `authelia_smtp` tfvars and `smtp_password` in KV. Without SMTP, Authelia writes enrollment links to `/data/notification.txt`. Optional Incus metrics requires a separately enrolled `--type=metrics` Incus client certificate, its key and server certificate in `kv/prometheus`, and the non-secret `incus_metrics` tfvars. Create the Prometheus secret volume, deploy its three fields, then apply fully. See [Incus metrics](https://linuxcontainers.org/incus/docs/main/metrics/).

## Check and operate

Inspect `incus list measerve:` and application logs. Verify UID/GID, file modes, read-only mounts, and that each app can read its own files. Reboot and confirm files survive; OpenBao may require manual unseal, while already provisioned workloads can start independently. Test a rotation and a restore from protected backups. Inspect raw state, a saved plan, Incus instance configuration, and logs for a canary value; only OpenBao and the intended secret volume should contain it.

Back up OpenBao Raft **and** TLS/unseal material, IncusOS system configuration and pool keys, Incus application state, application data volumes, and the secret volumes. Protect old snapshots after rotation. Caddy ACME data and Prometheus/Grafana databases also need backups. See [recovery](docs/recovery.md). A commit or push to this repository does not deploy the host.
