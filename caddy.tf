resource "incus_storage_volume" "caddy_etc" {
  name   = "caddy-etc"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote

  file {
    content     = templatefile("${path.module}/caddy/Caddyfile", {
      authelia_ip = var.site.authelia_ip
      base_domain = var.site.base_domain
      grafana_ip = var.site.grafana_ip
    })
    target_path = "/Caddyfile"
    mode        = "0644"
  }
}

resource "incus_storage_volume" "caddy_data" {
  name   = "caddy-data"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote
}

resource "incus_storage_volume" "caddy_runtime" {
  name   = "caddy-runtime"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote
}

resource "incus_instance" "caddy" {
  name     = "caddy"
  image    = "oci-docker:library/caddy:2"
  remote   = var.site.incus_remote
  profiles = []

  config = {
    "boot.autostart"        = "true"
    "user.caddyfile_sha256" = sha256(templatefile("${path.module}/caddy/Caddyfile", {
      authelia_ip = var.site.authelia_ip
      base_domain = var.site.base_domain
      grafana_ip = var.site.grafana_ip
    }))
  }

  # A volume file update does not make the running Caddy process reload.
  # Changing the environment entry makes the provider re-run this command.
  exec = {
    "reload-caddy" = {
      command = ["caddy", "reload", "--config", "/etc/caddy/Caddyfile"]
      environment = {
        CADDYFILE_SHA256 = sha256(templatefile("${path.module}/caddy/Caddyfile", {
          authelia_ip = var.site.authelia_ip
          base_domain = var.site.base_domain
          grafana_ip = var.site.grafana_ip
        }))
      }
      trigger = "on_change"
    }
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
      nictype = "macvlan"
      parent  = var.site.lan_parent
      hwaddr  = var.site.caddy_mac
    }
  }

  device {
    name = "eth1"
    type = "nic"
    properties = {
      network = var.site.private_bridge
    }
  }

  device {
    name = "caddy-etc"
    type = "disk"
    properties = {
      path   = "/etc/caddy"
      pool   = var.site.storage_pool
      source = incus_storage_volume.caddy_etc.name
    }
  }

  device {
    name = "caddy-data"
    type = "disk"
    properties = {
      path   = "/data"
      pool   = var.site.storage_pool
      source = incus_storage_volume.caddy_data.name
    }
  }

  device {
    name = "caddy-runtime"
    type = "disk"
    properties = {
      path   = "/config"
      pool   = var.site.storage_pool
      source = incus_storage_volume.caddy_runtime.name
    }
  }
}
