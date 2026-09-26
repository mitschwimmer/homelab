# Architecture

## Contents

1. Platform topology
2. Trust boundaries
3. Workload identity
4. Bootstrap
5. Human access and recovery
6. OpenBao server boundary
7. Rotation and dynamic secrets

## Platform topology

Use OpenBao as an Incus platform service, not as an application-specific helper and not as an IncusOS host modification.

~~~text
IncusOS / Incus
|
+-- openbao          system container + persistent storage
|
+-- workload A
|   +-- OpenBao Agent
|   +-- /run/secrets (tmpfs)
|
+-- workload B
|   +-- OpenBao Agent
|   +-- /run/secrets (tmpfs)
|
+-- workload C
    +-- OpenBao Agent
    +-- /run/secrets (tmpfs)
~~~

OpenTofu declares containers/VMs, networking, persistent volumes, non-secret Agent configuration, OpenBao policy/role references, and application references to secret files. OpenBao stores and serves the actual secret values.

## Trust boundaries

Keep four distinct classes of data:

1. **Public/non-secret configuration**: OpenBao address, role names, secret paths, destination paths, policy names, application usernames where non-sensitive.
2. **Machine bootstrap credentials**: AppRole SecretID, client private keys, or equivalent. Never persist these through OpenTofu state.
3. **Runtime OpenBao credentials**: short-lived tokens managed by Agent. Do not hand these to the application unless the application itself is the OpenBao client.
4. **Application secrets**: SMTP passwords, API tokens, database credentials, encryption keys. Render only what the workload needs.

A path such as `kv/data/authelia` is configuration, not a secret. The value stored under it is secret.

## Workload identity

Default to one machine identity per workload. Bind each identity to a narrow policy, for example:

~~~text
authelia identity
  -> read kv/data/authelia/*

grafana identity
  -> read kv/data/grafana/*
~~~

Do not grant workloads access based only on a shared network location or a common Incus profile.

Start with AppRole where no stronger native identity source exists. Consider certificate/JWT-based identity later when there is a trustworthy issuer and operational benefit.

`/dev/incus/sock` authenticates an instance to Incus for the guest API, but it does not issue a signed assertion that OpenBao can directly verify. Use it for non-secret metadata/discovery, not as an invented auth protocol.

## Bootstrap

The first machine credential is the difficult part. Do not move this problem into OpenTofu state.

For the initial AppRole implementation, prefer this flow:

~~~text
OpenTofu creates workload + non-secret config
              |
              v
operator/CI authenticates directly to OpenBao
              |
              v
generate short-lived or response-wrapped SecretID
              |
              v
deliver directly to workload runtime path
              |
              v
OpenBao Agent consumes it once and authenticates
              |
              v
Agent maintains renewable/short-lived token
~~~

Delivery can be an explicit post-provision operator/CI step such as an Incus file push into a protected runtime path. The exact command is implementation-specific. The important property is that the secret bytes never become an OpenTofu input, resource attribute, output, plan, or state value.

Prefer single-use/short-lived bootstrap material and configure Agent to remove a bootstrap file after consumption when the current OpenBao method supports it.

Do not put bootstrap secrets in Incus `user.*` metadata, cloud-init, profiles, or persistent config volumes.

## Human access and recovery

Use OIDC for normal human OpenBao login when available, for example through Authelia. Keep recovery independent from OIDC because the identity provider itself may consume OpenBao secrets.

Maintain and document:

- OpenBao unseal/recovery procedure;
- emergency administrative access;
- backup restoration procedure;
- location and custody of recovery material.

Avoid this circular dependency:

~~~text
OpenBao requires Authelia login
Authelia cannot start without OpenBao
no recovery path exists
~~~

Routine OIDC can depend on Authelia; emergency access must not.

## OpenBao server boundary

Run OpenBao in a dedicated system container with:

- private network reachability from managed workloads;
- persistent storage dedicated to OpenBao;
- an audit log destination whose persistence and access are deliberate;
- backups/snapshots appropriate to the configured storage backend;
- no dependency on secrets stored only in OpenBao for initial startup/unseal.

Do not expose OpenBao publicly merely to make workload access easy. Prefer internal reachability plus controlled human access.

If using a single-node storage backend for a homelab, make the single-node failure mode explicit and keep verified backups. Do not describe the setup as highly available.

## Rotation and dynamic secrets

For every secret define one of these behaviors:

- application rereads the file automatically;
- send a reload signal/API call;
- restart the application;
- restart/recreate the workload;
- no automatic rotation supported.

Prefer dynamic/leased credentials when the target system and OpenBao engine make them practical. Dynamic credentials reduce the value of long-lived static secrets but do not remove the need for workload identity and auditability.
