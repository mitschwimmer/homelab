# Homelab

OpenTofu definitions for the IncusOS homelab: Caddy serves public HTTPS and
consults Authelia over the private Incus bridge for protected routes.

## Prerequisites

Use a workstation with OpenTofu and an authenticated Incus client remote named
`IncusOS`. The existing `local` storage pool and `incusbr0` bridge are
referenced, not recreated. The provider defines the public Docker Hub image
remote in HCL and uses your existing Incus client authentication.

Caddy has two NICs: a macvlan on host interface `enp129s0` with MAC
`02:00:00:ca:dd:01`, and an internal NIC on `incusbr0`. The router's existing
DHCP reservation gives the macvlan NIC `192.168.1.200`; OpenTofu does not set a
static LAN IP inside Caddy. Keep public DNS and port forwards pointing there.

Authelia has only an `incusbr0` NIC. By default it reserves `10.221.180.10`
on the existing `10.221.180.0/24` bridge; check that this address is free and
set `authelia_bridge_ip` if it is not. Caddy uses that same value as its
internal upstream. Add a public DNS record for `auth.mitschwimmer.de` pointing
to the same public address as `mitschwimmer.de` before testing browser login.

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

Generate an Argon2id hash with `authelia crypto hash generate argon2` from an
Authelia installation, then edit the private `users.yml` to set the hash and a
real email address. The example hash and address are placeholders and cannot
be used for login. Back up the three keys and the user file privately.

The provider's `source_path` inputs read these files during `tofu apply`.
OpenTofu state holds the local paths but not their contents. On rotation, use
a new versioned directory, change `TF_VAR_authelia_secret_directory` and
apply; changing bytes at the same path alone does not trigger a re-upload.

## Apply

From the repository root, on the authenticated workstation:

```sh
export TF_VAR_authelia_secret_directory="$HOME/.config/homelab/authelia/v1"
tofu init
tofu plan
tofu apply
```

Check both services and the public endpoints:

```sh
incus list IncusOS:
curl --resolve mitschwimmer.de:443:192.168.1.200 https://mitschwimmer.de/health
curl --resolve auth.mitschwimmer.de:443:192.168.1.200 https://auth.mitschwimmer.de/api/health
curl -I --resolve mitschwimmer.de:443:192.168.1.200 https://mitschwimmer.de/private
```

The unauthenticated `/private` request must redirect to login or be denied;
it must never return `200`. After logging in, enroll a second factor and
repeat the browser test. Enrollment messages initially go to Authelia's
private `/data/notification.txt` in its persistent volume; read them locally
from the instance and do not paste the links into an issue or log. The root
site's health route stays public.

## Sensitive data

Do not commit passwords, encryption keys, private keys, user databases, or
OpenTofu plans and state. State is local to the operator's workstation and must
be backed up privately; `.gitignore` only prevents accidental staging. Caddy's
ACME data stays in the persistent `caddy-data` Incus volume. Authelia's SQLite
database and notifications stay in the `authelia-data` volume, and its secret
files in a separate read-only mounted volume. Back up the Authelia data volume
together with its secret files: losing the storage encryption key makes stored
data unusable.

`tofu apply` changes the Incus server and requires an authenticated remote.
Committing this repository does not deploy anything.
