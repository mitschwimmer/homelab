# Homelab

OpenTofu definitions for the IncusOS homelab. The first managed service is Caddy;
Authelia will join it on the private Incus bridge after ingress is checked.

## First deployment

On a workstation with OpenTofu and an authenticated Incus client remote named
`IncusOS`, run:

```sh
tofu init
tofu plan
tofu apply
```

The Incus provider reuses the workstation's existing client certificate and
trusted remote. It defines the public Docker Hub image remote in HCL. The
existing `local` storage pool and `incusbr0` bridge are referenced, not recreated.

Caddy has two NICs: a macvlan on host interface `enp129s0` with MAC
`02:00:00:ca:dd:01`, and an internal NIC on `incusbr0`. The router's existing
DHCP reservation gives the macvlan NIC `192.168.1.200`; OpenTofu does not set a
static IP inside the container. Keep the existing public DNS and port forwards
pointing to that reserved address.

Check the first deployment with:

```sh
incus list IncusOS:caddy
curl --resolve mitschwimmer.de:443:192.168.1.200 https://mitschwimmer.de/health
```

The Caddyfile currently serves only a health response. Add upstream routes
after confirming ingress, then deploy Authelia on `incusbr0` and add
`forward_auth` to protected routes.

## Sensitive data

Do not commit passwords, encryption keys, private keys, user databases, or
OpenTofu plans and state. State is local to the operator's workstation and must
be backed up privately; `.gitignore` only prevents accidental staging. Caddy's
ACME data stays in the persistent `caddy-data` Incus volume, not in Git or
OpenTofu state. Future Authelia secrets should be provisioned outside the
OpenTofu resource graph, so they do not become part of state or a public diff.

`tofu apply` changes the Incus server and requires an authenticated remote.
Committing this repository does not deploy anything.
