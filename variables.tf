variable "site" {
  description = "Installation-specific IncusOS, LAN and domain settings. Use a local site.auto.tfvars; see site.auto.tfvars.example."
  type = object({
    incus_remote    = string
    storage_pool    = string
    private_bridge  = string
    lan_parent      = string
    caddy_mac       = string
    authelia_ip     = string
    prometheus_ip   = string
    grafana_ip      = string
    private_dns_domain = string
    base_domain     = string
  })
}

variable "authelia_secret_directory" {
  description = "Absolute path outside this Git checkout containing SESSION_SECRET, STORAGE_ENCRYPTION_KEY, RESET_PASSWORD_JWT_SECRET and users.yml. The path, not the file contents, is stored in OpenTofu state."
  type        = string
}

variable "authelia_smtp" {
  description = "Set to use SMTP instead of the filesystem notifier. Put only nonsecret SMTP settings here; keep SMTP_PASSWORD in the private secret directory."
  type = object({
    address               = string
    username              = string
    sender                = string
    startup_check_address = string
  })
  default = null
}

variable "monitoring_secret_directory" {
  description = "Private directory outside the checkout with Grafana and OIDC secrets. File paths, not contents, are recorded in state."
  type        = string
}

variable "incus_metrics" {
  description = "Optional authenticated Incus metrics endpoint. Put its TLS certificate and key in monitoring_secret_directory before enabling."
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
