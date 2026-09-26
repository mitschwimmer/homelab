variable "site" {
  description = "Installation-specific IncusOS, LAN and domain settings. Use a local site.auto.tfvars; see site.auto.tfvars.example."
  type = object({
    incus_remote    = string
    storage_pool    = string
    private_bridge  = string
    lan_parent      = string
    caddy_mac       = string
    authelia_ip     = string
    openbao_ip      = string
    prometheus_ip   = string
    grafana_ip      = string
    private_dns_domain = string
    base_domain     = string
  })
}

variable "platform_tools_directory" {
  description = "Absolute path to a verified, pinned OpenBao binary outside the checkout. Contains bao."
  type        = string
}

variable "authelia_smtp" {
  description = "Set to use SMTP instead of the filesystem notifier. Put only nonsecret SMTP settings here; store smtp_password in OpenBao."
  type = object({
    address               = string
    username              = string
    sender                = string
    startup_check_address = string
  })
  default = null
}

variable "incus_metrics" {
  description = "Optional authenticated Incus metrics endpoint. Enroll its certificate and key in OpenBao before starting Prometheus."
  type = object({
    target      = string
    server_name = string
  })
  default = null
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
