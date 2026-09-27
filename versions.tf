terraform {
  required_version = ">= 1.7.0"

  encryption {
    key_provider "pbkdf2" "homelab" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "homelab" {
      keys = key_provider.pbkdf2.homelab
    }
    state {
      method   = method.aes_gcm.homelab
      enforced = true
    }
    plan {
      method   = method.aes_gcm.homelab
      enforced = true
    }
  }

  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "~> 1.2"
    }
  }
}

provider "incus" {
  default_remote = var.site.incus_remote

  # Uses the pre-authenticated client-side Incus remote.
  remote {
    name = var.site.incus_remote
  }

  remote {
    name     = "oci-docker"
    address  = "https://docker.io"
    protocol = "oci"
    public   = true
  }

  remote {
    name     = "images"
    address  = "https://images.linuxcontainers.org"
    protocol = "simplestreams"
    public   = true
  }
}
