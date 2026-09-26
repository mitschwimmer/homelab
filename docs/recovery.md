# Host and OpenBao recovery

The last IncusOS reinstall showed how expensive a reset becomes when host setup, storage, certificates, and application state must all be recreated. Treat a certificate mismatch or a broken client remote as a **client/host configuration problem first**. Inspect the remote address and certificates, pool, bridge, and IncusOS application status before changing disks. Do not run factory reset or `storage wipe-drive` as troubleshooting steps.

## Back up before a change

| Layer | Off-host recovery material |
| --- | --- |
| IncusOS | `incus admin os system backup` and storage-pool encryption/recovery keys. The system backup excludes installed application data. |
| Incus application | `incus admin os application backup incus` plus exported instances and custom volumes. Confirm what the application archive contains before relying on it for volume data. |
| OpenBao | `bao operator raft snapshot save`, exported `openbao-data` (Raft, audit, TLS key/cert), and two or more unseal shares stored separately. |
| Workloads | Exported application data and private secret volumes; or repopulate secret volumes from restored OpenBao before starting applications. |
| Deployment | OpenTofu state and site variables stored privately and matched to the actual Incus installation. |

For example, use the current authenticated remote and pool, save archives outside this checkout, transfer them off-host, and verify that they can be read:

```sh
incus admin os system backup measerve: /private/incusos-system.tar.gz
incus admin os application backup measerve:incus /private/incus-app.tar.gz -d '{"complete":false}'
incus storage volume export measerve:local openbao-data /private/openbao-data.tar.gz
incus storage volume export measerve:local authelia-data /private/authelia-data.tar.gz
bao operator raft snapshot save /private/openbao.snap
```

Export all other data and secret volumes listed by `incus storage volume list measerve:local`, plus instances where their rootfs contains needed state. Test a restore on an isolated server or pool. IncusOS's system backup is sensitive because it includes pool keys; Raft snapshots and secret volumes are sensitive too. Preserve the TLS private key/certificate pair with the Raft data so clients retain their trust anchor.

## Recover after reinstall or host loss

1. Restore IncusOS system configuration and the Incus application from their respective backups where possible. If reinstalling, preserve user-created pools and **their encryption keys**; do not wipe drives to make pool creation easier. Verify pool import, bridge subnet, remote TLS trust, and address allocations before OpenTofu.
2. Restore `openbao-data` from its volume export (and its TLS key/cert), or use the separately tested Raft-snapshot restore procedure if the data volume cannot be recovered. These are distinct recovery paths; do not initialize over restored Raft data. Start the OCI OpenBao instance with the existing volume and unseal using the original shares.
3. Restore OpenTofu state for that installation, or import surviving resources into a new state before applying. Review `tofu plan` for **no replacement or deletion of recovered volumes**. A fresh-state apply is for an empty host only.
4. Restore application data and secret volumes. If a secret volume was lost, create it, restore a protected export or run `scripts/deploy-secrets.py` against restored OpenBao, and only then start that workload. Run a full plan/apply and check services and certificates.

See the [IncusOS system backup](https://linuxcontainers.org/incus-os/docs/main/reference/system/backup/), [application backup](https://linuxcontainers.org/incus-os/docs/main/reference/applications/shared-api/), [Incus volume export/import](https://linuxcontainers.org/incus/docs/main/howto/storage_backup_volume/), and [OpenBao Raft snapshots](https://openbao.org/docs/commands/operator/raft/). A restore into a newly initialized OpenBao cluster may require a forced snapshot restore and different unseal keys; follow the OpenBao procedure for that path rather than improvising on the only copy.

## Moving an existing OpenBao system container to OCI

Back up `openbao-data` and OpenTofu state and confirm the TLS files at `tls/server.crt` and `tls/server.key`. Stop the old instance, review the plan: the `openbao` instance should be replaced, while `openbao-data` and `openbao-config` remain. Do **not** run the TLS bootstrap script or `bao operator init`. Apply, check the OCI process and logs, unseal, and verify KV reads before deploying workloads. If it fails, preserve the data volume and return to the previous instance definition; never rebuild the Raft volume just to fix an image/entrypoint problem.
