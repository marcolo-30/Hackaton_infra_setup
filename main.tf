#################################################################
# main.tf – Hetzner VMs + auto-generated Ansible inventory
#################################################################

terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

#############################
# 1. Provider & SSH Key
#############################
provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_ssh_key" "default" {
  name       = "mlsysops-key"
  public_key = file(var.ssh_public_key_path)
}

#############################
# 2. Private LAN
#############################
resource "hcloud_network" "lan" {
  name     = "mlsysops-net"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "lan_subnet" {
  network_id   = hcloud_network.lan.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.0.0/24"
}

##############################################
# 3. Server Types & Deterministic Private IPs
##############################################
locals {
  # Map VM roles to specific server types.
  # This assumes your vm_names are like "groupx-role", e.g., "group1-continuum".
  vm_server_types = {
    #"continuum" = "cx32"
    #"cluster"   = "cx32"
    #"node1"     = "ccx23"
    #"node2"     = "ccx33"
    "continuum" = "cx22"
    "cluster"   = "cx22"
    "node1"     = "cx22"
    "node2"     = "cx22"
  }

  # A default server type for any VMs not defined above.
  default_server_type = "cx22"

  # Role-based fixed private IPs (safe since you deploy one group at a time).
  # - *-continuum → 10.0.0.10
  # - *-cluster   → 10.0.0.11
  # - *-node1     → 10.0.0.12
  # - *-node2     → 10.0.0.14
  # Any other role falls back to a deterministic address to avoid collisions
  # with the hand-picked addresses in .10-.14
  fixed_ips = {
    for idx, name in var.vm_names : name =>
    (
      endswith(name, "-continuum") ? "10.0.0.10" :
      endswith(name, "-cluster")   ? "10.0.0.11" :
      endswith(name, "-node1")     ? "10.0.0.12" :
      endswith(name, "-node2")     ? "10.0.0.14" :
      cidrhost("10.0.0.0/24", idx + 20)
    )
  }
}

#############################
# 4. VM Deployment
#############################
resource "hcloud_server" "vm" {
  count  = length(var.vm_names)
  name   = var.vm_names[count.index]
  image  = "ubuntu-22.04"

  # Dynamically look up the server type.
  server_type = lookup(
    local.vm_server_types,
    split("-", var.vm_names[count.index])[1], # role (e.g., "node1")
    local.default_server_type                 # fallback if role not found
  )

  #location    = "hel1"
  #location    = "fsn1"
  location    = "nbg1"
  ssh_keys    = [hcloud_ssh_key.default.id]

  # Attach to the LAN with its fixed private address
  network {
    network_id = hcloud_network.lan.id
    ip         = local.fixed_ips[var.vm_names[count.index]]
  }

  # Each VM gets its own public IPv4
  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  # Use cloud-init for initial server setup
  user_data = templatefile("${path.module}/cloud-init.yaml", {
    public_key = file(var.ssh_public_key_path)
  })
}

#############################
# 5. Build Inventory Data
#############################
locals {
  # 5a. Extract unique group prefixes (e.g., "group1", "group2") from VM names
  group_names = distinct([
    for name in var.vm_names : split("-", name)[0]
  ])

  # 5b. Map each VM name to its public and private IPs
  server_ips = {
    for vm in hcloud_server.vm :
    vm.name => {
      public  = vm.ipv4_address
      private = local.fixed_ips[vm.name]
    }
  }

  # 5c. Dynamically find the management host (first *-continuum VM)
  management_vm_name = one([
    for name in var.vm_names : name if endswith(name, "-continuum")
  ])

  management_host = {
    name = local.management_vm_name
    ip   = local.server_ips[local.management_vm_name].public
  }

  # 5d. Dynamically generate the list of clusters
  clusters = [
    for idx, group in local.group_names : {
      name = "cluster${idx + 1}" # e.g., cluster1, cluster2

      master = {
        name       = "${group}-cluster"
        ip         = local.server_ips["${group}-cluster"].public
        k3s_name   = "${group}-cluster"

        # Dynamic CIDRs to avoid overlaps between clusters
        pod_cidr     = "10.${12 + idx}.0.0/16"
        service_cidr = "10.${100 + idx}.0.0/16"
      }

      workers = [
        for n in var.vm_names : {
          name = n
          ip   = local.server_ips[n].public
        } if startswith(n, "${group}-node") # Find workers by their name prefix
      ]
    }
  ]

  # 5e. Render the inventory file content from the template
  rendered_inventory = templatefile(
    "${path.module}/template_inventory.tftpl",
    {
      management   = local.management_host
      clusters     = local.clusters
      ansible_user = "mlsysops"
    }
  )
}

#############################
# 6. Write inventory.yml
#############################
resource "local_file" "inventory" {
  filename = "${path.module}/inventory.yml"
  content  = local.rendered_inventory
}

#############################
# 7. Outputs
#############################
output "inventory_file_path" {
  value       = local_file.inventory.filename
  description = "Path to the generated Ansible inventory file."
}

output "management_host_ip" {
  value       = local.management_host.ip
  description = "Public IP address of the management host."
}
