# Homelab

OpenTofu manages IncusOS networking, OCI instances, persistent volumes, and their private configuration files. A local KeePass database is the source of application secrets. `scripts/homelab.py` unlocks it and passes values to OpenTofu, which encrypts local state and saved plans with AES-GCM. See [ADR 0002](docs/adr/0002-keepass-and-encrypted-state.md).

## Prepare the operator workstation

Use the authenticated `measerve` Incus remote and an OpenTofu version supporting state encryption. Install Python and the two dependencies in `requirements.txt` in an isolated environment. On NixOS, enter a shell with `opentofu`, `incus.client`, Python, and packages for PyKeePass and `cryptography`. Keep your existing `site.auto.tfvars` outside Git, removing the `openbao` host-number entry; the example shows the remaining fields. Verify your pool and bridge before applying:

```sh
incus storage list measerve:
incus network show measerve:incusbr0
```

The bridge address numbers must be distinct and must avoid its gateway and broadcast addresses. Caddy's LAN MAC needs a DHCP reservation, public DNS, and ports 80/443 forwarded to it. The public domain and private bridge are site-specific.

Choose a KeePass database path **outside this checkout**, for example `$HOME/private/homelab.kdbx`. Protect and back it up independently of the OpenTofu state. The commands below abbreviate it as `DB`:

```sh
DB="$HOME/private/homelab.kdbx"
python3 scripts/homelab.py --database "$DB" init-secrets
```

`init-secrets` creates a KDBX database if absent, prompts for its master password, and generates stable random application values, an RSA OIDC signing key, and a **separate** random state-encryption passphrase. Repeating it retains existing entries. Never change or lose `state_passphrase` while any state or saved plan encrypted with it exists.

Complete the required entries by piping private files to `set`:

```sh
python3 scripts/homelab.py --database "$DB" set authelia/users_yml < /private/users.yml
python3 scripts/homelab.py --database "$DB" set grafana/client_secret < /private/grafana-client-secret
python3 scripts/homelab.py --database "$DB" set authelia/grafana_client_secret_hash < /private/grafana-client-hash
```

Create `users.yml` from `authelia/users.yml.example` with an Argon2 password hash and an `admins` user. Generate the **matching** Grafana client secret and PBKDF2 hash using the Authelia CLI, then place its “Random Password” and “Digest” outputs in the two private files above:

```sh
authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986
```

If SMTP is configured in `site.auto.tfvars`, add `authelia/smtp_password`. If Incus metrics are configured, add `prometheus/incus_server_cert`, `prometheus/incus_metrics_cert`, and `prometheus/incus_metrics_key` together. The file-based notifier works without SMTP; without metrics configuration, Prometheus needs none of those entries. Only use `set` with private input files: it reads the value from stdin, never a shell argument. Remove temporary copies after checking the KeePass database and backup.

## Migrate existing plaintext state

**Do this before an ordinary plan or apply with the new checkout.** First back up the existing state outside the repository and keep the earlier plaintext state backups private. The OpenBao retirement step already made such a backup. Check that the existing state reflects the removal of its three resources. Do not reset state or recreate the host.

```sh
python3 scripts/homelab.py --database "$DB" migrate-state
python3 scripts/homelab.py --database "$DB" tofu init
```

The migration runs from a private temporary configuration against the existing local state, with a **one-time** plaintext read fallback. Its targeted plan must create only `terraform_data.state_encryption`, a state-only marker; it must not change any Incus resource. The script verifies the resulting encrypted state envelope. The checked-in configuration has no plaintext fallback and enforces encryption for both state and plans. Keep any `terraform.tfstate.backup` and earlier copies private: OpenTofu may leave pre-migration plaintext backups. Preserve the same state passphrase and an off-host backup of the encrypted state and KeePass database. [OpenTofu's migration documentation](https://opentofu.org/docs/language/state/encryption/) explains why the fallback is needed.

For a brand-new empty installation, skip `migrate-state` and run `tofu init` through the wrapper as above.

## Apply and operate

Run every OpenTofu command through the wrapper, including `init`, `plan`, `apply`, `output`, `state`, and `destroy`, because the state key is required for reading the encrypted state. The wrapper prompts for the KeePass master password each time and supplies secrets as sensitive input variables. It does not write plaintext tfvars or saved plans. Avoid `tofu show -json`, `tofu state pull`, verbose provider logging, and captured process environments unless the output is handled as secret material; encryption protects files at rest, not a running operator process.

```sh
python3 scripts/homelab.py --database "$DB" tofu plan
python3 scripts/homelab.py --database "$DB" tofu apply
```

Review the first plan for intended changes to `authelia-secrets` and `grafana-secrets`, and for **no replacement or deletion of existing application data volumes**. The provider writes mode `0400` files with each application's UID/GID into private `0700` volumes, mounted read-only in each OCI instance. The encrypted state and any saved plan contain the secret values. Incus, its custom volumes and backups also contain them. A change to KeePass takes effect only after `tofu apply`; restart the affected application if it does not reload the changed file. Back up and restore the KeePass database, state, IncusOS pool keys, Incus application, and workload volumes as described in [recovery](docs/recovery.md). A push to GitHub does not deploy the host.
