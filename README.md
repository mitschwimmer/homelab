# Homelab

OpenTofu manages IncusOS networking, OCI instances, and persistent volumes. OpenBao holds application credentials. An operator copies selected KV fields into private, read-only mounted files; workloads run without OpenBao identities or Agents. See [ADR 0002](docs/adr/0002-openbao-deployment-secrets.md).

## Before applying

This is a fresh-deployment recipe. If the host or any data already exists, **inventory and back it up first**; use the [recovery guide](docs/recovery.md) rather than resetting or wiping drives. In particular, an IncusOS system backup does not include installed application data. Do not apply old OpenTofu state to a different Incus installation, or apply empty state over restored resources without importing them.

On NixOS, enter a shell with the tools used below (`incus.client` provides the CLI without the Incus server):

```sh
nix-shell -p opentofu incus.client openbao openssl gnupg python3
```

The interactive commands below use **Bash** syntax. If your `nix-shell` prompt is in fish, run `bash` before the later CLI steps. The bootstrap script itself runs under Bash.

The commands are `tofu`, `incus`, `bao`, `openssl`, `gpg`, and `python3`. Use your already authenticated Incus remote. Copy `site.auto.tfvars.example` to ignored `site.auto.tfvars` and verify the pool, bridge, physical NIC, MAC, host numbers, and DNS against the **current** host:

```sh
incus storage list measerve:
incus network show measerve:incusbr0
```

The managed bridge needs an `ipv4.address` CIDR, but a new cluster need not have assigned any instance IPs yet. OpenTofu derives four addresses from that CIDR using `private_host_numbers` (offsets from the network address). Choose distinct numbers that do not designate the bridge gateway, network, or broadcast address. If you have an older `site.auto.tfvars`, replace its four `*_ip` entries with the block in the updated example. Reserve Caddy's LAN MAC in the router; configure public DNS for the base domain, `auth`, and `grafana`, and forward HTTP/HTTPS to Caddy. OpenBao stays on the private bridge. Replace `measerve` and `local` below with your site values.

## Bootstrap OpenBao

The pinned official `openbao/openbao:2.7.0` image runs as UID/GID 900. Incus overrides its development-mode command with `bao server -config=/etc/openbao/server.hcl`. Its Raft data, audit log, and TLS files live in `openbao-data`, separate from the image. A restored volume already has TLS files: **do not generate a new key or initialize it again**. From the repository root, run:

```sh
bash scripts/bootstrap-openbao.sh
```

The script creates the volumes, derives OpenBao's IP from Incus, installs TLS after you confirm the volume is new and empty, creates the container, forwards the API temporarily, and initializes and unseals OpenBao with terminal prompts. **Store the printed shares and root token separately off-host** before proceeding. The server configuration declares a persistent file audit device; the script verifies it, enables KV v2, and installs the deployment policy, then closes its port forward. Reruns reuse an existing certificate and initialize only when OpenBao reports that it has not been initialized. If TLS creation stopped partway through, the script refuses to overwrite it; inspect the volume before resetting anything. Review each targeted OpenTofu plan before approving it.

### Recover from the audit API error

If an earlier bootstrap stopped after unsealing with `cannot enable audit device via API`, OpenBao is already initialized. Keep the original shares, token, TLS files, and `openbao-data`. Apply the updated server configuration, restart the container to load its declarative audit stanza, and rerun the script:

```sh
tofu apply -target=incus_storage_volume.openbao_config
incus restart measerve:openbao
bash scripts/bootstrap-openbao.sh
```

The restart seals OpenBao again. Enter **two different existing shares** when the script prompts; it will not call `bao operator init` again. Substitute your Incus remote for `measerve`.

If an existing certificate covers a different bridge IP, the script stops without changing the key, Raft data, or certificate. Reissue **only** that certificate for the computed address, then rerun the script:

```bash
openbao_ip=$(printf 'local.private_ips.openbao\n' | tofu console | python3 -c 'import json,sys; print(json.load(sys.stdin))')
bash scripts/reissue-openbao-cert.sh measerve local "$openbao_ip"
bash scripts/bootstrap-openbao.sh
```

The reissue command keeps the private key. Reissuing the self-signed certificate changes the trust anchor clients must enroll. Do not change the host number on a running OpenBao installation without planning that client update.

