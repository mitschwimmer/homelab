mock_provider "incus" {
  mock_data "incus_network" {
    defaults = { config = { "ipv4.address" = "10.20.4.1/24" } }
  }
}

variables {
  state_passphrase = "test-only-state-passphrase"
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
  workload_secrets = {
    authelia = {
      session_secret             = "test"
      storage_encryption_key     = "test"
      reset_password_jwt_secret  = "test"
      oidc_hmac_secret           = "test"
      oidc_jwks                  = "test"
      grafana_client_secret_hash = "test"
      users_yml                  = "test"
    }
    grafana = { client_secret = "test", admin_password = "test", secret_key = "test" }
  }
}

run "optional_workload" {
  command = plan
  assert {
    condition = (
      length(incus_instance.llama) == 0 &&
      length(incus_storage_volume.llama_cache) == 0 &&
      !strcontains(local.prometheus_configuration, "job_name: llama")
    )
    error_message = "An omitted llama workload must not create cache/instances or scrape targets."
  }
}

run "router_with_downloads" {
  command = plan
  variables {
    llama = {
      enabled      = true
      host_number  = 13
      storage_pool = "models"
      gpu_pci      = "0000:03:00.0"
    }
  }
  assert {
    condition = (
      incus_instance.llama[0].config["environment.LLAMA_ARG_MODELS_MAX"] == "1" &&
      !contains(keys(incus_instance.llama[0].config), "environment.LLAMA_ARG_MODEL") &&
      !contains(keys(incus_instance.llama[0].config), "environment.LLAMA_ARG_CTX_SIZE") &&
      !contains(keys(incus_instance.llama[0].config), "environment.LLAMA_ARG_SPEC_TYPE")
    )
    error_message = "Router must limit residency and leave model selection/context/MTP to presets."
  }
  assert {
    condition = (
      incus_storage_volume.llama_cache[0].config["initial.uid"] == "1000" &&
      incus_storage_volume.llama_cache[0].pool == "models" &&
      one([for d in incus_instance.llama[0].device : d if d.name == "cache"]).properties["path"] == incus_instance.llama[0].config["environment.LLAMA_CACHE"] &&
      !contains(keys(one([for d in incus_instance.llama[0].device : d if d.name == "cache"]).properties), "readonly") &&
      one([for d in incus_instance.llama[0].device : d if d.name == "models"]).properties["readonly"] == "true"
    )
    error_message = "Downloads need a writable UID-1000 persistent cache while uploaded models stay read-only."
  }
  assert {
    condition = (
      join(",", local.llama_model_names) == "mimo,qwen36" &&
      strcontains(local.llama_presets, "hf-file = MiMo-V2.6-Distill-Qwen-9B-Q5_K_M.gguf") &&
      strcontains(local.llama_presets, "hf-file = Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf") &&
      !strcontains(local.llama_presets, "[local]")
    )
    error_message = "Fresh installations must select exact download files without a legacy preset."
  }
  assert {
    condition = (
      strcontains(local.prometheus_configuration, "autoload: ['false']") &&
      strcontains(local.prometheus_configuration, "target_label: __param_model") &&
      strcontains(local.prometheus_configuration, "model: \"mimo\"") &&
      strcontains(local.prometheus_configuration, "model: \"qwen36\"")
    )
    error_message = "Monitoring must route by model without loading idle models."
  }
}

run "retain_existing_local_model" {
  command = plan
  variables {
    llama = {
      enabled          = true
      host_number      = 13
      storage_pool     = "models"
      gpu_pci          = "0000:03:00.0"
      model_file       = "Qwen3.8-27B-i1-IQ4_XS-GGUF-Smaller.gguf"
      context_size     = 49152
      speculative_type = "draft-mtp"
      draft_max        = 2
      reasoning_effort = "medium"
    }
  }
  assert {
    condition = (
      contains(local.llama_model_names, "local") &&
      strcontains(local.llama_presets, "model = /models/Qwen3.8-27B-i1-IQ4_XS-GGUF-Smaller.gguf") &&
      strcontains(local.llama_presets, "ctx-size = 49152") &&
      strcontains(local.llama_presets, "spec-type = draft-mtp") &&
      strcontains(local.llama_presets, "\"reasoning_effort\":\"medium\"")
    )
    error_message = "Existing tfvars must retain their local GGUF and tuning without becoming router-wide defaults."
  }
}

run "reject_ini_injection" {
  command = plan
  variables {
    llama = {
      enabled      = true
      host_number  = 13
      storage_pool = "models"
      gpu_pci      = "0000:03:00.0"
      model_file   = "model.gguf\n[extra]\nmodel = other.gguf"
    }
  }
  expect_failures = [var.llama]
}
