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
    "boot.autorestart" = "true"
    "oci.entrypoint" = "/opt/platform/start-oci.sh"
    "environment.HOMELAB_SERVICE" = "authelia"
    "environment.HOMELAB_REQUIRED_SECRETS" = join(" ", local.workload_fields.authelia)
    "environment.AUTHELIA_SESSION_SECRET_FILE" = "/run/secrets/session_secret"
    "environment.AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE" = "/run/secrets/storage_encryption_key"
    "environment.AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE" = "/run/secrets/reset_password_jwt_secret"
    "environment.AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET_FILE" = "/run/secrets/oidc_hmac_secret"
    "environment.X_AUTHELIA_CONFIG_FILTERS" = "template"
  }, var.authelia_smtp == null ? {} : {
    "environment.AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE" = "/run/secrets/smtp_password"
  })

  # A changed config file on its mounted volume requires a process restart.
  # The SQLite database persists; application secrets are rendered to tmpfs.
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
    name = "agent-config"
    type = "disk"
    properties = {
      path     = "/etc/openbao"
      pool     = var.site.storage_pool
      source   = incus_storage_volume.workload_agent["authelia"].name
      readonly = "true"
    }
  }

  device {
    name = "auth"
    type = "disk"
    properties = {
      path   = "/var/lib/openbao-auth"
      pool   = var.site.storage_pool
      source = incus_storage_volume.workload_auth["authelia"].name
    }
  }

  device {
    name = "tools"
    type = "disk"
    properties = {
      path = "/opt/platform"
      pool = var.site.storage_pool
      source = incus_storage_volume.platform_tools.name
      readonly = "true"
    }
  }

  device {
    name = "runtime-secrets"
    type = "disk"
    properties = {
      path = "/run/secrets"
      source = "tmpfs:"
      size = "1MiB"
      "initial.uid" = "0"
      "initial.gid" = "0"
      "initial.mode" = "0700"
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
