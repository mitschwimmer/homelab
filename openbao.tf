locals {
  openbao_server_configuration = templatefile("${path.module}/openbao/server.hcl.tftpl", {
    openbao_ip = var.site.openbao_ip
  })
}

# A versioned, operator-verified binary is copied into this non-secret volume.
# Changing platform_tools_directory to a new versioned path is an explicit upgrade.
resource "incus_storage_volume" "platform_tools" {
  name   = "platform-tools-openbao-2-7-0"
  pool   = var.site.storage_pool
  remote = var.site.incus_remote

  file {
    source_path = "${var.platform_tools_directory}/bao"
    target_path = "/bao"
    mode        = "0755"
  }

  file {
    source_path = "${path.module}/openbao/start-oci.sh"
    target_path = "/start-oci.sh"
    mode        = "0755"
  }
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
  image    = "images:debian/13/cloud"
  remote   = var.site.incus_remote
  profiles = []

  config = {
    "boot.autostart"          = "true"
    "boot.autostart.priority" = "20"
    "cloud-init.user-data" = templatefile("${path.module}/openbao/cloud-init.yml.tftpl", {
      openbao_ip = var.site.openbao_ip
    })
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
    name = "tools"
    type = "disk"
    properties = {
      path     = "/opt/platform"
      pool     = var.site.storage_pool
      source   = incus_storage_volume.platform_tools.name
      readonly = "true"
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
