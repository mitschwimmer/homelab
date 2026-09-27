# Model binaries are uploaded directly to this volume, never stored in state.
# Create it with llama.enabled=false, upload the model, then enable the instance.
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

resource "incus_instance" "llama" {
  count    = var.llama == null ? 0 : (var.llama.enabled ? 1 : 0)
  name     = "llama"
  image    = "oci-ghcr:ggml-org/llama.cpp:server-rocm-b10362"
  remote   = var.site.incus_remote
  profiles = []

  config = {
    "boot.autostart"                          = "true"
    "boot.autorestart"                        = "true"
    "oci.uid"                                 = "1000"
    "oci.gid"                                 = "1000"
    "environment.LLAMA_ARG_MODEL"            = "/models/${var.llama.model_file}"
    "environment.LLAMA_ARG_CTX_SIZE"         = tostring(var.llama.context_size)
    "environment.LLAMA_ARG_N_GPU_LAYERS"     = "all"
    "environment.LLAMA_ARG_ENDPOINT_METRICS" = "1"
    "environment.LLAMA_ARG_UI"               = "false"
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
