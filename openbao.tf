locals {
  openbao_server_configuration = templatefile("${path.module}/openbao/server.hcl.tftpl", {
    openbao_ip = var.site.openbao_ip
  })
}

resource "incus_storage_volume" "openbao_config" {
  name   = "openbao-config"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote

  file {
    content     = local.openbao_server_configuration
    target_path = "/server.hcl"
    mode        = "0644"
  }
}

resource "incus_storage_volume" "openbao_data" {
  name   = "openbao-data"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote
  config = {
    "initial.uid"  = "900"
    "initial.gid"  = "900"
    "initial.mode" = "0700"
  }
}

resource "incus_instance" "openbao" {
  name     = "openbao"
  image    = "oci-docker:openbao/openbao:2.7.0"
  remote   = var.site.incus_remote
  profiles = []

  config = {
    "boot.autostart"          = "true"
    "boot.autostart.priority" = "20"
    "boot.autorestart"        = "true"
    # Override the upstream image's development-mode CMD with a production server.
    "oci.entrypoint" = "/usr/bin/bao server -config=/etc/openbao/server.hcl"
    "oci.uid"        = "900"
    "oci.gid"        = "900"
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
      "ipv4.address" = var.site.openbao_ip
    }
  }

  device {
    name = "config"
    type = "disk"
    properties = {
      path     = "/etc/openbao"
      pool     = var.site.storage_pool
      source   = incus_storage_volume.openbao_config.name
      readonly = "true"
    }
  }

  device {
    name = "data"
    type = "disk"
    properties = {
      path   = "/var/lib/openbao"
      pool   = var.site.storage_pool
      source = incus_storage_volume.openbao_data.name
    }
  }
}
