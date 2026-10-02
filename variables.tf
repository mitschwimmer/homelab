variable "site" {
  description = "Installation-specific IncusOS, LAN and domain settings. Use a local site.auto.tfvars; see site.auto.tfvars.example."
  type = object({
    incus_remote   = string
    storage_pool   = string
    private_bridge = string
    lan_parent     = string
    caddy_mac      = string
    private_host_numbers = object({
      authelia   = number
      prometheus = number
      grafana    = number
    })
    private_dns_domain = string
    base_domain        = string
  })

  validation {
    condition = length(distinct(values(var.site.private_host_numbers))) == 3 && alltrue([
      for n in values(var.site.private_host_numbers) : n > 1 && n == floor(n)
    ])
    error_message = "Choose three distinct whole private host numbers greater than 1, avoiding the bridge gateway and broadcast address."
  }
}

variable "state_passphrase" {
  description = "Stable KeePass-held encryption passphrase. Supply only through scripts/homelab.py."
  type        = string
  sensitive   = true
}

variable "workload_secrets" {
  description = "Values loaded from KeePass by scripts/homelab.py. Never put them in tfvars or Git."
  type        = map(map(string))
  sensitive   = true
}

variable "authelia_smtp" {
  description = "Set to use SMTP instead of the filesystem notifier. Put only nonsecret SMTP settings here; store smtp_password in KeePass."
  type = object({
    address               = string
    username              = string
    sender                = string
    startup_check_address = string
  })
  default = null
}

variable "incus_metrics" {
  description = "Optional authenticated Incus metrics endpoint. Enroll its certificate and key in KeePass before starting Prometheus."
  type = object({
    target      = string
    server_name = string
  })
  default = null
}

variable "llama" {
  description = "Optional ROCm llama.cpp model router with automatic downloads. model_file and its tuning fields optionally retain an existing uploaded GGUF as the local preset."
  type = object({
    enabled          = bool
    host_number      = number
    storage_pool     = string
    gpu_pci          = string
    model_file       = optional(string)
    context_size     = optional(number, 49152)
    parallel         = optional(number, 1)
    speculative_type = optional(string, "draft-mtp")
    draft_max        = optional(number, 2)
    reasoning_effort = optional(string, "medium")
  })
  default = null

  validation {
    condition = var.llama == null ? true : (
      var.llama.host_number > 1 &&
      var.llama.host_number == floor(var.llama.host_number) &&
      can(regex("^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\\.[0-7]$", var.llama.gpu_pci)) &&
      (var.llama.model_file == null ? true : can(regex("^[^/\\\\\\r\\n]+\\.gguf$", var.llama.model_file))) &&
      var.llama.context_size >= 512 && var.llama.context_size == floor(var.llama.context_size) &&
      var.llama.parallel >= 1 && var.llama.parallel == floor(var.llama.parallel) &&
      contains(["none", "draft-mtp"], var.llama.speculative_type) &&
      var.llama.draft_max >= 1 && var.llama.draft_max == floor(var.llama.draft_max) &&
      contains(["low", "medium", "xhigh"], var.llama.reasoning_effort) &&
      trimspace(var.llama.storage_pool) != ""
    )
    error_message = "Set a whole host number greater than 1, an existing storage pool, a full GPU PCI address, a GGUF filename, context size of at least 512, positive whole parallel/draft counts, speculative_type none or draft-mtp, and reasoning_effort low, medium or xhigh."
  }
}

variable "openwebui" {
  description = "Optional public Open WebUI with Authelia OIDC and the private llama.cpp backend."
  type = object({
    hostname    = optional(string, "ai.archaic.work")
    host_number = number
  })
  default = null

  validation {
    condition = var.openwebui == null ? true : (
      var.openwebui.host_number > 1 &&
      var.openwebui.host_number == floor(var.openwebui.host_number) &&
      can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.openwebui.hostname))
    )
    error_message = "Set a whole host number greater than 1 and a lowercase DNS hostname."
  }
}

variable "prometheus_extra_targets" {
  description = "Additional private HTTP Prometheus exporters, for example the Immich API and microservices endpoints once deployed."
  type = list(object({
    job_name     = string
    target       = string
    metrics_path = string
  }))
  default = []
}
