locals {
  prometheus_configuration = templatefile("${path.module}/prometheus/prometheus.yml.tftpl", {
    prometheus_ip             = var.site.prometheus_ip
    private_dns_domain        = var.site.private_dns_domain
    authelia_ip               = var.site.authelia_ip
    grafana_ip                = var.site.grafana_ip
    incus_metrics_enabled     = var.incus_metrics != null
    incus_metrics_target      = var.incus_metrics == null ? "" : var.incus_metrics.target
    incus_metrics_server_name = var.incus_metrics == null ? "" : var.incus_metrics.server_name
    extra_targets             = var.prometheus_extra_targets
  })
}

resource "terraform_data" "prometheus_configuration" {
  triggers_replace = sha256(local.prometheus_configuration)
}

resource "incus_storage_volume" "prometheus_config" {
  name   = "prometheus-config"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote

  file {
    content     = local.prometheus_configuration
    target_path = "/prometheus.yml"
    mode        = "0644"
  }

}

resource "incus_storage_volume" "prometheus_data" {
  name   = "prometheus-data"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote
  config = {
    "initial.uid"  = "65534"
    "initial.gid"  = "65534"
    "initial.mode" = "0700"
  }
}

resource "incus_instance" "prometheus" {
  name     = "prometheus"
  image    = "oci-docker:prom/prometheus:v3.12.0"
  remote   = var.site.incus_remote
  profiles = []

  config = {
    "boot.autostart"   = "true"
    "boot.autorestart" = "true"
    "oci.uid"          = "65534"
    "oci.gid"          = "65534"
  }

  lifecycle {
    replace_triggered_by = [terraform_data.prometheus_configuration]
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
      "ipv4.address" = var.site.prometheus_ip
    }
  }

  device {
    name = "config"
    type = "disk"
    properties = {
      path     = "/etc/prometheus"
      pool     = var.site.storage_pool
      source   = incus_storage_volume.prometheus_config.name
      readonly = "true"
    }
  }

  device {
    name = "data"
    type = "disk"
    properties = {
      path   = "/prometheus"
      pool   = var.site.storage_pool
      source = incus_storage_volume.prometheus_data.name
    }
  }

  dynamic "device" {
    for_each = var.incus_metrics == null ? [] : [1]
    content {
      name = "secrets"
      type = "disk"
      properties = {
        path     = "/var/lib/homelab-secrets"
        pool     = var.site.storage_pool
        source   = incus_storage_volume.workload_secrets["prometheus"].name
        readonly = "true"
      }
    }
  }
}
