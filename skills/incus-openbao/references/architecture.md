# Architecture

## Default trust boundary

OpenBao stores canonical application values. An operator or CI identity reads selected KV fields and writes them to private Incus volumes through the control API. OpenTofu creates instances, volumes, non-secret field mappings and application file paths. The application reads its own mounted files. Workloads do not need OpenBao clients, tokens, policies, or network access.

Incus and backups of its secret volumes are trusted secret storage. Git, OpenTofu state, plan files, and general workstation storage are not. A remote administrator who can read or modify Incus volumes can read application secrets. Preserve OpenBao unseal shares and Raft backups independently, and keep emergency recovery available without Authelia/OIDC.

A path such as `kv/authelia` and field name `smtp_password` is non-secret configuration; the field value is secret. The declaration can be an OpenTofu output consumed by a small deployment program, but no OpenBao data source should carry application values into normal resource attributes.

## Recovery and rotation

On first install, provision OpenBao and empty private volumes, initialize and populate OpenBao, copy fields, then create/start OCI workloads. If a secret volume is lost, restore it from protected backup or recopy all fields before starting the app. Host reboot needs no OpenBao access for already installed files. On KV rotation, copy the affected workload's complete field set and restart/reload it after successful transfer. Do not assume a KV update propagates automatically. Protect snapshots and backups retaining old versions.

For dynamic/leased credentials, mutually untrusted administrators, or a stronger separation from Incus persistence, explicitly choose a runtime model: individual workload identity, narrow policy, bootstrap outside state, Agent or client, renewal, and startup/outage handling. This is an exception requiring a distinct threat model.

## OpenBao server and host loss

Run a single-node server from a version-pinned official OCI image with an explicit `bao server -config=...` command; upstream image defaults may start dev mode. Mount a private persistent Raft/TLS volume writable by its non-root UID and read-only non-secret HCL config. Provision TLS outside OpenTofu before first start. Retain the TLS key and original unseal shares with restored Raft data; do not initialize or regenerate keys on recovery.

IncusOS system backups exclude installed application data. Preserve system backup/pool encryption keys, Incus application backup, exported volumes and instances, OpenBao Raft snapshots, TLS/unseal material, and OpenTofu state off-host. Restore/import before applying configuration and inspect the plan for volume replacement. A factory reset erases the main drive; drive wiping is a separate destructive operation, never a generic certificate or pool troubleshooting step.
