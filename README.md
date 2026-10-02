# Homelab

OpenTofu manages measerve networking, OCI instances, persistent volumes, and private workload files. A KeePass database at `$HOME/.keychains/homelab.kdbx` holds application secrets and a separate state encryption passphrase. `scripts/homelab.py` unlocks it and invokes OpenTofu, which encrypts state and saved plans with AES-GCM. See [ADR 0002](docs/adr/0002-keepass-and-encrypted-state.md).

## Enter the Nix shell

On NixOS, change to your homelab checkout (the directory containing `shell.nix`) and enter the environment from **fish**:

```fish
cd /path/to/homelab
nix-shell --run fish
```

Replace `/path/to/homelab` with your checkout's path. This starts a child fish shell with `tofu`, `incus`, `authelia`, `openssl`, the Hugging Face CLI (`hf`), and a Python interpreter with PyKeePass and `cryptography` on its search path. Nix supplies the Python dependencies: there is no `.venv` to activate and no pip installation is needed. Enter this shell again whenever you open a new terminal; leave it with `exit`.

Inside the shell, check that Python can load the dependencies and display the wrapper's commands:

```fish
python3 -c 'import sys, pykeepass, cryptography; print(sys.executable)'
python3 scripts/homelab.py --help
hf --help
```

The first command should print a Python path under `/nix/store/` without an import error. If you get `ModuleNotFoundError`, make sure you entered the Nix shell from the repository root. If another project's virtual environment is active, leave it with `deactivate` before entering this shell.

For a single command without an interactive shell, run this from the repository root:

```fish
nix-shell --run 'python3 scripts/homelab.py tofu plan'
```

Run the remaining commands inside the interactive Nix shell from this repository's root. Use the already authenticated `measerve` Incus remote. Copy `site.auto.tfvars.example` to ignored `site.auto.tfvars` and set your actual pool, bridge, LAN interface, MAC, host numbers, and domain. Remove the former `openbao` host number if updating an older site file. Check the current host:

```fish
incus storage list measerve:
incus network show measerve:incusbr0
```

Caddy's LAN MAC needs a DHCP reservation, public DNS for `auth.<base_domain>` and `grafana.<base_domain>`, and ports 80/443 forwarded to it. Grafana signs users in through Authelia OIDC: only members of the `admins` group with a second factor can complete authorization, and Grafana assigns them its server administrator role. The apex domain is not served. The private host numbers must be distinct and avoid the bridge gateway and broadcast address.

## Resume work on an existing installation

If KeePass and encrypted OpenTofu state are already set up, keep using that database, state, and your ignored `site.auto.tfvars`. The state migration below is a one-time setup step; do not archive your current state when resuming work. OpenTofu loads `site.auto.tfvars` automatically from the repository root.

After entering the Nix shell, validate and review your changes:

```fish
python3 scripts/homelab.py tofu validate
python3 scripts/homelab.py tofu plan
```

If OpenTofu reports that initialization is required (for example, in a fresh checkout with your existing state restored), run `python3 scripts/homelab.py tofu init` first. The wrapper prompts for your KeePass master password on each invocation and supplies the secrets and state encryption passphrase to OpenTofu.

