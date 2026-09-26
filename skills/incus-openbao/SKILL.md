---
name: incus-openbao
description: Design, implement, review, and migrate OpenBao-backed secret delivery for Incus/IncusOS homelabs managed with OpenTofu. Use when adding or changing services that need credentials, moving existing workstation-side secret files out of OpenTofu, configuring OpenBao Agent for Incus system containers, OCI application containers, or VMs, designing workload authentication/policies, preventing secrets from entering OpenTofu state, rotating secrets, or reviewing homelab changes for secret-handling regressions.
---

# Incus OpenBao

Treat OpenBao as the platform secret and workload-identity layer for Incus workloads. Keep OpenTofu responsible for topology, non-secret configuration, policy references, and lifecycle; keep secret values in OpenBao and deliver them to workloads at runtime.

## Core invariants

Apply these rules unless the user explicitly chooses a different security model:

1. Never put secret values in Git, HCL, `*.tfvars`, Incus instance configuration, `user.*` metadata, cloud-init, or ordinary OpenTofu resource attributes.
2. Do not use OpenTofu as the transport path for workload secrets when the workload can retrieve them at runtime.
3. Let OpenTofu declare **which** OpenBao role, policy, path, and destination a workload uses; let OpenBao own the secret value and its lifecycle.
4. Render workload secrets into `/run/secrets` or another tmpfs-backed runtime directory. Prefer application `*_FILE`/file-secret interfaces over environment variables.
5. Give each workload its own OpenBao identity and least-privilege policy. Never share one broad AppRole across unrelated services.
6. Keep OpenBao itself outside its own dependency graph. Its storage, unseal/recovery path, and emergency administration must not require secrets obtainable only from OpenBao.
7. Treat OpenBao authentication bootstrap material as a secret. Do not solve secret-state leakage by putting an AppRole SecretID into OpenTofu state.
8. If OpenTofu must directly consume a secret, use OpenTofu ephemerality and provider write-only attributes where supported. Otherwise redesign the flow instead of accepting state leakage by default.
9. Keep an operator recovery path that works if Authelia/OIDC or dependent workloads are unavailable.
10. Pin and verify the OpenBao binary/version used by workloads. Do not silently upgrade a shared platform binary beneath running services.

## Default architecture

Use one dedicated OpenBao system container as an Incus platform service with persistent storage and private network reachability. Configure dependent workloads to tolerate OpenBao being temporarily unavailable during boot and retry authentication rather than relying on strict Incus boot ordering.

For each secret-consuming workload:

- create or select a workload-specific OpenBao policy;
- use a workload-specific machine identity;
- run OpenBao Agent in or alongside the workload;
- render only the required secrets to tmpfs;
- configure the application to read those files;
- decide explicitly whether secret rotation requires reload, restart, or no action.

Read [architecture.md](references/architecture.md) when designing authentication, bootstrap, policy, recovery, or platform topology.

## Implementation workflow

When modifying an Incus/OpenTofu repository, follow this sequence.

1. Inspect the existing workload definition, secret inputs, state-sensitive resource attributes, and application secret interfaces before changing anything.
2. Classify every secret as one of:
   - provider/operator authentication used only while running OpenTofu;
   - workload runtime secret;
   - OpenBao bootstrap/recovery material.
3. Prefer runtime retrieval for workload secrets. Remove workstation-side secret-file upload paths only after the OpenBao path is proven.
4. Select the workload pattern from [workload-patterns.md](references/workload-patterns.md): system container, OCI application container, or VM.
5. Define OpenBao policy and identity references as non-secret configuration in OpenTofu.
6. Bootstrap the machine identity through a path that bypasses OpenTofu state. For the initial AppRole design, prefer a short-lived/response-wrapped SecretID delivered after provisioning and consumed once by OpenBao Agent. Verify current OpenBao syntax before implementing.
7. Configure runtime secret rendering and application file-secret references.
8. Add restart/reload behavior for rotation where needed.
9. Run the state and runtime verification in [migration-and-verification.md](references/migration-and-verification.md).
10. Preserve a rollback path until the service has survived reboot, OpenBao outage/recovery, and secret rotation tests.

