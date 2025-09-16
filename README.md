# Hackaton Infra Setup

This repository automates the setup of the **MLSysOps Hackaton environment** using Terraform, Ansible, and the MLSysOps CLI.

The included `script.sh` provisions the infrastructure, installs K3s and Karmada, bootstraps the MLSysOps CLI on the remote host, and fetches back the `karmada-kubeconfig.yaml` file for local use.

---

## 🚀 Quick Start

### 1. Clone this repository
```bash
git clone https://github.com/marcolo-30/Hackaton_infra_setup.git
cd Hackaton_infra_setup
git submodule update --init --recursive
```

### 2. Make sure dependencies are installed
On your **local machine**, you need:

- [Terraform](https://developer.hashicorp.com/terraform/downloads)  
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html)  
- SSH key access to the provisioned VM (`mlsysops` user)

Check with:
```bash
terraform -version
ansible --version
```

If either is missing, install them before continuing.

### 3. Run the setup script
```bash
chmod +x script.sh
./script.sh
```

The script will:
1. Run `terraform apply` and create infrastructure.
2. Parse `inventory.yml` to extract the IP of `group1-continuum`.
3. Run Ansible to install K3s and Karmada on the new nodes.
4. Bootstrap the MLSysOps CLI on the remote host.
5. Copy the generated `karmada-kubeconfig.yaml` back to your local machine.

---

## 📂 Outputs

After successful execution you will have:

- **.karmada_host_ip** → contains the remote host IP.  
- **karmada-kubeconfig.yaml** → local kubeconfig to interact with Karmada.  

Example:
```bash
export KUBECONFIG=./karmada-kubeconfig.yaml
kubectl get nodes
```

---

## ⚠️ Notes

- The script will **stop on error** and print the step that failed.  
- On fresh VMs, APT locks may delay package installation — the script includes retries to handle this.  

---

## 🛡️ Disclaimer

This repo provisions and configures remote infrastructure.  
Use only in **test or hackathon environments** unless you know exactly what you are doing.
