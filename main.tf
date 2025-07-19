###############################################################
# main.tf  –  Hetzner VMs + auto-generated Ansible inventory
###############################################################

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

#######################
# 1.  Provider & SSH key
#######################
provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_ssh_key" "default" {
  name       = "mlsysops-key"
  public_key = file(var.ssh_public_key_path)
}


#######################
# 2.  Private LAN (optional but handy)
#######################
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

#######################
# 3.  Deterministic private IPs
#######################
locals {
  # 10.0.0.10, .11, .12, … (one per VM)
  fixed_ips = {
    for idx, name in var.vm_names :
    name => cidrhost("10.0.0.0/24", idx + 10)
  }
}

#######################
# 4.  VM deployment
#######################
resource "hcloud_server" "vm" {
  count       = length(var.vm_names)
  name        = var.vm_names[count.index]
  image       = "ubuntu-22.04"
  server_type = "cx22"
  location    = "fsn1"
  ssh_keys    = [hcloud_ssh_key.default.id]

  # Attach to the LAN with its fixed private address
  network {
    network_id = hcloud_network.lan.id
    ip         = local.fixed_ips[var.vm_names[count.index]]
  }

  # Only the “-continuum” VM gets a public IPv4
  #dynamic "public_net" {
  #  for_each = endswith(var.vm_names[count.index], "-continuum") ? [1] : []
  #  content {
  #    ipv4_enabled = true
  #    ipv6_enabled = false
  #  }
  #}


  # Inside resource "hcloud_server" "vm" { … }
  public_net {
    ipv4_enabled = true # ← each VM gets its own public IPv4
    ipv6_enabled = false
  }


  # cloud-init
  user_data = templatefile("${path.module}/cloud-init.yaml", {
    public_key = file(var.ssh_public_key_path)
  })
}

#######################
# 5.  Build the inventory data in locals (DYNAMIC VERSION)
#######################
locals {
  # 5a. Extraer los prefijos de grupo (ej: "group1", "group2") de forma única
  group_names = distinct([
    for name in var.vm_names : split("-", name)[0]
  ])

  # Public + private IPs for every VM (esto no cambia)
  server_ips = {
    for vm in hcloud_server.vm :
    vm.name => {
      public  = vm.ipv4_address
      private = local.fixed_ips[vm.name]
    }
  }

  # 5b. Encontrar el management host dinámicamente
  # Crea una lista de todos los nodos "-continuum" y selecciona el primero como el principal.
  management_vm_name = [
    for name in var.vm_names : name if endswith(name, "-continuum")
  ][0] # <-- Selecciona el primer elemento de la lista

  management_host = {
    name = local.management_vm_name
    ip   = local.server_ips[local.management_vm_name].public
  }

  # 5c. Generar la lista de clusters dinámicamente
  clusters = [
    for idx, group in local.group_names : {
      name = "cluster${idx + 1}" # ej: cluster1, cluster2

      master = {
        name     = "${group}-cluster"
        ip       = local.server_ips["${group}-cluster"].public
        k3s_name = "${group}-cluster"
        # CIDRs dinámicos para evitar solapamientos entre clusters
        pod_cidr     = "10.${12 + idx}.0.0/16"
        service_cidr = "10.${100 + idx}.0.0/16"
      }

      workers = [
        for n in var.vm_names : {
          name = n
          ip   = local.server_ips[n].public
        } if startswith(n, "${group}-node") # Encuentra workers por prefijo
      ]
    }
  ]

  # 5d. Renderizar el inventario (esto no cambia)
  rendered_inventory = templatefile(
    "${path.module}/template_inventory.tftpl",
    {
      management   = local.management_host
      clusters     = local.clusters
      ansible_user = "mlsysops"
    }
  )
}

#######################
# 6.  Write inventory.yaml
#######################
resource "local_file" "inventory" {
  filename = "${path.module}/inventory.yml"
  content  = local.rendered_inventory
}

#######################
# 7.  Helpful output
#######################
output "inventory_file" {
  value       = local_file.inventory.filename
  description = "Path to the generated Ansible inventory"
}
