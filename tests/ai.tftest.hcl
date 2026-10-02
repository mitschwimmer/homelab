mock_provider "incus" {
  mock_data "incus_network" {
    defaults = { config = { "ipv4.address" = "10.20.4.1/24" } }
  }
}

variables {
  site = {
    incus_remote         = "test"
    storage_pool         = "local"
    private_bridge       = "incusbr0"
    lan_parent           = "eth0"
    caddy_mac            = "02:00:00:ca:dd:01"
    private_host_numbers = { authelia = 10, prometheus = 11, grafana = 12 }
    private_dns_domain   = "incus"
    base_domain          = "example.test"
  }
  state_passphrase = "test-only-encryption-passphrase"
  workload_secrets = {
    authelia = {
      session_secret   = "test", storage_encryption_key = "test", reset_password_jwt_secret = "test",
      oidc_hmac_secret = "test", oidc_jwks = "test", grafana_client_secret_hash = "test",
      users_yml        = "test", openwebui_client_secret_hash = "test"
    }
    grafana   = { client_secret = "test", admin_password = "test", secret_key = "test" }
    openwebui = { client_secret = "test", secret_key = "test" }
  }
}

run "existing_site_without_pi" {
  command = plan
  assert {
    condition     = length(incus_instance.pi) == 0 && !strcontains(local.caddy_configuration, "pi.example.test")
    error_message = "Pi must remain optional for existing installations."
  }
}

run "shared_ai_services" {
  command = plan
  variables {
    llama = {
      enabled = true, host_number = 13, storage_pool = "local",
      gpu_pci = "0000:01:00.0"
    }
    openwebui = { hostname = "ai.other.test", host_number = 14 }
    pi        = { host_number = 15 }
  }
  assert {
    condition     = incus_instance.pi[0].type == "virtual-machine" && local.private_ips.pi == "10.20.4.15"
    error_message = "Pi must be a VM on the shared workload bridge."
  }
  assert {
    condition     = strcontains(local.caddy_configuration, "pi.example.test") && strcontains(local.caddy_configuration, "/api/authz/forward-auth")
    error_message = "Pi must be protected by Authelia ForwardAuth."
  }
  assert {
    condition     = strcontains(local.authelia_configuration, "authorization_policy: ai_users") && strcontains(local.authelia_configuration, "subject: 'group:ai-users'")
    error_message = "AI frontends must use the ai-users group."
  }
  assert {
    condition     = incus_instance.openwebui[0].config["environment.OAUTH_ALLOWED_ROLES"] == "ai-users" && incus_instance.openwebui[0].config["environment.OAUTH_ADMIN_ROLES"] == "admins"
    error_message = "Ordinary AI access and Open WebUI administration must have independent groups."
  }
  assert {
    condition     = local.pi_models.providers.homelab.baseUrl == "http://10.20.4.13:8080/v1" && [for model in local.pi_models.providers.homelab.models : model.id] == local.llama_model_names && alltrue([for model in local.pi_models.providers.homelab.models : model.contextWindow >= 32768])
    error_message = "Pi must use the router preset IDs, endpoint and context limits."
  }
}

run "reject_cross_domain_forward_auth" {
  command = plan
  variables {
    llama = {
      enabled = true, host_number = 13, storage_pool = "local",
      gpu_pci = "0000:01:00.0"
    }
    pi = { host_number = 15, hostname = "pi.other.test" }
  }
  expect_failures = [incus_instance.pi]
}

run "reject_colliding_addresses" {
  command = plan
  variables {
    llama = {
      enabled = true, host_number = 13, storage_pool = "local",
      gpu_pci = "0000:01:00.0"
    }
    pi = { host_number = 13 }
  }
  expect_failures = [incus_instance.pi]
}
