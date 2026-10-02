# Retain the existing volume for manually uploaded models, including legacy
# single-model installations. Downloads use a separate UID-1000 cache volume.
resource "incus_storage_volume" "llama_models" {
  count  = var.llama == null ? 0 : 1
  name   = "llama-models"
  pool   = var.llama.storage_pool
  remote = var.site.incus_remote
  config = {
    "initial.mode" = "0755"
  }

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = !contains(values(var.site.private_host_numbers), var.llama.host_number)
      error_message = "The llama private host number must differ from the other workloads."
    }
  }
}

resource "incus_storage_volume" "llama_cache" {
  count  = var.llama == null ? 0 : 1
  name   = "llama-cache"
  pool   = var.llama.storage_pool
  remote = var.site.incus_remote
  config = {
    "initial.uid"  = "1000"
    "initial.gid"  = "1000"
    "initial.mode" = "0750"
  }

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  llama_presets = var.llama == null ? "" : templatefile("${path.module}/llama/models.ini.tftpl", {
    model_file       = var.llama.model_file
    context_size     = var.llama.context_size
    parallel         = var.llama.parallel
    speculative_type = var.llama.speculative_type
    draft_max        = var.llama.draft_max
    reasoning_effort = var.llama.reasoning_effort
  })
  llama_model_names = concat(["mimo", "qwen36"], var.llama == null ? [] : (
    var.llama.model_file == null ? [] : ["local"]
  ))
}

resource "incus_storage_volume" "llama_config" {
  count  = var.llama == null ? 0 : 1
  name   = "llama-config"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote
  file {
    target_path = "/models.ini"
    content     = local.llama_presets
    mode        = "0644"
  }
}

resource "terraform_data" "llama_configuration" {
  count            = var.llama == null ? 0 : 1
  triggers_replace = sha256(local.llama_presets)
}

resource "incus_instance" "llama" {
  count    = var.llama == null ? 0 : (var.llama.enabled ? 1 : 0)
  name     = "llama"
  image    = "oci-ghcr:ggml-org/llama.cpp:server-rocm-b11277"
  remote   = var.site.incus_remote
  profiles = []

  config = {
    "boot.autostart"                         = "true"
    "boot.autorestart"                       = "true"
    "oci.uid"                                = "1000"
    "oci.gid"                                = "1000"
    "environment.LLAMA_CACHE"                = "/var/cache/llama"
    "environment.LLAMA_ARG_MODELS_PRESET"    = "/etc/llama/models.ini"
    "environment.LLAMA_ARG_MODELS_MAX"       = "1"
    "environment.LLAMA_ARG_MODELS_AUTOLOAD"  = "true"
    "environment.LLAMA_ARG_HOST"             = "0.0.0.0"
    "environment.LLAMA_ARG_PORT"             = "8080"
    "environment.LLAMA_ARG_ENDPOINT_METRICS" = "1"
    "environment.LLAMA_ARG_UI"               = "false"
  }

  lifecycle {
    replace_triggered_by = [terraform_data.llama_configuration]
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = var.site.storage_pool
    }
  }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      network        = var.site.private_bridge
      "ipv4.address" = local.private_ips.llama
    }
  }

  device {
    name = "models"
    type = "disk"
    properties = {
      path     = "/models"
      pool     = var.llama.storage_pool
      source   = incus_storage_volume.llama_models[0].name
      readonly = "true"
    }
  }

  device {
    name = "cache"
    type = "disk"
    properties = {
      path   = "/var/cache/llama"
      pool   = var.llama.storage_pool
      source = incus_storage_volume.llama_cache[0].name
    }
  }

  device {
    name = "config"
    type = "disk"
    properties = {
      path     = "/etc/llama"
      pool     = var.site.storage_pool
      source   = incus_storage_volume.llama_config[0].name
      readonly = "true"
    }
  }

  device {
    name = "gpu"
    type = "gpu"
    properties = {
      gputype = "physical"
      pci     = var.llama.gpu_pci
      uid     = "1000"
      gid     = "1000"
      mode    = "0660"
    }
  }

  device {
    name = "kfd"
    type = "unix-char"
    properties = {
      source = "/dev/kfd"
      path   = "/dev/kfd"
      uid    = "1000"
      gid    = "1000"
      mode   = "0660"
    }
  }
}
