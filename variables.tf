variable "site" {
  description = "Installation-specific IncusOS, LAN and domain settings. Use a local site.auto.tfvars; see site.auto.tfvars.example."
  type = object({
    incus_remote    = string
    storage_pool    = string
    private_bridge  = string
    lan_parent      = string
    caddy_mac       = string
    authelia_ip     = string
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
