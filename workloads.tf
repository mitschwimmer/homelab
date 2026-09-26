locals {
  workload_fields = {
    authelia = concat([
      "session_secret", "storage_encryption_key", "reset_password_jwt_secret",
      "users.yml", "oidc_hmac_secret", "oidc_jwks", "grafana_client_secret_hash"
    ], var.authelia_smtp == null ? [] : ["smtp_password"])
    grafana = ["client_secret", "admin_password", "secret_key"]
    prometheus = concat(["agent_ready"], var.incus_metrics == null ? [] : [
      "incus_server_cert", "incus_metrics_cert", "incus_metrics_key"
    ])
  }

  workload_uids = {
    authelia   = 0
    grafana    = 472
    prometheus = 65534
  }
}

# Every application has separate bootstrap material and Agent configuration.
# These volumes hold role IDs, SecretIDs and the server CA only after the
# operator enrolls them directly through Incus; OpenTofu never sees their bytes.
resource "incus_storage_volume" "workload_auth" {
  for_each = local.workload_fields
  name     = "${each.key}-openbao-auth"
  pool     = var.site.storage_pool
  remote   = var.site.incus_remote
  config = {
    "initial.uid"  = tostring(local.workload_uids[each.key])
    "initial.gid"  = tostring(local.workload_uids[each.key])
    "initial.mode" = "0700"
  }
}

resource "incus_storage_volume" "workload_agent" {
  for_each = local.workload_fields
  name     = "${each.key}-openbao-agent"
  pool     = var.site.storage_pool
  remote   = var.site.incus_remote

  file {
    content = templatefile("${path.module}/openbao/agent.hcl.tftpl", {
      openbao_ip = var.site.openbao_ip
      templates = join("\n", [for field in each.value : <<-EOT
        template {
          contents = "{{ with secret \"kv/data/${each.key}\" }}{{ .Data.data.${replace(field, ".", "_")} }}{{ end }}"
          destination = "/run/secrets/${field}"
          perms = "0400"
          error_on_missing_key = true
        }
      EOT
      ])
    })
    target_path = "/agent.hcl"
    mode        = "0444"
  }
}