### Retry or start over

For a failed bootstrap, **rerun the script first**. The container is replaceable, but `openbao-data` is a separate persistent volume containing Raft state, TLS key, audit log, and any secrets already stored. OpenTofu state tracks these resources; deleting state entries does not delete the real volumes and can make the next apply conflict with them. If you need to keep an initialized installation, preserve the volume and original unseal shares and follow the [recovery guide](docs/recovery.md).

For a deliberate clean start on a new installation, first decide that **all contents of `openbao-data` can be discarded**. If OpenBao was initialized, this loses its KV data and invalidates its old root token and unseal shares; any workloads relying on it will need their secrets restored or replaced. Back up anything you need. Review and approve this targeted destruction, then run the script again:

```sh
tofu destroy -target=incus_instance.openbao -target=incus_storage_volume.openbao_data -target=incus_storage_volume.openbao_config
bash scripts/bootstrap-openbao.sh
```

This removes the tracked OpenBao instance and its two custom volumes; OpenTofu retains state for other resources. It does not reset IncusOS, the bridge, or other workloads. If a volume exists outside the current state, stop and import or inspect it rather than applying fresh state over it. Never remove the whole state file to restart one service.

### Admin access and backups

For later administration, keep `incus port-forward measerve:openbao 8200 18200` running in one terminal. In another, copy the public certificate to workstation **tmpfs** and use the CLI over loopback:

```bash
umask 077
bao_tmp=$(mktemp -d /dev/shm/openbao-admin.XXXXXX)
incus storage volume file pull measerve:local openbao-data/tls/server.crt "$bao_tmp/server.crt"
export BAO_ADDR=https://127.0.0.1:18200 BAO_CACERT="$bao_tmp/server.crt"
```

Store the three shares and initial root token **off-host**, separately from OpenTofu state. Unseal again after a server restart with two different shares. Read the root token without shell history or the CLI token helper when administrative work requires it:

```bash
read -rsp 'OpenBao token: ' BAO_TOKEN; printf '\n'; export BAO_TOKEN
bao token lookup
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

```bash
bao token create -policy=deploy-secrets -ttl=1h -no-default-policy
unset BAO_TOKEN
read -rsp 'Deployment token: ' BAO_TOKEN; printf '\n'; export BAO_TOKEN
python3 scripts/deploy-secrets.py
tofu plan
tofu apply
```

The script reads the non-secret deployment manifest with `tofu console`, including after the targeted bootstrap applies, then fetches KV fields and streams them to Incus volumes. Secret values never enter OpenTofu. Files are mode `0400`, owned by their non-root application UID, in private `0700` volumes mounted read-only. A failed transfer stops deployment; recopy all fields for that service before restarting. Targeted applies above only establish first-boot order; the final full apply reconciles the configuration.

For rotation, update KV, then `python3 scripts/deploy-secrets.py authelia` and `incus restart measerve:authelia` (substitute the service). KV changes do not automatically update files. Remove obsolete files from the volume after removing their manifest entries.

Optional SMTP uses non-secret `authelia_smtp` tfvars and `smtp_password` in KV. Without SMTP, Authelia writes enrollment links to `/data/notification.txt`. Optional Incus metrics requires a separately enrolled `--type=metrics` Incus client certificate, its key and server certificate in `kv/prometheus`, and the non-secret `incus_metrics` tfvars. Create the Prometheus secret volume, deploy its three fields, then apply fully. See [Incus metrics](https://linuxcontainers.org/incus/docs/main/metrics/).

## Check and operate

Inspect `incus list measerve:` and application logs. Verify UID/GID, file modes, read-only mounts, and that each app can read its own files. Reboot and confirm files survive; OpenBao may require manual unseal, while already provisioned workloads can start independently. Test a rotation and a restore from protected backups. Inspect raw state, a saved plan, Incus instance configuration, and logs for a canary value; only OpenBao and the intended secret volume should contain it.

Back up OpenBao Raft **and** TLS/unseal material, IncusOS system configuration and pool keys, Incus application state, application data volumes, and the secret volumes. Protect old snapshots after rotation. Caddy ACME data and Prometheus/Grafana databases also need backups. See [recovery](docs/recovery.md). A commit or push to this repository does not deploy the host.
