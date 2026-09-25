# Homelab

OpenTofu definitions for the IncusOS homelab: Caddy serves public HTTPS and
consults Authelia over the private Incus bridge for protected routes.

## Prerequisites

Use a workstation with OpenTofu and an authenticated Incus client remote.
Copy `site.auto.tfvars.example` to `site.auto.tfvars` and adjust its `site`
values for your installation. The example contains the values of the original
deployment, so copying it unchanged preserves those settings. The local file
is ignored by Git. The specified storage pool and private bridge must already
exist; the provider references them but does not create them. Check that
`authelia_ip` is free on the private bridge. The provider defines the public
Docker Hub image remote in HCL and uses your existing Incus client authentication.

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

## Apply

From the repository root, on the authenticated workstation:

```sh
cp site.auto.tfvars.example site.auto.tfvars
# Edit site.auto.tfvars for this installation before proceeding.
export TF_VAR_authelia_secret_directory="$HOME/.config/homelab/authelia/v1"
tofu init
tofu plan
tofu apply
```

For an existing deployment, keep the values from the example initially and
inspect `tofu plan` before applying. With those values, this refactor should
make no infrastructure changes. Do not apply if the plan proposes to replace
the running instances or volumes; check the site file and the existing state.
On a different installation, use its own state and a site file with its own
values. Do not commit either the local site file or state.

Check both services and the public endpoints:

```sh
INCUS_REMOTE=IncusOS # use the remote in your site file
BASE_DOMAIN=mitschwimmer.de # use the domain in your site file
CADDY_LAN_IP=192.168.1.200 # use your router's DHCP reservation
incus list "$INCUS_REMOTE:"
curl --resolve "$BASE_DOMAIN:443:$CADDY_LAN_IP" "https://$BASE_DOMAIN/health"
curl --resolve "auth.$BASE_DOMAIN:443:$CADDY_LAN_IP" "https://auth.$BASE_DOMAIN/api/health"
curl -I --resolve "$BASE_DOMAIN:443:$CADDY_LAN_IP" "https://$BASE_DOMAIN/private"
```

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
