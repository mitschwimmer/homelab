locals {
  grafana_datasource_configuration = templatefile("${path.module}/grafana/datasources.yml.tftpl", {
    prometheus_ip = var.site.prometheus_ip
  })
}

resource "terraform_data" "grafana_provisioning" {
  triggers_replace = sha256(local.grafana_datasource_configuration)
}

resource "incus_storage_volume" "grafana_provisioning" {
  name   = "grafana-provisioning"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote

  file {
    content     = local.grafana_datasource_configuration
    target_path = "/datasources.yml"
    mode        = "0644"
  }
}

resource "incus_storage_volume" "grafana_data" {
  name   = "grafana-data"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote
  config = {
    "initial.uid"  = "472"
    "initial.gid"  = "0"
    "initial.mode" = "0700"
  }
}

resource "incus_instance" "grafana" {
  name     = "grafana"
  image    = "oci-docker:grafana/grafana:13.1.0"
  remote   = var.site.incus_remote
  profiles = []

  lifecycle {
    replace_triggered_by = [terraform_data.grafana_provisioning]
  }

  config = {
    "boot.autostart"                                               = "true"
    "boot.autorestart"                                             = "true"
    "oci.uid"                                                      = "472"
    "oci.gid"                                                      = "0"
    "environment.GF_SERVER_ROOT_URL"                               = "https://grafana.${var.site.base_domain}"
    "environment.GF_SECURITY_ADMIN_PASSWORD__FILE"                 = "/var/lib/homelab-secrets/admin_password"
    "environment.GF_SECURITY_SECRET_KEY__FILE"                     = "/var/lib/homelab-secrets/secret_key"
    "environment.GF_AUTH_BASIC_ENABLED"                            = "false"
    "environment.GF_AUTH_DISABLE_LOGIN_FORM"                       = "true"
    "environment.GF_AUTH_GENERIC_OAUTH_ENABLED"                    = "true"
    "environment.GF_AUTH_GENERIC_OAUTH_NAME"                       = "Authelia"
    "environment.GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN"                 = "true"
    "environment.GF_AUTH_GENERIC_OAUTH_CLIENT_ID"                  = "grafana-homelab"
    "environment.GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET__FILE"        = "/var/lib/homelab-secrets/client_secret"
    "environment.GF_AUTH_GENERIC_OAUTH_SCOPES"                     = "openid profile email groups"
    "environment.GF_AUTH_GENERIC_OAUTH_AUTH_URL"                   = "https://auth.${var.site.base_domain}/api/oidc/authorization"
    "environment.GF_AUTH_GENERIC_OAUTH_TOKEN_URL"                  = "https://auth.${var.site.base_domain}/api/oidc/token"
    "environment.GF_AUTH_GENERIC_OAUTH_API_URL"                    = "https://auth.${var.site.base_domain}/api/oidc/userinfo"
    "environment.GF_AUTH_GENERIC_OAUTH_LOGIN_ATTRIBUTE_PATH"       = "preferred_username"
    "environment.GF_AUTH_GENERIC_OAUTH_GROUPS_ATTRIBUTE_PATH"      = "groups"
    "environment.GF_AUTH_GENERIC_OAUTH_USE_PKCE"                   = "true"
    "environment.GF_AUTH_GENERIC_OAUTH_AUTH_STYLE"                 = "InHeader"
    "environment.GF_AUTH_GENERIC_OAUTH_ALLOWED_GROUPS"             = "admins"
    "environment.GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH"        = "contains(groups[*], 'admins') && 'GrafanaAdmin' || 'None'"
    "environment.GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_STRICT"      = "true"
    "environment.GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN" = "true"
    "environment.GF_METRICS_ENABLED"                               = "true"
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
      "ipv4.address" = var.site.grafana_ip
    }
  }

  device {
    name = "data"
    type = "disk"
    properties = {
      path   = "/var/lib/grafana"
      pool   = var.site.storage_pool
      source = incus_storage_volume.grafana_data.name
    }
  }

  device {
    name = "provisioning"
    type = "disk"
    properties = {
      path     = "/etc/grafana/provisioning/datasources"
      pool     = var.site.storage_pool
      source   = incus_storage_volume.grafana_provisioning.name
      readonly = "true"
    }
  }

  device {
    name = "secrets"
    type = "disk"
    properties = {
      path     = "/var/lib/homelab-secrets"
      pool     = var.site.storage_pool
      source   = incus_storage_volume.workload_secrets["grafana"].name
      readonly = "true"
    }
  }

}
