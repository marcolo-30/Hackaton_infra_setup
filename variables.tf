variable "vm_names" {
  description = "Names for the VMs"
  type        = list(string)
  default = [
    #"group1-continuum",
    #"group1-cluster", "group1-node1", "group1-node2",
    #"group2-continuum",
    #"group2-cluster", "group2-node1", "group2-node2",
    #"group3-continuum",
    #"group3-cluster", "group3-node1","group3-node2",
    #"group4-continuum",
    #"group4-cluster", "group4-node1","group4-node2",
    #"group5-continuum",
    #"group5-cluster", "group5-node1","group5-node2",
    #"group6-continuum",
    #"group6-cluster", "group6-node1","group6-node2"
    #"group7-continuum",
    #"group7-cluster", "group7-node1","group7-node2",

  ]
}

variable "hcloud_token" {
  description = "Hetzner API token"
  type        = string
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Path to ssh"
  type        = string
}
