resource "incus_storage_volume" "caddy_etc" {
  name   = "caddy-etc"
  pool   = "local"
  remote = "IncusOS"

  file {
    content     = templatefile("${path.module}/caddy/Caddyfile", {
      authelia_ip = var.authelia_bridge_ip
    })
    target_path = "/Caddyfile"
    mode        = "0644"
  }
}

resource "incus_storage_volume" "caddy_data" {
  name   = "caddy-data"
  pool   = "local"
  remote = "IncusOS"
}

resource "incus_storage_volume" "caddy_runtime" {
  name   = "caddy-runtime"
  pool   = "local"
  remote = "IncusOS"
}

resource "incus_instance" "caddy" {
  name     = "caddy"
  image    = "oci-docker:library/caddy:2"
  remote   = "IncusOS"
  profiles = []

  config = {
    "boot.autostart"        = "true"
    "user.caddyfile_sha256" = sha256(templatefile("${path.module}/caddy/Caddyfile", {
      authelia_ip = var.authelia_bridge_ip
    }))
  }

  # A volume file update does not make the running Caddy process reload.
  # Changing the environment entry makes the provider re-run this command.
  exec = {
    "reload-caddy" = {
      command = ["caddy", "reload", "--config", "/etc/caddy/Caddyfile"]
      environment = {
        CADDYFILE_SHA256 = sha256(templatefile("${path.module}/caddy/Caddyfile", {
          authelia_ip = var.authelia_bridge_ip
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
      pool = "local"
    }
  }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      nictype = "macvlan"
      parent  = "enp129s0"
      hwaddr  = "02:00:00:ca:dd:01"
    }
  }

  device {
    name = "eth1"
    type = "nic"
    properties = {
      network = "incusbr0"
    }
  }

  device {
    name = "caddy-etc"
    type = "disk"
    properties = {
      path   = "/etc/caddy"
      pool   = "local"
      source = incus_storage_volume.caddy_etc.name
    }
  }

  device {
    name = "caddy-data"
    type = "disk"
    properties = {
      path   = "/data"
      pool   = "local"
      source = incus_storage_volume.caddy_data.name
    }
  }

  device {
    name = "caddy-runtime"
    type = "disk"
    properties = {
      path   = "/config"
      pool   = "local"
      source = incus_storage_volume.caddy_runtime.name
    }
  }
}
