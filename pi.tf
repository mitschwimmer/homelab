locals {
  pi_hostname        = var.pi == null ? "" : coalesce(var.pi.hostname, "pi.${var.site.base_domain}")
  pi_service_release = "build-de8c7c683751d0bd91d6e92a8b5f9ea8497f39de"
  pi_service_sha256  = "7b004aaf4be27d0b1e8ad0860c3897fe66d701f28c67e5982f01417744f0756b"
  # INI sections are the router's API IDs. Inherit integer context/slot
  # settings from [*], then apply each model's overrides.
  pi_preset_blocks = split("\n[", "\n${local.llama_presets}")
  pi_preset_limits = {
    for block in slice(local.pi_preset_blocks, 1, length(local.pi_preset_blocks)) : split("]", block)[0] => {
      for setting in regexall("(?m)^[\\t ]*(ctx-size|parallel)[\\t ]*=[\\t ]*([0-9]+)[\\t ]*(?:[;#].*)?\\r?$", block) : setting[0] => tonumber(setting[1])
    }
  }
  pi_model_limits = {
    for name in local.llama_model_names : name => merge(try(local.pi_preset_limits["*"], {}), local.pi_preset_limits[name])
  }
  pi_models = var.pi == null ? {} : {
    providers = {
      homelab = {
        baseUrl = "http://${try(local.private_ips.llama, "127.0.0.1")}:8080/v1"
        api     = "openai-completions"
        apiKey  = "local-no-secret"
        models = [for name in local.llama_model_names : {
          id            = name
          name          = name
          reasoning     = true
          input         = ["text"]
          contextWindow = floor(lookup(local.pi_model_limits[name], "ctx-size", 0) / max(lookup(local.pi_model_limits[name], "parallel", 1), 1))
          maxTokens     = 8192
          cost          = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 }
          compat = {
            supportsDeveloperRole   = false
            supportsStore           = false
            supportsReasoningEffort = false
            maxTokensField          = "max_tokens"
          }
        }]
      }
    }
  }
  pi_cloud_init = var.pi == null ? "" : "#cloud-config\n${yamlencode({
    package_update  = true
    package_upgrade = true
    packages        = ["ca-certificates", "curl", "xz-utils", "ripgrep", "fd-find", "git", "unattended-upgrades"]
    users           = [{ name = "pi", uid = 1000, lock_passwd = true, shell = "/usr/sbin/nologin", no_create_home = true }]
    write_files = [
      { path = "/opt/homelab-pi/install.sh", content = templatefile("${path.module}/pi/install.sh", {
        release_ref    = local.pi_service_release
        archive_sha256 = local.pi_service_sha256
      }), owner = "root:root", permissions = "0444" },
      { path = "/etc/systemd/system/homelab-pi.service", content = file("${path.module}/pi/pi.service"), owner = "root:root", permissions = "0444" },
      { path = "/etc/homelab-pi/models.json", content = jsonencode(local.pi_models), owner = "root:root", permissions = "0444" },
      { path = "/etc/homelab-pi/service.env", content = "PI_PROVIDER=homelab\nPI_WEB_UI_ORIGIN=https://${local.pi_hostname}\nPI_MODEL_ID=${try(local.llama_model_names[0], "unconfigured")}\n", owner = "root:root", permissions = "0444" },
      { path = "/etc/apt/apt.conf.d/20auto-upgrades", content = "APT::Periodic::Update-Package-Lists \"1\";\nAPT::Periodic::Unattended-Upgrade \"1\";\n", owner = "root:root", permissions = "0644" }
    ]
    runcmd = [["/bin/sh", "/opt/homelab-pi/install.sh"]]
  })}"
}

resource "incus_storage_volume" "pi_data" {
  for_each = var.pi == null ? toset([]) : toset(["agent", "workspace"])
  name     = "pi-${each.key}"
  pool     = var.site.storage_pool
  remote   = var.site.incus_remote
  config = {
    "initial.uid"  = "1000"
    "initial.gid"  = "1000"
    "initial.mode" = "0700"
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "terraform_data" "pi_configuration" {
  count            = var.pi == null ? 0 : 1
  triggers_replace = sha256(local.pi_cloud_init)
}

resource "incus_instance" "pi" {
  count    = var.pi == null ? 0 : 1
  name     = "pi"
  image    = "images:debian/13/cloud"
  type     = "virtual-machine"
  remote   = var.site.incus_remote
  profiles = []
  config = {
    "boot.autostart"       = "true"
    "limits.cpu"           = tostring(var.pi.cpu)
    "limits.memory"        = var.pi.memory
    "cloud-init.user-data" = local.pi_cloud_init
  }
  wait_for { type = "agent" }

  lifecycle {
    replace_triggered_by = [terraform_data.pi_configuration]
    precondition {
      condition = !contains(values(var.site.private_host_numbers), var.pi.host_number) && (
        var.llama == null ? true : var.pi.host_number != var.llama.host_number
      ) && (var.openwebui == null ? true : var.pi.host_number != var.openwebui.host_number)
      error_message = "Pi needs a private host number distinct from all other workloads."
    }
    precondition {
      condition     = var.llama == null ? false : var.llama.enabled && length(local.llama_model_names) > 0 && alltrue([for model in local.pi_models.providers.homelab.models : model.contextWindow >= 32768])
      error_message = "Pi requires an enabled llama.cpp router with named presets providing at least 32768 context tokens per slot."
    }
    precondition {
      condition = endswith(local.pi_hostname, ".${var.site.base_domain}") && !contains([
        "auth.${var.site.base_domain}", "grafana.${var.site.base_domain}", try(var.openwebui.hostname, "")
      ], local.pi_hostname)
      error_message = "Pi needs a distinct hostname beneath site.base_domain so Authelia's ForwardAuth cookie applies."
    }
  }
  device {
    name       = "root"
    type       = "disk"
    properties = { path = "/", pool = var.site.storage_pool, size = var.pi.root_size }
  }
  device {
    name       = "eth0"
    type       = "nic"
    properties = { network = var.site.private_bridge, "ipv4.address" = local.private_ips.pi }
  }
  device {
    name       = "agent"
    type       = "disk"
    properties = { path = "/var/lib/pi", pool = var.site.storage_pool, source = incus_storage_volume.pi_data["agent"].name }
  }
  device {
    name       = "workspace"
    type       = "disk"
    properties = { path = "/workspace", pool = var.site.storage_pool, source = incus_storage_volume.pi_data["workspace"].name }
  }
}
