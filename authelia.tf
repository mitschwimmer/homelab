resource "incus_storage_volume" "authelia_config" {
  name   = "authelia-config"
  pool   = "local"
  remote = "IncusOS"

  file {
    content     = file("${path.module}/authelia/configuration.yml")
    target_path = "/configuration.yml"
    mode        = "0644"
  }
}

resource "incus_storage_volume" "authelia_secrets" {
  name   = "authelia-secrets"
  pool   = "local"
  remote = "IncusOS"

  # source_path makes the provider read bytes at apply time. The state records
  # file paths rather than the session keys, encryption key or password hashes.
  file {
    source_path = "${var.authelia_secret_directory}/SESSION_SECRET"
    target_path = "/SESSION_SECRET"
    mode        = "0600"
  }

  file {
    source_path = "${var.authelia_secret_directory}/STORAGE_ENCRYPTION_KEY"
    target_path = "/STORAGE_ENCRYPTION_KEY"
    mode        = "0600"
  }

  file {
    source_path = "${var.authelia_secret_directory}/RESET_PASSWORD_JWT_SECRET"
    target_path = "/RESET_PASSWORD_JWT_SECRET"
    mode        = "0600"
  }

  file {
    source_path = "${var.authelia_secret_directory}/users.yml"
    target_path = "/users.yml"
    mode        = "0600"
  }
}

resource "incus_storage_volume" "authelia_data" {
  name   = "authelia-data"
  pool   = "local"
  remote = "IncusOS"
}

resource "incus_instance" "authelia" {
  name     = "authelia"
  image    = "oci-docker:authelia/authelia:4.39.28"
  remote   = "IncusOS"
  profiles = []

  config = {
    "boot.autostart" = "true"
    "environment.AUTHELIA_SESSION_SECRET_FILE" = "/secrets/SESSION_SECRET"
    "environment.AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE" = "/secrets/STORAGE_ENCRYPTION_KEY"
    "environment.AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE" = "/secrets/RESET_PASSWORD_JWT_SECRET"
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = "local"
    }
  }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      network        = "incusbr0"
      "ipv4.address" = var.authelia_bridge_ip
    }
  }

  device {
    name = "authelia-config"
    type = "disk"
    properties = {
      path   = "/config"
      pool   = "local"
      source = incus_storage_volume.authelia_config.name
    }
  }

  device {
    name = "authelia-secrets"
    type = "disk"
    properties = {
      path     = "/secrets"
      pool     = "local"
      source   = incus_storage_volume.authelia_secrets.name
      readonly = "true"
    }
  }

  device {
    name = "authelia-data"
    type = "disk"
    properties = {
      path   = "/data"
      pool   = "local"
      source = incus_storage_volume.authelia_data.name
    }
  }
}
