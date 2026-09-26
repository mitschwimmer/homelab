# Migration and verification

## Contents

1. Incremental migration
2. Example: Authelia SMTP password
3. State-leak verification
4. Runtime verification
5. Failure-mode tests
6. Pull-request review checklist

## Incremental migration

Migrate one secret path at a time.

1. Identify the current source, transport, persistence point, and consumer.
2. Create the OpenBao path/value and narrow workload policy.
3. Provision non-secret Agent configuration and runtime tmpfs.
4. Bootstrap workload authentication outside OpenTofu state.
5. Render the secret under `/run/secrets` and configure the application to consume it.
6. Apply and test without deleting the old mechanism if both can safely coexist.
7. Remove the old workstation-side secret upload/input.
8. Inspect plan/state and Incus configuration for residual secret material.
9. Test reboot, outage recovery, and rotation.
10. Remove obsolete local secret directories/documentation only after successful migration.

Avoid broad refactors during a secret migration. Preserve persistent data volumes and stable service addressing unless the migration genuinely requires changing them.

## Example: Authelia SMTP password

Target architecture:

~~~text
OpenBao kv/data/authelia.smtp_password
              |
              v
Authelia workload identity + Agent
              |
              v
/run/secrets/authelia-smtp-password
              |
              v
AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE
~~~

OpenTofu should contain the OpenBao path, destination path, role/policy reference, and application file setting, but not the SMTP password.

This is a good first migration because losing SMTP affects notifications but does not need to redefine the entire authentication architecture. Verify the service's actual failure mode before relying on that assumption in a specific deployment.

## State-leak verification

Do not rely only on `sensitive = true`.

Before applying a migration, create or identify a safe test/canary secret value that is unique enough to search for. After plan/apply, verify that the plaintext does not occur in:

- saved plan files;
- `tofu show -json` output for state;
- raw state files/backups;
- generated HCL/tfvars;
- Incus instance/profile configuration;
- cloud-init data;
- application unit files;
- logs produced during provisioning.

Use the repository's actual backend/state workflow. Do not print real production secrets simply to test absence.

If a secret appears in state, stop and redesign unless the user explicitly accepts state as a secret store.

## Runtime verification

Verify on the workload:

- `/run/secrets` is tmpfs/ephemeral as intended;
- secret file owner/group/mode are minimal;
- only expected secret files exist;
- OpenBao Agent can authenticate with the workload-specific identity;
- the resulting policy cannot read another workload's secret path;
- the application reads the file successfully;
- neither Agent nor application logs print the secret;
- bootstrap material is removed/expired after use where designed.

Test least privilege explicitly by attempting one allowed read and one denied read using a diagnostic token/identity path that does not expose production values unnecessarily.

## Failure-mode tests

A platform secret system is not proven by a successful happy-path apply. Test:

1. **Reboot**: reboot/restart the workload and verify it reacquires secrets without operator copying.
2. **OpenBao late startup**: start the workload while OpenBao is unavailable, then restore OpenBao and verify automatic recovery.
3. **Rotation**: rotate one test secret and verify the documented reload/restart behavior.
4. **Agent failure**: terminate Agent and confirm the intended application behavior.
5. **Identity revocation**: revoke/disable the workload identity and verify future secret acquisition fails.
6. **Replacement**: replace the Incus instance and verify bootstrap/re-enrollment is deliberate and does not resurrect stale credentials accidentally.
7. **Recovery**: verify operators can recover OpenBao if OIDC/Authelia is unavailable.

## Pull-request review checklist

Reject or flag changes that:

- add plaintext secret values to HCL, examples, tests, README snippets, or generated files;
- add secret-bearing `TF_VAR_*` values as a persistent local convention for workload delivery;
- put AppRole SecretIDs/client private keys in OpenTofu resources or Incus metadata;
- render secrets onto persistent/shared storage without an explicit reason;
- use one machine identity for multiple unrelated workloads;
- grant broad `kv/*` read access instead of workload paths;
- make OpenBao startup depend on OpenBao-hosted secrets;
- make human recovery depend solely on the normal OIDC provider;
- use an ordinary provider attribute for an ephemeral OpenTofu secret when a write-only path is required;
- assume an OCI supervisor/process-supervisor feature is stable without checking its current status;
- change binary versions without checksum verification and a rollback path.

Prefer PRs that include operational tests and migration/rollback notes alongside HCL changes.
