resource "incus_storage_volume" "openwebui_data" {
  count  = var.openwebui == null ? 0 : 1
  name   = "openwebui-data"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote
  config = {
    "initial.uid"  = "0"
    "initial.gid"  = "0"
    "initial.mode" = "0700"
  }

  lifecycle {
    prevent_destroy = true
    precondition {
      condition = !contains(values(var.site.private_host_numbers), var.openwebui.host_number) && (
        var.llama == null ? true : var.openwebui.host_number != var.llama.host_number
      )
      error_message = "Open WebUI needs a private host number distinct from all other workloads."
    }
    precondition {
      condition     = var.llama == null ? false : var.llama.enabled
      error_message = "Configure and enable the llama.cpp workload before adding Open WebUI."
    }
    precondition {
      condition = !contains([
        "auth.${var.site.base_domain}", "grafana.${var.site.base_domain}"
      ], var.openwebui.hostname)
      error_message = "Open WebUI must use a hostname distinct from Authelia and Grafana."
    }
  }
}

resource "incus_storage_volume" "openwebui_config" {
  count  = var.openwebui == null ? 0 : 1
  name   = "openwebui-config"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote
  config = {
    "initial.mode" = "0755"
  }
  file {
    target_path = "/start.sh"
    content     = file("${path.module}/openwebui/start.sh")
    mode        = "0555"
  }
}

resource "terraform_data" "openwebui_startup" {
  count            = var.openwebui == null ? 0 : 1
  triggers_replace = sha256(file("${path.module}/openwebui/start.sh"))
}

resource "incus_instance" "openwebui" {
  count    = var.openwebui == null ? 0 : 1
  name     = "openwebui"
  image    = "oci-ghcr:open-webui/open-webui:v0.11.4"
  remote   = var.site.incus_remote
  profiles = []

  # Match the upstream image's root process inside an unprivileged container.
  config = {
    "boot.autostart"                               = "true"
    "boot.autorestart"                             = "true"
    "oci.entrypoint"                               = "/bin/sh /etc/homelab-openwebui/start.sh"
    "oci.uid"                                      = "0"
    "oci.gid"                                      = "0"
    "environment.WEBUI_URL"                        = "https://${var.openwebui.hostname}"
    "environment.WEBUI_AUTH"                       = "true"
    "environment.WEBUI_SESSION_COOKIE_SECURE"      = "true"
    "environment.WEBUI_AUTH_COOKIE_SECURE"         = "true"
    "environment.ENABLE_LOGIN_FORM"                = "false"
    "environment.ENABLE_PASSWORD_AUTH"             = "false"
    "environment.ENABLE_SIGNUP"                    = "false"
    "environment.ENABLE_OAUTH_SIGNUP"              = "true"
    "environment.ENABLE_OAUTH"                     = "true"
    "environment.OAUTH_CLIENT_ID"                  = "openwebui-homelab"
    "environment.OAUTH_PROVIDER_NAME"              = "Authelia"
    "environment.OPENID_PROVIDER_URL"              = "https://auth.${var.site.base_domain}/.well-known/openid-configuration"
    "environment.OPENID_REDIRECT_URI"              = "https://${var.openwebui.hostname}/oauth/oidc/callback"
    "environment.OAUTH_SCOPES"                     = "openid profile email groups"
    "environment.OAUTH_CODE_CHALLENGE_METHOD"      = "S256"
    "environment.OAUTH_TOKEN_ENDPOINT_AUTH_METHOD" = "client_secret_basic"
    "environment.ENABLE_OAUTH_ROLE_MANAGEMENT"     = "true"
    "environment.OAUTH_ROLES_CLAIM"                = "groups"
    "environment.OAUTH_ALLOWED_ROLES"              = "admins"
    "environment.OAUTH_ADMIN_ROLES"                = "admins"
    "environment.OAUTH_MERGE_ACCOUNTS_BY_EMAIL"    = "false"
    "environment.ENABLE_PERSISTENT_CONFIG"         = "false"
    "environment.ENABLE_OLLAMA_API"                = "false"
    "environment.ENABLE_OPENAI_API"                = "true"
    "environment.OPENAI_API_BASE_URL"              = "http://${try(local.private_ips.llama, "127.0.0.1")}:8080/v1"
    # The image defaults OPENAI_API_KEY to empty. Incus removes empty config
    # values, so explicitly setting it causes a provider consistency error.
    "environment.CORS_ALLOW_ORIGIN"   = "https://${var.openwebui.hostname}"
    "environment.FORWARDED_ALLOW_IPS" = "${local.private_bridge_cidr}"
  }

  lifecycle {
    replace_triggered_by = [terraform_data.openwebui_startup]
  }

  device {
    name       = "root"
    type       = "disk"
    properties = { path = "/", pool = var.site.storage_pool }
  }
  device {
    name = "eth0"
    type = "nic"
    properties = {
      network        = var.site.private_bridge
      "ipv4.address" = local.private_ips.openwebui
    }
  }
  device {
    name = "data"
    type = "disk"
    properties = {
      path   = "/app/backend/data"
      pool   = var.site.storage_pool
      source = incus_storage_volume.openwebui_data[0].name
    }
  }
  device {
    name = "config"
    type = "disk"
    properties = {
      path     = "/etc/homelab-openwebui"
      pool     = var.site.storage_pool
      source   = incus_storage_volume.openwebui_config[0].name
      readonly = "true"
    }
  }
  device {
    name = "secrets"
    type = "disk"
    properties = {
      path     = "/var/lib/homelab-secrets"
      pool     = var.site.storage_pool
      source   = incus_storage_volume.workload_secrets["openwebui"].name
      readonly = "true"
    }
  }
}
