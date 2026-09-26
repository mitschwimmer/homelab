# ADR 0002: Deployment files and an OCI OpenBao server

- Status: Accepted
- Date: 2026-09-26

## Context

Per-workload OpenBao Agents needed AppRole bootstrap credentials, policies, startup wrappers, and renewal handling. This single trusted IncusOS host already has an operator who administers OpenBao and Incus. OpenTofu provider attributes retain secret values in plans/state, so HCL must never fetch application secrets into ordinary resources. A recent host wipe and reinstall also exposed the cost of losing IncusOS/Incus state, pool keys, certificates, and volumes.

The former OpenBao system container installed a workstation-provided binary through cloud-init and generated TLS on first boot. That was a convenience of the original implementation, not a requirement of OpenBao.

## Decision

Use OpenBao KV v2 as the source. OpenTofu declares only field names, private Incus volumes, paths, UID/GID, and modes. An operator-authenticated command streams fields directly into per-workload persistent volumes. Non-root OCI apps read mounted files (`0400`, directory `0700`, guest mount read-only); they do not authenticate to OpenBao.

Run OpenBao from the version-pinned official OCI image with an explicit production server command, UID/GID 900, separate read-only HCL configuration, and a persistent Raft volume. Provision its TLS key/certificate into that volume outside OpenTofu before first start. Its unseal and recovery remain independent of Authelia. Incus and its backups are inside the secret boundary; Git and OpenTofu state are outside it.

## Consequences

- First boot is staged: volumes, TLS, OpenBao initialization/KV, workload secret files, then the remaining OCI instances. A restored OpenBao volume must reuse its original TLS and unseal material; never initialize it again.
- Image replacement can reuse Raft/TLS data. A host reinstall still requires independent IncusOS, Incus application, pool-key, OpenBao, and workload backups; see [recovery](../recovery.md). A system backup alone is insufficient.
- Rotation requires redeploying all fields for the service and then restarting/reloading it. A failed copy may leave mixed files; recopy before restart. Snapshots may retain older values.
- Dynamic leased credentials or separate trust domains may justify per-workload Agents later, with explicit identity and renewal design. Incus environment/system credentials or direct OpenTofu secret reads do not meet this design's state and non-root requirements.

Implementation: [`openbao.tf`](../../openbao.tf), [`workloads.tf`](../../workloads.tf), [`scripts/deploy-secrets.py`](../../scripts/deploy-secrets.py), [`README.md`](../../README.md).
