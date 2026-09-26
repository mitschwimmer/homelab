locals {
  # Field names and destinations are public configuration. Values are fetched
  # after OpenTofu creates the volumes; they never enter plans or state.
  workload_fields = {
    # Keys are destination filenames; values are KV v2 field names.
    authelia = merge({ for field in [
      "session_secret", "storage_encryption_key", "reset_password_jwt_secret",
      "oidc_hmac_secret", "oidc_jwks", "grafana_client_secret_hash"
      ] : field => field }, { "users.yml" = "users_yml" },
    var.authelia_smtp == null ? {} : { "smtp_password" = "smtp_password" })
    grafana = { for field in ["client_secret", "admin_password", "secret_key"] : field => field }
    prometheus = var.incus_metrics == null ? {} : { for field in [
      "incus_server_cert", "incus_metrics_cert", "incus_metrics_key"
    ] : field => field }
  }

  workload_owners = {
    authelia   = { uid = 1000, gid = 1000 }
    grafana    = { uid = 472, gid = 0 }
    prometheus = { uid = 65534, gid = 65534 }
  }

  secret_workloads = { for service, fields in local.workload_fields : service => fields if length(fields) > 0 }
}

# Private persistent volumes can be populated while OCI instances are stopped
# and survive instance replacement. Their backups contain application secrets.
resource "incus_storage_volume" "workload_secrets" {
  for_each = local.secret_workloads
  name     = "${each.key}-secrets"
  pool     = var.site.storage_pool
  remote   = var.site.incus_remote
  config = {
    "initial.uid"  = tostring(local.workload_owners[each.key].uid)
    "initial.gid"  = tostring(local.workload_owners[each.key].gid)
    "initial.mode" = "0700"
  }
}

output "secret_deployment" {
  description = "Non-secret destinations consumed by scripts/deploy-secrets.py"
  value = {
    for service, fields in local.secret_workloads : service => {
      remote = var.site.incus_remote
      pool   = var.site.storage_pool
      volume = incus_storage_volume.workload_secrets[service].name
      uid    = local.workload_owners[service].uid
      gid    = local.workload_owners[service].gid
      fields = fields
    }
  }
}
