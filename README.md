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
it must never return `200`. The root site's health route stays public.

## Enrollment messages and SMTP

The default notifier **does not send email**. It writes enrollment and reset
links to `/data/notification.txt` inside the Authelia instance. For immediate
enrollment, read it privately with:

```sh
incus exec IncusOS:authelia -- cat /data/notification.txt
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
