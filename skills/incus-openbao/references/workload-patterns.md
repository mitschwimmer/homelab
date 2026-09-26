# Workload patterns

## Contents

1. Common runtime layout
2. Incus system containers
3. OCI application containers
4. Virtual machines
5. Shared binary distribution
6. Application integration

## Common runtime layout

Aim for this inside every secret-consuming Linux workload:

~~~text
/etc/openbao/agent.hcl      non-secret Agent configuration
/run/openbao/               bootstrap/runtime auth material
/run/secrets/               rendered application secrets
~~~

Use restrictive ownership and modes. The application should be able to read only its own secret files. Do not make `/run/secrets` a shared cross-workload volume.

## Incus system containers

Preferred pattern:

~~~text
system container
+-- bao
+-- openbao-agent.service
+-- application.service
+-- /run/secrets (tmpfs)
~~~

Use systemd to manage Agent and the application separately. Make application startup wait for required secret files, not merely for the Agent process to have started. Use normal restart policies so a temporary OpenBao outage at boot recovers automatically.

Incus can provide `/run/secrets` as a tmpfs disk device. It can also mount a pinned OpenBao binary read-only from a platform-tools volume when this simplifies upgrades.

For system-container images with reliable package/binary installation, installing the pinned binary inside the guest is also acceptable. Pick one platform convention and keep it consistent.

## OCI application containers

OCI images normally expect one application process and often have no systemd. Do not rebuild every upstream application image solely to bake in OpenBao if Incus can provide the Agent binary/config externally.

Preferred Incus plumbing:

- mount a pinned `bao` binary read-only;
- mount non-secret Agent configuration read-only;
- create `/run/secrets` as tmpfs;
- keep bootstrap auth material in a protected runtime path;
- arrange lifecycle so Agent is available before the application consumes its secrets.

There are two lifecycle approaches:

### OpenBao Agent Process Supervisor

If current upstream documentation says the feature is stable enough for the deployment, Agent can become the outer process and launch the application after authentication/templates are ready. This is the cleanest conceptual model.

If the feature is still beta/experimental, do not silently make it the platform default. Call out the status and require an explicit choice.

### Small container supervisor/wrapper

Use a minimal, auditable init/supervisor when Process Supervisor is not accepted. It must:

1. start Agent;
2. wait for required rendered secret files;
3. start the application;
4. forward termination signals correctly;
5. reap child processes;
6. fail closed if initial secret acquisition fails;
7. define what happens if Agent later dies.

Do not use a naive shell background process plus `exec` if it loses Agent lifecycle/signal handling.

## Virtual machines

Treat the VM as an independent Linux machine:

~~~text
VM
+-- locally installed pinned bao binary
+-- systemd OpenBao Agent
+-- application service
+-- guest /run/secrets
~~~

Provision the Agent binary and non-secret config through the normal guest bootstrap mechanism, commonly cloud-init. Do not mount the executable from the host merely to avoid installing it; preserve the VM boundary.

The VM's own `/run` is already ephemeral on conventional Linux systems. Verify rather than assume this for unusual guest images.

## Shared binary distribution

For containers, a read-only Incus platform-tools volume is reasonable:

~~~text
platform-tools/openbao/<version>/<arch>/bao
~~~

Operational rules:

- pin version and architecture;
- verify the upstream checksum/signature before publishing the binary to the shared volume;
- do not replace a binary in place while workloads are using it;
- publish a new versioned path and roll workloads deliberately;
- keep old versions long enough for rollback.

Do not turn a shared writable tools volume into another supply-chain trust problem.

## Application integration

Prefer native file-secret mechanisms, for example settings conceptually like:

~~~text
SMTP_PASSWORD_FILE=/run/secrets/smtp-password
DATABASE_PASSWORD_FILE=/run/secrets/database-password
~~~

When an application only accepts environment variables, prefer having the trusted launcher read the file immediately before starting the application. Understand that the resulting secret becomes visible to the application process and potentially its child processes.

Never put secret values in command-line arguments because they may appear in process listings, logs, or diagnostic output.
