# Host and secret recovery

An IncusOS system backup does not contain all application data. Back up each layer and test restoration before relying on it. Treat remote certificate mismatches as client/host configuration problems first; inspect the remote and pools before changing disks.

| Layer | Off-host recovery material |
| --- | --- |
| IncusOS | `incus admin os system backup` and storage-pool encryption/recovery keys. |
| Incus application | `incus admin os application backup incus`, plus exports of persistent volumes and any instance rootfs data. |
| Operator secrets | KeePass `.kdbx` database and its master password, backed up independently. It contains the state passphrase and application values. |
| Deployment | The matching encrypted OpenTofu state, `site.auto.tfvars`, and any saved encrypted plans. Protect any old plaintext state copies. |
| Workloads | Application data and custom volumes. Secret volumes also contain plaintext application values; they can be recreated from KeePass by applying the configuration to an empty host. |

For example, save archives outside the checkout with the authenticated remote, transfer them off-host, and verify they can be read:

```sh
incus admin os system backup measerve: /private/incusos-system.tar.gz
incus admin os application backup measerve:incus /private/incus-app.tar.gz -d '{"complete":false}'
incus storage volume export measerve:local authelia-data /private/authelia-data.tar.gz
```

Export other data and secret volumes listed by `incus storage volume list measerve:local`. Verify the contents of the Incus application archive instead of assuming it includes volume data. The IncusOS system backup and pool keys, KeePass database, state, and application volumes are all sensitive.

After a reinstall, restore host and Incus configuration and import the original pool with its encryption keys. Restore the KeePass database and the matching OpenTofu state before running the wrapper. If state was lost but resources survived, import them rather than applying empty state over existing resources. Review the plan for no replacement or deletion of recovered volumes. Restore application data; run `tofu apply` through the wrapper to reconcile configuration and secret files. Then verify mounts, services, certificates, and a reboot.

See the [IncusOS system backup](https://linuxcontainers.org/incus-os/docs/main/reference/system/backup/), [application backup](https://linuxcontainers.org/incus-os/docs/main/reference/applications/shared-api/), [Incus volume export/import](https://linuxcontainers.org/incus/docs/main/howto/storage_backup_volume/), and [OpenTofu state encryption](https://opentofu.org/docs/language/state/encryption/).
