# Workload patterns

## Non-root OCI application

Prefer an upstream image's non-root UID or set Incus `oci.uid` and `oci.gid` after checking its data permissions and startup behavior. Use a per-service Incus volume with `initial.uid`, `initial.gid`, and `initial.mode=0700`; copy selected fields to its top level as that UID/GID and mode `0400` with `incus storage volume file push -`. Mount it read-only in the instance. This volume can be filled while the instance is stopped, survives instance replacement, and persists across reboot. Use non-secret `*_FILE`/`__FILE` settings or application config pointing at the mounted paths. Keep data volumes separate.

For a workload with no secret files, do not create a placeholder credential merely to make deployment uniform. If files must live in the rootfs, `incus file push -` supports a stdin source and owner/mode; document that replacement may erase the copy. Never push into a future tmpfs mount before startup: that file would be hidden by the mount.

## System container and VM

For a system container, deployment-time files work as above; systemd credentials can also pass root-owned credentials to services with `LoadCredential=`. For a VM, use a secure guest delivery path and account for the VM isolation boundary; direct Incus file operations may require an agent. Do not assume OCI-specific volume commands or ownership mapping transfer unchanged.

## Exceptions

If an application accepts only environment values, a small launcher can read its file and export the value to the process; this exposes it in process environments. Writing an Incus `environment.*` or `systemd.credential.*` key persists it in instance configuration; OpenTofu must not manage that key as an ordinary secret-bearing attribute. For runtime OpenBao Agent, define an explicit workload identity, bootstrap and recovery design, template destination, token renewal, reload handling, and supported supervisor behavior. Use it when the extra isolation or leased secrets warrant it.