## OpenTofu boundary

Prefer OpenTofu configuration that contains only references such as:

~~~hcl
openbao = {
  role = "authelia"
  secrets = {
    smtp_password = {
      path        = "kv/data/authelia"
      field       = "smtp_password"
      destination = "/run/secrets/authelia-smtp-password"
    }
  }
}
~~~

This is conceptual structure, not a required module API. Adapt it to the repository rather than forcing an abstraction prematurely.

If OpenTofu itself needs a credential to configure a provider, prefer an ephemeral root variable and provider configuration. If OpenTofu must write a secret to a target resource, require a provider-supported write-only attribute. Do not feed ephemeral values into ordinary persistent resource attributes.

Do not introduce a Vault/OpenBao data source merely because it is available. Fetching the secret inside OpenTofu is inferior to runtime retrieval when the target workload can authenticate to OpenBao itself.

## Incus integration

Use Incus for non-secret plumbing:

- workload placement and lifecycle;
- private networking to OpenBao;
- tmpfs runtime secret mounts for containers;
- read-only distribution of a pinned OpenBao binary to containers where useful;
- non-secret workload metadata such as role names or secret-path references;
- boot priority as a convenience, never as the only resilience mechanism.

Do not store secret values in Incus configuration, custom metadata, profiles, cloud-init, or persistent shared volumes.

`/dev/incus/sock` is useful for non-secret instance metadata but is not, by itself, a cryptographically verifiable OpenBao workload identity. Do not pretend it replaces an authentication method. A future Incus identity broker/JWT issuer can be considered only as a deliberate security component with its own threat model and review.

## Workload authentication

Start with one AppRole per workload unless a better native identity source already exists. Scope policies to the minimum paths and capabilities needed.

Keep these concepts separate:

- `role_id`: identifier/configuration material;
- `secret_id` or equivalent bootstrap credential: secret material;
- OpenBao token: short-lived runtime credential maintained by Agent;
- application secret: the credential rendered for the target application.

Do not reuse application secrets as OpenBao authentication credentials.

For humans, OIDC through the homelab identity provider is appropriate for routine access, but retain an emergency/recovery path independent of that OIDC provider.

## Service addition rule

Whenever adding a new service, ask these questions before implementing it:

1. Which credentials does it consume?
2. Which credentials can become dynamic/short-lived instead of static?
3. Can it read secrets from files?
4. Which OpenBao paths should its identity read?
5. What happens when OpenBao is unavailable at startup?
6. What happens when a secret rotates while the service is running?
7. Does any secret value cross OpenTofu, Incus metadata, logs, command lines, or persistent disk?

If any answer implies unnecessary secret exposure, redesign before proceeding.

## Repository migration

For repositories that currently upload local secret files into Incus volumes, migrate incrementally. Do not delete the existing mechanism and OpenBao-enable all workloads in one change.

Use the migration sequence in [migration-and-verification.md](references/migration-and-verification.md), preferably starting with a low-risk secret such as an SMTP credential. Keep state compatibility and data volumes intact while changing only the secret-delivery path.

## Version-specific implementation

OpenBao, OpenTofu, Incus, and provider capabilities evolve. Before emitting exact HCL, Agent configuration, AppRole flags, process-supervisor behavior, or Incus device syntax:

- inspect the repository's pinned versions;
- check current upstream documentation when syntax or feature status matters;
- do not assume Vault and OpenBao provider compatibility for newer features;
- treat OpenBao Agent Process Supervisor as opt-in if its current upstream status is still beta/experimental.

## References

- [architecture.md](references/architecture.md): platform topology, trust boundaries, bootstrap, recovery, and policy model.
- [workload-patterns.md](references/workload-patterns.md): system container, OCI container, and VM delivery patterns.
- [migration-and-verification.md](references/migration-and-verification.md): incremental migration, state-leak checks, reboot/outage/rotation tests, and review checklist.
