# ADR 0002: KeePass secrets in encrypted OpenTofu state

- Status: Accepted
- Date: 2026-09-27

## Context

This is one trusted homelab host with an operator workstation. The previous OpenBao service, Raft storage, TLS key, unseal procedure, deployment token, and separate delivery script added operational steps for a small set of static secrets. OpenTofu must retain provider-managed file contents in plans and state. The operator has chosen to trust encrypted local state with these values.

## Decision

Use a local KeePass KDBX database as the source of stable application secrets and a separate random passphrase for state encryption. A Python script using PyKeePass creates missing secrets, reads operator-provided values, and invokes OpenTofu with sensitive input variables. The passphrase is derived by OpenTofu's PBKDF2 key provider for AES-GCM encryption of local state and plans. The checked-in configuration enforces encryption and has no plaintext read fallback. A dedicated one-time migration command reads the pre-existing plaintext state from a private staged configuration and creates one state-only marker to force an encrypted state write.

OpenTofu manages private per-workload Incus volumes and mode `0400` files, owned by each service UID/GID and mounted read-only. KeePass and its master password are backed up independently from the encrypted state. Neither KDBX nor state is committed.

## Consequences

- The decrypted state, plan output, Incus volumes, process memory, and provider execution remain inside the operator's secret boundary. File encryption at rest does not protect these live surfaces.
- Losing either the KDBX database or its master password can make both application secrets and state unrecoverable. Rotating the state passphrase requires an explicit encryption migration, not editing an entry in place.
- Existing plaintext state and backups remain sensitive even after migration; remove or protect them separately. The one-time migration must finish before application secrets enter state.
- Secret rotation is a KeePass edit followed by `tofu apply` and possibly a workload restart. Restore depends on matching state, KDBX, pool keys, and application data.

Implementation: [`versions.tf`](../../versions.tf), [`workloads.tf`](../../workloads.tf), [`scripts/homelab.py`](../../scripts/homelab.py), and [`README.md`](../../README.md).
