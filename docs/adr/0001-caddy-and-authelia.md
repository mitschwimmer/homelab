# ADR 0001: Caddy and Authelia for public access

- Status: Accepted
- Date: 2026-09-26

## Context

This homelab runs services on a single IncusOS host. Some services need a
public HTTPS address, while access to private applications must
require a login and a second factor. The router forwards HTTP and HTTPS to
one LAN address; the applications and identity service live on an internal
Incus bridge. The infrastructure is described with OpenTofu and should remain
small enough to understand and operate at home.

We previously considered Traefik for a setup in which NetBird would be the
service publishing platform. The current deployment uses direct router port
forwards and public DNS instead. It does not require a NetBird-specific proxy
integration. Caddy is a better fit for this narrower setup: its Caddyfile
expresses the few routes directly and it manages public TLS certificates.

A reverse proxy alone does not provide the shared login, second-factor
policy, and identity claims wanted for protected services. Each application
should not need a separate public authentication setup.

## Decision

Use **Caddy** as the sole public HTTP entry point and TLS terminator. Run it
as an Incus OCI instance with a macvlan NIC on the LAN and another NIC on the
private Incus bridge. Reserve its LAN address by MAC in the router, forward
ports 80 and 443 to it, and point public DNS at the router's public address.
Keep Caddy's certificate data in a persistent Incus volume.

Use **Authelia** as the identity and authorization service on the private
bridge. Publish the Authelia portal through Caddy at `auth.<base_domain>` so
users can complete login and enrollment. Use its
file-backed users and persistent SQLite storage for this small deployment.

For applications that need a user identity within the application, also use
Authelia as an OpenID Connect provider. Grafana uses Authelia OIDC to sign
users in. Its client authorization policy requires the `admins` group and a
second factor. Grafana accepts only that group and maps it to the server
administrator role. Caddy handles TLS and routing without a second login gate. Only
`auth.<base_domain>` and `grafana.<base_domain>` have public Caddy routes;
the apex domain has none. Prometheus and exporter endpoints stay on the
private network.

Authelia requires a nonempty proxy `access_control` rule set when the default
policy is `deny`, even though Caddy does not call its forward-auth endpoint.
Keep a rule scoped to Grafana so the service can start; the separate OIDC
authorization policy governs Grafana sign-in.

Keep user data, keys, and passwords outside Git. The deployment supplies
private files to read-only workload mounts as described in
[ADR 0002](0002-keepass-and-encrypted-state.md). This ADR records the proxy and
identity choice independently of the secret delivery mechanism.

## Consequences

- Caddy owns public routing and certificate renewal; Authelia owns login,
  second-factor checks, and OIDC authorization policies. An OIDC application
  needs an Authelia client and application-side access and role mapping.
- The router reservation, port forwards, public DNS, and any split DNS needed
  to reach the public Authelia URL from private applications remain outside
  OpenTofu. The Caddy macvlan NIC cannot be reached directly from the IncusOS
  host; the private bridge is the internal route to Caddy and its upstreams.
- Grafana depends on Authelia for login. If Authelia is unavailable, new Grafana
  sessions cannot authenticate.
- The file user store suits a small set of accounts but requires private,
  operator-managed changes and backups. SMTP must be configured separately
  for enrollment and reset messages to reach an inbox.
- The decision can be revisited if NetBird becomes the publishing platform or
  the number of services makes a different proxy integration worthwhile.

## Alternatives considered

- **Traefik with NetBird integration:** attractive when NetBird publishes
  services, but adds a dependency on that integration for a requirement the
  present deployment does not have.
- **Caddy authentication alone or per-application accounts:** sufficient for
  simple gates, but does not give this deployment one shared second-factor
  policy and OIDC identity for applications such as Grafana.

## Implementation references

- [`caddy.tf`](../../caddy.tf) and [`caddy/Caddyfile`](../../caddy/Caddyfile)
- [`authelia.tf`](../../authelia.tf) and
  [`authelia/configuration.yml.tftpl`](../../authelia/configuration.yml.tftpl)
- [`grafana.tf`](../../grafana.tf) for the first OIDC consumer
