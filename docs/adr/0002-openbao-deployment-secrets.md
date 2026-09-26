# ADR 0002: OpenBao as the deployment secret store

- Status: Accepted
- Date: 2026-09-26

## Context

The first OpenBao integration ran an Agent and separate AppRole identity in
each OCI workload. It needed persistent bootstrap credentials, a custom PID 1,
startup retries, tmpfs rendering, workload policies, and agent lifecycle
management. The homelab runs on one trusted IncusOS host. Its operator already
controls both OpenBao and Incus. The application images should run under
non-root UIDs, including Authelia, and read only their own secret files.

OpenTofu's ordinary Incus resource attributes persist values in state, so
fetching secrets from OpenBao in HCL and passing them to `environment.*` or
`systemd.credential.*` would expose those values in state. Incus system
credentials are root-owned for container consumers, making direct access by
non-root OCI processes awkward. A tmpfs plus post-start file injection would
need a launcher to keep applications from starting before injection.

## Decision

Use OpenBao KV v2 as the authoritative store for application secrets.
OpenTofu declares each workload's field names, owner UID/GID, Incus volume,
and file paths, never secret values. After provisioning private persistent
volumes, an operator-authenticated deployment command retrieves fields from
OpenBao and streams them through the Incus API into each volume. Its files
have mode `0400`; the volume directory has mode `0700` and belongs to the
non-root application UID. Mount each volume read-only in its OCI instance
under `/var/lib/homelab-secrets`. Applications consume native file settings,
or non-secret configuration pointing at files.

OpenBao remains a separate system container and cannot depend on itself or
Authelia for unseal and emergency recovery. Workloads have no OpenBao token,
Agent, AppRole, or direct connectivity requirement. Incus and its backups are
inside the application secret trust boundary. Git, OpenTofu plans, and state
remain outside that boundary.

## Consequences

- The first bootstrap has two stages: provision OpenBao and empty private
  volumes; initialize and populate OpenBao, install the files; then apply the
  complete workload configuration. Files exist before OCI entrypoints start.
- Secret volumes persist across instance replacement and host reboots.
  Incus snapshots and volume backups can retain previous values after
  rotation; they require restricted access, retention, and off-host backup.
- Rotation is explicit: update OpenBao, redeploy affected files, then restart
  or reload the application. Reconciliation does not automatically refresh
  files when KV values change. The deployment operation must be repeated
  when replacing a lost secret volume.
- A partially failed copy can leave a service with mixed or truncated files.
  Stop, re-run deployment, check the files and application, and only then
  restart. Keep the existing service running during a routine rotation until
  the full copy succeeds. Do not run concurrent deployments to one volume.
- File ownership must match the actual OCI process UID/GID. New services
  should use native file settings where available, with an explicit exception
  for an application that can consume secrets only through the environment.

## Alternatives considered

- **Per-workload OpenBao Agent and AppRole:** isolates secrets from Incus
  persistence but adds identity bootstrap and lifecycle plumbing to each
  application. Reserve it for workloads that need dynamic credentials or an
  independent trust boundary.
- **Incus system credentials or environment values:** both persist in Incus
  instance configuration; the former are inaccessible to ordinary non-root
  OCI entrypoints without another privilege handoff, while the latter enter
  process environments.
- **tmpfs plus file injection:** avoids persistent copies but requires a
  start gate or wrapper and reinjection after every restart.
- **OpenTofu reads OpenBao values directly:** ordinary provider attributes
  retain those values in plan/state.

## Implementation references

- [`workloads.tf`](../../workloads.tf): declarations and non-secret output
- [`scripts/deploy-secrets.py`](../../scripts/deploy-secrets.py): transfer
- [`README.md`](../../README.md): first boot, rotation, and verification
