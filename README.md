# Homelab

OpenTofu manages measerve networking, OCI instances, persistent volumes, and private workload files. A KeePass database at `$HOME/.keychains/homelab.kdbx` holds application secrets and a separate state encryption passphrase. `scripts/homelab.py` unlocks it and invokes OpenTofu, which encrypts state and saved plans with AES-GCM. See [ADR 0002](docs/adr/0002-keepass-and-encrypted-state.md).

## Enter the Nix shell

On NixOS, start the repository's `shell.nix` from **fish**:

```fish
nix-shell --run fish
```

The Nix shell provides `tofu`, `incus`, `authelia`, and a Python interpreter with PyKeePass and `cryptography`; no pip installation is needed. Run the remaining commands inside it from this repository's root. Use the already authenticated `measerve` Incus remote. Copy `site.auto.tfvars.example` to ignored `site.auto.tfvars` and set your actual pool, bridge, LAN interface, MAC, host numbers, and domain. Remove the former `openbao` host number if updating an older site file. Check the current host:

```fish
incus storage list measerve:
incus network show measerve:incusbr0
```

Caddy's LAN MAC needs a DHCP reservation, public DNS, and ports 80/443 forwarded to it. The private host numbers must be distinct and avoid the bridge gateway and broadcast address.

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

The script creates `$HOME/.keychains/homelab.kdbx` with owner-only permissions, prompts for a master password, and generates stable random application values, an RSA OIDC signing key, and a separate random state encryption passphrase. Repeating the command retains existing values. Back up the KDBX database and master password independently of state. Do not change `state_passphrase` while state or saved plans encrypted with it still exist.

Create a private `users.yml` based on the example. Generate an Argon2 hash for the account password, replace the example hash and email, and keep the `admins` group for a Grafana administrator:

```fish
authelia crypto hash generate argon2
cp authelia/users.yml.example $HOME/.keychains/users.yml
chmod 600 $HOME/.keychains/users.yml
# Edit $HOME/.keychains/users.yml privately, then import it:
python3 scripts/homelab.py set authelia/users_yml < $HOME/.keychains/users.yml
```

Generate a **matching** Grafana OIDC client secret and PBKDF2 hash with Authelia:

```fish
authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986
python3 scripts/homelab.py set grafana/client_secret
python3 scripts/homelab.py set authelia/grafana_client_secret_hash
```

Copy the CLI's “Random Password” into the first prompt and “Digest” into the second. Input is hidden; values are never shell arguments. `set` also accepts redirected stdin for multiline values. Once the KeePass entry and backup are verified, remove the temporary `users.yml` file if it is no longer needed.

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

To rotate a value, update its KeePass entry with `set`, run `python3 scripts/homelab.py tofu plan` and `python3 scripts/homelab.py tofu apply`, then restart the affected workload if it does not reload the file. Back up the KeePass database, encrypted state, IncusOS pool keys, Incus application, and workload volumes as described in [recovery](docs/recovery.md). A push to GitHub does not deploy measerve.
