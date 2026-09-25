locals {
  authelia_configuration = templatefile("${path.module}/authelia/configuration.yml.tftpl", {
    smtp_enabled        = var.authelia_smtp != null
    smtp_address        = var.authelia_smtp == null ? "" : var.authelia_smtp.address
    smtp_username       = var.authelia_smtp == null ? "" : var.authelia_smtp.username
    smtp_sender         = var.authelia_smtp == null ? "" : var.authelia_smtp.sender
    smtp_check_address  = var.authelia_smtp == null ? "" : var.authelia_smtp.startup_check_address
    base_domain         = var.site.base_domain
  })
}

resource "terraform_data" "authelia_configuration" {
  triggers_replace = sha256(local.authelia_configuration)
}

resource "incus_storage_volume" "authelia_config" {
  name   = "authelia-config"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote

  file {
    content     = local.authelia_configuration
    target_path = "/configuration.yml"
    mode        = "0644"
  }
}

resource "incus_storage_volume" "authelia_secrets" {
  name   = "authelia-secrets"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote

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

  dynamic "file" {
    for_each = var.authelia_smtp == null ? [] : [1]
    content {
      source_path = "${var.authelia_secret_directory}/SMTP_PASSWORD"
      target_path = "/SMTP_PASSWORD"
      mode        = "0600"
    }
  }

  file {
    source_path = "${var.monitoring_secret_directory}/OIDC_HMAC_SECRET"
    target_path = "/OIDC_HMAC_SECRET"
    mode        = "0600"
  }

  file {
    source_path = "${var.monitoring_secret_directory}/OIDC_JWKS"
    target_path = "/OIDC_JWKS"
    mode        = "0600"
  }

  file {
    source_path = "${var.monitoring_secret_directory}/GRAFANA_CLIENT_SECRET_HASH"
    target_path = "/GRAFANA_CLIENT_SECRET_HASH"
    mode        = "0600"
  }
}

resource "incus_storage_volume" "authelia_data" {
  name   = "authelia-data"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote
}

resource "incus_instance" "authelia" {
  name     = "authelia"
  image    = "oci-docker:authelia/authelia:4.39.28"
  remote   = var.site.incus_remote
  profiles = []

  config = merge({
    "boot.autostart" = "true"
    "environment.AUTHELIA_SESSION_SECRET_FILE" = "/secrets/SESSION_SECRET"
    "environment.AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE" = "/secrets/STORAGE_ENCRYPTION_KEY"
    "environment.AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE" = "/secrets/RESET_PASSWORD_JWT_SECRET"
    "environment.AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET_FILE" = "/secrets/OIDC_HMAC_SECRET"
    "environment.X_AUTHELIA_CONFIG_FILTERS" = "template"
  }, var.authelia_smtp == null ? {} : {
    "environment.AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE" = "/secrets/SMTP_PASSWORD"
  })

  # A changed config file on its mounted volume requires a process restart.
  # The SQLite database and secrets persist in separate volumes.
  lifecycle {
    replace_triggered_by = [terraform_data.authelia_configuration]
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
      "ipv4.address" = var.site.authelia_ip
    }
  }

  device {
    name = "authelia-config"
    type = "disk"
    properties = {
      path   = "/config"
      pool   = var.site.storage_pool
      source = incus_storage_volume.authelia_config.name
    }
  }

  device {
    name = "authelia-secrets"
    type = "disk"
    properties = {
      path     = "/secrets"
      pool     = var.site.storage_pool
      source   = incus_storage_volume.authelia_secrets.name
      readonly = "true"
    }
  }

  device {
    name = "authelia-data"
    type = "disk"
    properties = {
      path   = "/data"
      pool   = var.site.storage_pool
      source = incus_storage_volume.authelia_data.name
    }
  }
}