After reviewing the plan, apply it with `python3 scripts/homelab.py tofu apply` and review its confirmation prompt. For the GPU workload, continue with [the llama.cpp setup](#serve-a-gguf-with-llamacpp-and-rocm): recording `gpu_pci` alone does not upload a model. Keep `llama.enabled = false` until the model volume exists and the configured GGUF has been uploaded, then enable the instance and plan/apply again.

## Start with an empty OpenTofu state

This workflow deliberately starts a **new state**. Before using this checkout, finish any cleanup with the old checkout and state, then archive the old state outside the repository. The OpenBao retirement backup is a separate recovery copy. In fish:

```fish
mkdir -p $HOME/.keychains/retired-homelab-state
chmod 700 $HOME/.keychains $HOME/.keychains/retired-homelab-state
for file in terraform.tfstate terraform.tfstate.backup
    if test -f $file
        mv -n $file $HOME/.keychains/retired-homelab-state/
        chmod 600 $HOME/.keychains/retired-homelab-state/$file
    end
end
```

An empty OpenTofu state does **not** mean an empty Incus host. Inspect `incus list measerve:` and `incus storage volume list measerve:local` before applying. The earlier OpenBao bootstrap also created `authelia-secrets` and `grafana-secrets` volumes, and perhaps `prometheus-secrets`. If they still exist, reconcile them using the old state before archiving it, or import them into the new encrypted state. Never run a new-state apply against existing resources of the same names; it will try to create them again. Retain the old state archive privately for recovery.

## Create the KeePass database and application secrets

```fish
python3 scripts/homelab.py init-secrets
```

The script creates `$HOME/.keychains/homelab.kdbx` with owner-only permissions, prompts for a master password, and generates stable random application values, an RSA OIDC signing key, and a separate random state encryption passphrase. It also invokes the Authelia CLI to generate a matching Grafana OIDC client secret and PBKDF2 hash, and saves both directly in KeePass. Repeating the command retains existing values. If only one Grafana OIDC value exists from an interrupted setup, it replaces the partial pair with a fresh matching pair. It repairs permissions on a database made too permissive by older versions of the script. Back up the KDBX database and master password independently of state. Do not change `state_passphrase` while state or saved plans encrypted with it still exist.

Create a private `users.yml` based on the example. Generate an Argon2 hash for the account password, replace the example hash and email, and keep the `admins` group for a Grafana administrator:

```fish
authelia crypto hash generate argon2
cp authelia/users.yml.example $HOME/.keychains/users.yml
chmod 600 $HOME/.keychains/users.yml
# Edit $HOME/.keychains/users.yml privately, then import it:
python3 scripts/homelab.py set authelia/users_yml < $HOME/.keychains/users.yml
```

`set` also accepts redirected stdin for multiline values. Once the KeePass entry and backup are verified, remove the temporary `users.yml` file if it is no longer needed.

If SMTP is configured in `site.auto.tfvars`, add `authelia/smtp_password` with `set`. If Incus metrics are configured, add `prometheus/incus_server_cert`, `prometheus/incus_metrics_cert`, and `prometheus/incus_metrics_key` from private files. The file-based notifier and default Prometheus setup need no optional entries.

## Initialize and apply

Run every OpenTofu command through the wrapper so it can supply the state passphrase and application secrets. It does not create plaintext tfvars or saved plans:

```fish
python3 scripts/homelab.py tofu init
python3 scripts/homelab.py tofu validate
python3 scripts/homelab.py tofu plan
python3 scripts/homelab.py tofu apply
```

Review the plan for only the resources you intend to create. The provider writes mode `0400` secret files with each application's UID/GID into private `0700` volumes, mounted read-only in each OCI instance. Encrypted state and saved plans still contain those values, and Incus volumes and their backups contain the plaintext. File encryption at rest does not hide values from an operator running `tofu show -json`, `tofu state pull`, verbose provider logging, or captured process environments. Treat such output as secret material.

## Collect Incus instance metrics

The Prometheus data source is provisioned through `grafana/datasources.yml.tftpl`. This repository also provisions the **Dashboards → Homelab → Incus instances** dashboard from `grafana/incus.json`, showing scrape status and per-instance CPU, memory, network, and disk use. Grafana reads both definitions when OpenTofu applies this configuration; dashboard changes in the repository take effect after an apply. The provisioning volumes must be readable and listable by Grafana's UID 472. This change recreates the older data source provisioning volume, whose default mode prevented Grafana from discovering its YAML file. To troubleshoot an empty dashboard after applying, query `up{job="incus"}` in Grafana Explore and wait for a scrape.

The IncusOS default Incus application listens on port 8443. Check the address of the `measerve` remote and confirm that its metrics endpoint responds with `incus_` metrics:

```fish
incus remote list
incus query measerve:/1.0/metrics | head -n 10
```

Create a dedicated metrics certificate and enroll only its public certificate with Incus. Do this once; keep the key private and backed up. The Nix shell includes OpenSSL:

```fish
mkdir -p $HOME/.keychains/incus-metrics
chmod 700 $HOME/.keychains/incus-metrics
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -sha384 -nodes -days 3650 -subj '/CN=homelab-prometheus' -keyout $HOME/.keychains/incus-metrics/metrics.key -out $HOME/.keychains/incus-metrics/metrics.crt
chmod 600 $HOME/.keychains/incus-metrics/metrics.key
incus config trust add-certificate measerve: $HOME/.keychains/incus-metrics/metrics.crt --type=metrics
```

The Incus client keeps the trusted server certificate at `$HOME/.config/incus/servercerts/measerve.crt` for a user-configured remote. Inspect its subject alternative names to choose `server_name` for the Prometheus TLS check:

```fish
openssl x509 -in $HOME/.config/incus/servercerts/measerve.crt -noout -ext subjectAltName
```

Import the three files into KeePass. The metrics certificate is public, but keeping the certificate and key together simplifies recovery:

```fish
python3 scripts/homelab.py set prometheus/incus_server_cert < $HOME/.config/incus/servercerts/measerve.crt
python3 scripts/homelab.py set prometheus/incus_metrics_cert < $HOME/.keychains/incus-metrics/metrics.crt
python3 scripts/homelab.py set prometheus/incus_metrics_key < $HOME/.keychains/incus-metrics/metrics.key
```

In ignored `site.auto.tfvars`, set `incus_metrics = { target = "<measerve LAN IP>:8443", server_name = "<DNS name in the certificate SAN>" }`. The target must be reachable from the Prometheus instance on the private bridge; `incus remote list` shows the management endpoint to start from. IncusOS may issue a certificate whose only non-loopback SAN is a UUID-shaped DNS name. In that case, use that exact DNS name for `server_name` while keeping the reachable LAN IP in `target`. The two values serve different purposes: Prometheus connects to `target` and checks the server certificate against `server_name`. The `127.0.0.1` and `::1` SANs are only suitable when connecting over loopback. Then run `python3 scripts/homelab.py tofu plan` and `python3 scripts/homelab.py tofu apply`. The plan should add the private `prometheus-secrets` volume and replace Prometheus to mount it. In Grafana Explore, query `up{job="incus"}`; it should return `1`. Then try `incus_cpu_seconds_total` to confirm instance data is present. Prometheus scrapes this endpoint over TLS every 60 seconds, so wait for a scrape after apply.

To rotate a value, update its KeePass entry with `set`, run `python3 scripts/homelab.py tofu plan` and `python3 scripts/homelab.py tofu apply`, then restart the affected workload if it does not reload the file. Back up the KeePass database, encrypted state, IncusOS pool keys, Incus application, and workload volumes as described in [recovery](docs/recovery.md). A push to GitHub does not deploy measerve.

## Publish Open WebUI with Authelia OIDC

Open WebUI is optional. It runs the pinned `v0.11.4` upstream image, connects to llama.cpp's private OpenAI-compatible `/v1` API, and stores users, chats, and uploads in `openwebui-data`. Caddy terminates HTTPS for `ai.archaic.work`. The llama.cpp API itself remains private. A working WebUI health check does not establish that llama.cpp can serve a model; verify backend health before testing chat.

Login uses the existing `https://auth.<base_domain>` Authelia provider, with authorization-code flow, S256 PKCE, and a confidential client. The application hostname can be on a different domain from Authelia; do not change `site.base_domain` just to add it. Authelia allows only `admins` with a second factor to authorize this client, and Open WebUI maps that group to its administrator role. Password login and local signup are disabled; OAuth account creation is enabled. Environment configuration remains authoritative even after a database exists. The [Authelia integration guide](https://www.authelia.com/integration/openid-connect/clients/open-webui/) documents this flow.

Point `ai.archaic.work`'s public A record (and AAAA only if IPv6 routing works) at the router's public address. Existing ports 80/443 must reach Caddy. The browser and the Open WebUI instance must also reach Authelia's public HTTPS URL; check DNS and NAT loopback/split DNS if discovery or token exchange fails. Keep TLS verification enabled.

In ignored `site.auto.tfvars`, add the following, choosing a host number distinct from all existing workloads and the bridge gateway/broadcast:

```hcl
openwebui = {
  hostname    = "ai.archaic.work"
  host_number = 14
}
```

The `llama` configuration must exist and have `enabled = true`. Run these commands from the repository root in its Nix shell:

```fish
python3 scripts/homelab.py init-secrets
python3 scripts/homelab.py tofu validate
python3 scripts/homelab.py tofu plan
python3 scripts/homelab.py tofu apply
```

`init-secrets` retains complete existing credentials and creates the Open WebUI session key and matching OIDC secret/hash pair in KeePass. Back up the updated database. The secret volumes hold private files; a small startup script reads them into the process environment because Open WebUI does not support an `OAUTH_CLIENT_SECRET_FILE` option. Values do not enter Incus configuration or startup arguments. They remain accessible to privileged operators and in encrypted state and private volume backups, as with the other workloads. An incomplete OIDC pair is regenerated together; rotating an existing pair requires updating both entries and restarting both applications.

Expect the plan to add Open WebUI, its data/config/secrets volumes, and the Authelia client secret file; it also replaces Authelia to load the new client and reloads Caddy with the new route. Review any other changes separately, including temporary llama debugging settings. This repository does not apply infrastructure changes on push.

After applying:

```fish
incus exec measerve:openwebui -- curl -fsS http://127.0.0.1:8080/health
incus exec measerve:openwebui -- curl -fsS https://auth.<base_domain>/.well-known/openid-configuration
incus exec measerve:openwebui -- curl -fsS http://<llama-private-IP>:8080/v1/models
```

Replace the placeholders with your configured domain and the llama address from `python3 scripts/homelab.py tofu output private_addresses`. Open `https://ai.archaic.work`, complete Authelia login with an `admins` account and a second factor, and send a chat message. Verify a non-admin account cannot authorize the client and that no password signup/login path is usable. Test streaming and reload the page to confirm chat persistence. For failures, inspect `incus console measerve:openwebui --show-log` and the Authelia/Caddy logs. Back up `openwebui-data` before image upgrades; it contains personal conversations and uploads, and database migrations may affect downgrade compatibility. The volume has destruction protection and survives instance replacement.

## Serve models with llama.cpp and ROCm

The optional llama.cpp workload runs the pinned `server-rocm-b11277` image as UID/GID 1000. It receives the selected GPU's DRM render node and `/dev/kfd`. The API listens on port 8080 on the private bridge, with no public Caddy route. Open WebUI keeps using the same `/v1` endpoint.

The server runs in **router mode**. Requests select `mimo` or `qwen36` using the OpenAI API's `model` field. At most one model is loaded at a time. Requesting another model unloads the previous one and starts the requested model with its own settings. Model switching takes loading time; the first load also downloads the weights. Concurrent requests for different models share this single residency slot and can incur queueing and repeated switches.

### Configure and apply

Check the GPU and an available storage pool on measerve. If the IncusOS GPU firmware application is missing, install it and verify that Incus detects the card. Run the `add` command only if `gpu-support` is absent:

```fish
incus admin os application list measerve:
incus admin os application add measerve:gpu-support
incus info measerve: --resources
incus storage list measerve:
```

Confirm the AMD card reports the `amdgpu` driver and a DRM render node. Firmware does not replace the host kernel driver. Add the following to your ignored `site.auto.tfvars`, using an existing pool and the actual full PCI address. The host number must differ from the other workloads:

```hcl
llama = {
  enabled      = true
  host_number  = 13
  storage_pool = "<existing-pool>"
  gpu_pci      = "<full-GPU-PCI-address>"
}
```

A fresh installation needs no manual model upload. Plan and apply from the repository's Nix shell:

```fish
python3 scripts/homelab.py tofu plan
python3 scripts/homelab.py tofu apply
incus exec measerve:llama -- curl -fsS http://127.0.0.1:8080/health
incus exec measerve:llama -- curl -fsS http://127.0.0.1:8080/v1/models
```

Review the plan: it creates `llama-cache` and `llama-config` and may replace the llama and Prometheus instances. Changes to presets replace the llama instance so it reads the new configuration. There is no deployment on push.

The volumes have distinct roles:

| Volume | Mount | Purpose |
| --- | --- | --- |
| `llama-cache` | `/var/cache/llama`, writable UID/GID 1000 | Persistent Hugging Face downloads (`LLAMA_CACHE`) |
| `llama-config` | `/etc/llama`, read-only | Rendered model presets |
| `llama-models` | Not mounted | Protected archive of previously uploaded GGUFs |

The cache and archived model volumes have destruction protection and survive instance replacement. Cached weights do not enter OpenTofu state. Keep enough space for the two new GGUFs (approximately 21 GB total), any existing models, download temporary files, and future updates. Back up weights if avoiding a re-download matters. Changing the model pool requires a deliberate volume migration.

### Model presets

Manage models, download repositories/files, and all model settings only in [`llama/models.ini.tftpl`](llama/models.ini.tftpl). Add, rename, or remove named INI sections there; their names become API model IDs and Prometheus targets automatically. Plan and apply after editing. The `llama` tfvars object contains only infrastructure settings. Shared defaults use one slot, full GPU offload, Flash Attention, Q8 KV cache, Jinja, no vision projector, and no speculative decoding. These are text-only coding-agent presets:

| API model | Distributor and quant | Initial context | Speculation |
| --- | --- | --- | --- |
| `mimo` | `bartowski/MiMo-V2.6-Distill-Qwen-9B-GGUF`, `Q5_K_M` | 131072 tokens | None |
| `qwen36` | `unsloth/Qwen3.6-35B-A3B-MTP-GGUF`, `UD-IQ3_XXS` | 65536 tokens | None initially |

Both presets specify the exact `hf-file`; llama.cpp downloads only the selected text model, not the entire repository or its vision projector. Downloads require internet access to Hugging Face and its file storage endpoints. These public repositories need no token. A first request can take several minutes to download. The cache persists across replacements, but upstream repository contents can change: filenames are explicit, not immutable revision pins.

Context sizes are **trial targets**, not measured VRAM-fit guarantees on the RX 9060 XT. Check startup allocations and that all layers are on the intended GPU. If a load fails for lack of VRAM, reduce that preset's `ctx-size`, plan/apply, and repeat. Do not assume `/health` success establishes that any model has loaded or uses the GPU.

Keep each GGUF's embedded template. Unsloth documents Qwen3.6 improvements for developer messages and nested tool arguments; validate actual multi-turn tool calls before accepting the template. MiMo uses its own chat template despite its Qwen architecture. If a template override becomes necessary, mount the reviewed file in `llama-config` and add `chat-template-file = /etc/llama/<filename>` to that model's preset.

Qwen3.6's default coding sampler is temperature 0.6, top-p 0.95, top-k 20, min-p 0; requests can override sampling parameters. Both presets explicitly enable thinking. Validate thinking extraction and tool calls with the actual agent. After validating Qwen3.6's baseline and available VRAM, uncomment its `spec-type = draft-mtp` and `spec-draft-n-max = 2` settings, apply, and compare speed and correctness. Do not enable MTP globally or assume MiMo's GGUF contains a usable MTP head.

Model-specific settings belong in the INI, not global `LLAMA_ARG_CTX_SIZE`, `LLAMA_ARG_SPEC_TYPE`, or `LLAMA_ARG_CHAT_TEMPLATE_KWARGS` environment variables. Router CLI/environment settings can override presets.

### Warm up and switch models

Load each preset once to download and validate it. Run these commands **sequentially**; the second load replaces the first:

```fish
incus exec measerve:llama -- curl -fsS --max-time 3600 \
  http://127.0.0.1:8080/models/load \
  -H 'Content-Type: application/json' -d '{"model":"mimo"}'
incus exec measerve:llama -- curl -fsS --max-time 3600 \
  http://127.0.0.1:8080/models/load \
  -H 'Content-Type: application/json' -d '{"model":"qwen36"}'
incus console measerve:llama --show-log
```

`/models` reports load state and failures. Confirm `loaded` and test an actual completion; do not rely only on the load acknowledgement. To select a model through the API:

```fish
incus exec measerve:openwebui -- curl -fsS --max-time 3600 \
  http://<llama-private-IP>:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"mimo","messages":[{"role":"user","content":"Explain a small Java record example."}],"max_tokens":2048}'
```

Use `qwen36` to switch. Open WebUI should list these names after refreshing its model list. Existing chats referring to an old filename/alias need the corresponding new selection. For agents, set their model ID to the preset name and their advertised context limit to the tested server context.

### Existing installations

Reduce your existing `llama` tfvars block to `enabled`, `host_number`, `storage_pool`, and `gpu_pci`. Remove `model_file`, `context_size`, `parallel`, `speculative_type`, `draft_max`, and `reasoning_effort`; model configuration now lives solely in `llama/models.ini.tftpl`. The previous uploaded files remain protected on the unmounted `llama-models` volume, but there is no `local` preset.

The download volume is created with the correct UID/GID. Inspect manually applied instance settings before deploying; remove any obsolete global model/context/speculation/template environment settings that remain outside OpenTofu's managed configuration.

The historical Qwen3.8 short-prompt benchmark on b10362 measured about 16.4 tokens/s without MTP and 28.6 with two draft tokens at 8k context. It does not establish performance for these new models or their larger contexts. Compare prompt processing, time to first tool call, and time to a correct tested change on representative coding tasks.

### Monitoring and validation

Prometheus scrapes each preset with `model=<name>&autoload=false`, retaining `job="llama"` and adding a `model` label. Monitoring therefore never downloads or loads an idle model. An unloaded model's scrape can fail (`up=0`); that alone is not a service outage. Use the router's `/health` for service health and `/models` for residency. Model inference metrics are available only while that model is loaded.

The router remains private and has no API key; it is for trusted bridge services. Do not expose its model management endpoints through Caddy. The b11277 source supports presets, automatic downloading, and one-model residency. The CPU binary can validate router startup and presets locally; ROCm memory fit, MTP performance, embedded template behavior, and Open WebUI switching still require validation on measerve.

Run the configuration checks without accessing a live Incus host:

```fish
tofu fmt -check -recursive
tofu init -backend=false
tofu validate
tofu test
```

The mocked tests cover optional installations, writable cache permissions, model settings and IDs from the INI, removal of the uploaded-model mount, and non-loading monitoring.
