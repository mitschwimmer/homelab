terraform {
  required_version = ">= 1.7.0"

  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "~> 1.2"
    }
  }
}

provider "incus" {
  default_remote = "IncusOS"

  # Uses the pre-authenticated client-side Incus remote.
  remote {
    name = "IncusOS"
  }

  remote {
    name     = "oci-docker"
    address  = "https://docker.io"
    protocol = "oci"
    public   = true
  }
}
