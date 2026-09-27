# ADR 0002: KeePass secrets in encrypted OpenTofu state

- Status: Accepted
- Date: 2026-09-27

## Context

This is one trusted homelab host with an operator workstation. The previous OpenBao service, Raft storage, TLS key, unseal procedure, and separate deployment script added operational steps for a small set of static secrets. OpenTofu retains provider-managed file contents in plans and state. The operator has chosen to start a new, encrypted state that can contain these values.

## Decision

Use a KeePass KDBX database at `$HOME/.keychains/homelab.kdbx` as the source of stable application secrets and a separate random passphrase for state encryption. A Python script using PyKeePass creates missing secrets, reads operator-provided values, and invokes OpenTofu with sensitive input variables. OpenTofu's PBKDF2 key provider derives an AES-GCM key for local state and plans. The checked-in configuration enforces encryption from the first state write. There is no plaintext state migration or read fallback.

OpenTofu manages private per-workload Incus volumes and mode `0400` files, owned by each service UID/GID and mounted read-only. KeePass and its master password are backed up independently from encrypted state. Neither KDBX nor state is committed. Dependencies come from Nix packages.

## Consequences

- A fresh state has no knowledge of resources that may still exist on measerve. Retire them with the old state or import them before applying the new configuration.
- Decrypted state, plan output, Incus volumes, process memory, and provider execution remain inside the operator's secret boundary. Encryption at rest does not protect these live surfaces.
- Losing either the KDBX database or its master password can make both application secrets and state unrecoverable. Rotating the state passphrase requires an explicit encryption migration, not editing an entry in place.
- Secret rotation is a KeePass edit followed by `tofu apply` and possibly a workload restart. Restore depends on matching state, KDBX, pool keys, and application data.

Implementation: [`versions.tf`](../../versions.tf), [`workloads.tf`](../../workloads.tf), [`scripts/homelab.py`](../../scripts/homelab.py), and [`README.md`](../../README.md).
