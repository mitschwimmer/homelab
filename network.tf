data "incus_network" "private" {
  name   = var.site.private_bridge
  remote = var.site.incus_remote
}

locals {
  private_bridge_cidr = data.incus_network.private.config["ipv4.address"]
  private_ips = {
    for service, host_number in var.site.private_host_numbers :
    service => cidrhost(local.private_bridge_cidr, host_number)
  }
}

output "private_addresses" {
  description = "Computed service addresses on the current Incus bridge. Verify they are unallocated before applying."
  value       = local.private_ips
}
