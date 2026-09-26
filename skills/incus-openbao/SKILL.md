---
name: incus-openbao
description: Design, implement, review, and migrate OpenBao-backed secret delivery for Incus/IncusOS homelabs managed with OpenTofu. Use for deployment-time secret files in non-root OCI workloads, OpenBao setup and recovery, state-leak prevention, rotation, or optional workload runtime authentication.
---

# Incus OpenBao

Use OpenBao as the authoritative secret store for a trusted Incus host. Default to an operator-authenticated deployment step that copies application secrets into per-workload private files. Workloads consume files and do not authenticate to OpenBao. Consider per-workload Agent and identity only when the threat model or dynamic credentials justify the extra lifecycle machinery.

## Core invariants

1. Keep secret values out of Git, HCL, tfvars, ordinary OpenTofu attributes, outputs, plans, and state. `sensitive` alone does not prevent state storage.
2. Let OpenTofu declare only secret source references, file destinations, UID/GID, mode, and non-secret application file settings. Read secret values outside OpenTofu.
3. Prefer non-root OCI entrypoints and native `*_FILE` interfaces. Give each workload a separate persistent Incus volume or private rootfs directory with restrictive ownership. Make a volume read-only in the guest when it needs no writes there.
4. Treat Incus control-plane access, persistent secret files, volume snapshots, and backups as inside the trusted secret boundary. Document retention and rotation of older copies.
5. Stream values through process memory and the Incus API/CLI, not command arguments, logs, temporary workstation files, or environment variables. Validate destination names and file ownership.
6. Stage first boot so files exist before the OCI entrypoint starts. On rotation, deploy all required fields, check success, then restart/reload explicitly. Do not assume OpenBao changes automatically update installed files.
7. Keep OpenBao storage, unseal/recovery, and emergency administration independent of OpenBao-hosted secrets and routine Authelia/OIDC access.
8. Authenticate the deployment operator/CI to OpenBao with a scoped credential that is not committed or fed through OpenTofu state. Restrict Incus administration separately.
9. Inspect provider and application versions before relying on exact syntax or file-secret support. Use current upstream docs for version-sensitive details.
10. For a single-node OpenBao server on IncusOS, prefer a pinned official OCI image with an explicit production command, persistent Raft/TLS volume, and TLS provisioned outside OpenTofu state. Never run the image's default dev command or regenerate TLS over a restored volume.
11. Treat host recovery as a separate design requirement: back up IncusOS system configuration and pool keys, Incus application state, custom volumes, OpenBao Raft/TLS/unseal material, and OpenTofu state independently. Diagnose client TLS/pool problems before any reset or drive wipe.

## Repository workflow

1. Read the existing workload UID/GID, native file settings, persistence layout, and secret source. Check for old state/volumes before removing resources.
2. Define a non-secret manifest in OpenTofu mapping each service and KV field to its destination volume/path, owner, and mode. Keep values out of the provider graph.
3. Create a private persistent volume per service when stopped-instance injection and replacement survival are useful. Set directory owner and mode `0700`; push files as application owner with mode `0400`; mount read-only in the OCI container. For a secret that belongs in a rootfs instead, document replacement behavior.
4. Implement a small deployment command that fetches OpenBao fields and writes through Incus stdin. Ensure failures do not print values, and do not restart a service after a failed transfer.
5. Bootstrap OpenBao and empty secret volumes first, populate KV, transfer files, then create/start applications. Verify application UID, file readability, backup boundary, restart and rotation.
6. Review state, plans, instance configuration, logs, and command lines with a canary value; the value should appear only in OpenBao, explicitly trusted Incus storage, and application memory.

Read [architecture.md](references/architecture.md) for trust and recovery, [workload-patterns.md](references/workload-patterns.md) for system/OCI/VM choices, and [migration-and-verification.md](references/migration-and-verification.md) for migration and tests.

## Exceptions

When an application has no file interface, choose a documented launcher or Incus environment setting with an explicit persistence and exposure assessment. If runtime authentication is required, design separate workload identity, least-privilege policy, secure bootstrap, Agent lifecycle, and outage behavior; do not silently generalize the deployment-file default into a runtime Agent architecture. OpenBao dynamic credentials with short leases typically need runtime renewal rather than static deployment.
