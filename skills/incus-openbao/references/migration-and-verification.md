# Migration and verification

## Migration

1. Inventory every source, field, destination, consumer UID, existing volume, snapshot, and state attribute. Preserve application data volumes.
2. Add non-secret mappings and private destinations in OpenTofu. Ensure file paths match the application's native file-secret settings.
3. Create OpenBao and empty volumes first. Populate OpenBao outside OpenTofu; copy files through Incus without writing plaintext to workstation disk or command arguments.
4. Check complete ownership/mode and application readability, then start or restart workloads. Migrate one service at a time for a live installation.
5. Remove obsolete Agent/AppRole files, auth volumes, policies, and bootstrap credentials deliberately. Revoke old SecretIDs and account for snapshots containing them.
6. Run a normal OpenTofu plan after any targeted bootstrap apply; test host reboot, lost volume restoration, failed transfer, and rotation.

## Verification

Use a non-production canary field to inspect saved plan, raw state, `tofu show -json`, HCL/tfvars, Incus instance config, and provisioning logs. The plaintext must not appear there; it should appear in its explicitly trusted private volume. Check the process UID is non-root, each volume directory is `0700`, files are owned by that UID with mode `0400`, and the guest mount is read-only. Check the application can read its fields and unrelated workloads cannot. Back up the volume and verify access restrictions and retention, including old values after rotation.

The deployment command must stop on a missing/empty KV field and on push errors without printing bytes or restarting the app. A partial copy may leave mixed values; recopy all fields before restarting. Test replacement with a preserved volume and recovery of a missing volume from OpenBao. Keep OpenBao unseal and emergency access independent of Authelia.
