variable "authelia_bridge_ip" {
  description = "Authelia's reserved IPv4 address on the existing incusbr0 bridge. Check that it is free before the first apply."
  type        = string
  default     = "10.221.180.10"
}

variable "authelia_secret_directory" {
  description = "Absolute path outside this Git checkout containing SESSION_SECRET, STORAGE_ENCRYPTION_KEY, RESET_PASSWORD_JWT_SECRET and users.yml. The path, not the file contents, is stored in OpenTofu state."
  type        = string
}
