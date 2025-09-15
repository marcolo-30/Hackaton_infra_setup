#!/usr/bin/env bash
set -Eeuo pipefail

# ===== Config =====
HOST_KEY="group1-continuum"        # The inventory host whose IP we need
REMOTE_USER="mlsysops"             # SSH user on the remote
REMOTE_HOME="/home/${REMOTE_USER}" # Remote home dir

# ===== Helpers =====
TOTAL_STEPS=8
STEP=0

handle_error() {
  echo "❌ ERROR: Script failed at step: $1"
  echo "⏱️ End time: $(date '+%Y-%m-%d %H:%M:%S')"
  exit 1
}

show_progress() {
  echo "✅ [$1%] $2 completed"
}

percent() {
  echo $(( $1 * 100 / TOTAL_STEPS ))
}

run_with_retries() {
  local cmd="$1"
  local retries="$2"
  local sleep_s="$3"

  local attempt=1
  while true; do
    echo "▶️  Attempt ${attempt}/${retries}: ${cmd}"
    set +e
    eval "${cmd}"
    local rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
      return 0
    fi

    if (( attempt >= retries )); then
      echo "❌ Command failed after ${retries} attempts: ${cmd}"
      return $rc
    fi

    echo "⏳ Likely transient issue. Waiting ${sleep_s}s before retry..."
    sleep "${sleep_s}"
    attempt=$((attempt + 1))
  done
}

# ===== Start time =====
START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
echo "⏱️ Script started at: ${START_TIME}"

# ===== Step 1: Terraform apply =====
STEP=$((STEP+1))
echo "[$(percent ${STEP})%] 🚀 Running terraform apply..."
terraform apply -auto-approve || handle_error "terraform apply"
show_progress "$(percent ${STEP})" "Terraform apply"

# ===== Step 2: Extract IP for ${HOST_KEY} from inventory.yml =====
STEP=$((STEP+1))
echo "[$(percent ${STEP})%] 🔍 Extracting IP address for ${HOST_KEY} from inventory.yml..."
[[ -f "inventory.yml" ]] || handle_error "inventory.yml not found after terraform apply"

IP_ADDRESS=$(awk -v key="${HOST_KEY}:" '
  $0 ~ key {found=1; next}
  found && /ansible_host:/ {print $2; exit}
' inventory.yml)

[[ -n "${IP_ADDRESS}" ]] || handle_error "Failed to extract ansible_host for ${HOST_KEY} from inventory.yml"

echo "📌 Extracted ${HOST_KEY} IP Address: ${IP_ADDRESS}"
export MLS_KARMADA_HOST_IP="${IP_ADDRESS}"
echo "${IP_ADDRESS}" > .karmada_host_ip
show_progress "$(percent ${STEP})" "IP extraction"

# ===== Step 3: Copy inventory.yml locally into orchestrators tree =====
STEP=$((STEP+1))
echo "[$(percent ${STEP})%] 📂 Copying inventory.yml..."
cp inventory.yml mlsysops-framework/orchestrators/inventory.yml || handle_error "copy inventory.yml"
show_progress "$(percent ${STEP})" "Copy inventory.yml"

# ===== Step 4: Run k3s-install (serial + retries) =====
STEP=$((STEP+1))
echo "[$(percent ${STEP})%] ⚙️ Running ansible-playbook: k3s-install.yml (serial, with retries)..."
cd mlsysops-framework/orchestrators/ || handle_error "cd mlsysops-framework/orchestrators/"

run_with_retries \
  "ansible-playbook -i inventory.yml k3s-install.yml --forks 1" \
  5 \
  20 || handle_error "ansible-playbook k3s-install.yml (APT lock?)"
show_progress "$(percent ${STEP})" "k3s-install"

# ===== Step 5: Run karmada-install (serial) =====
STEP=$((STEP+1))
echo "[$(percent ${STEP})%] ⚙️ Running ansible-playbook: karmada-install.yml (serial)..."
ansible-playbook -i inventory.yml karmada-install.yml --forks 1 \
  || handle_error "ansible-playbook karmada-install.yml"
show_progress "$(percent ${STEP})" "karmada-install"

# ===== Step 6: Clean known_hosts for the extracted IP (LOCAL) =====
STEP=$((STEP+1))
echo "[$(percent ${STEP})%] 🧹 Cleaning known_hosts for ${IP_ADDRESS} (local)..."
ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "${IP_ADDRESS}" >/dev/null 2>&1 || true
show_progress "$(percent ${STEP})" "known_hosts cleanup"

# ===== Step 7: Copy inventory.yml to remote host via SCP =====
STEP=$((STEP+1))
echo "[$(percent ${STEP})%] 📤 Copying inventory.yml to remote ${REMOTE_USER}@${IP_ADDRESS}:${REMOTE_HOME}/inventory.yaml ..."
scp -o StrictHostKeyChecking=no \
    "${PWD}/inventory.yml" \
    "${REMOTE_USER}@${IP_ADDRESS}:${REMOTE_HOME}/inventory.yaml" \
    || handle_error "scp inventory.yml to remote"
show_progress "$(percent ${STEP})" "SCP inventory to remote"

# ===== Step 8: Remote bootstrap + CLI deploy =====
STEP=$((STEP+1))
echo "[$(percent ${STEP})%] 🖥️  Bootstrapping remote CLI and running deploy-all on ${REMOTE_USER}@${IP_ADDRESS} ..."

ssh -o StrictHostKeyChecking=no "${REMOTE_USER}@${IP_ADDRESS}" bash -lc "'
set -Eeuo pipefail

wait_for_apt() {
  while pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null; do
    sleep 5
  done
}

if [[ ! -d \"${REMOTE_HOME}/mlsysops-framework\" ]]; then
  git clone https://github.com/mlsysops-eu/mlsysops-framework
fi
cd mlsysops-framework

git fetch origin
git branch -r || true
git checkout origin/cli-hackaton

cd ~
wait_for_apt
sudo apt-get update -y
wait_for_apt
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3.10-venv
python3 -m venv .venv
source .venv/bin/activate

cd mlsysops-framework/mlsysops-cli/
pip install --upgrade pip
pip install -e .

if ! grep -q \"_MLS_COMPLETE=bash_source mls\" ~/.bashrc; then
  echo '\''eval \"\$(_MLS_COMPLETE=bash_source mls)\"'\'' >> ~/.bashrc
fi
source ~/.bashrc || true
cd ~

export KUBECONFIG=\"${REMOTE_HOME}/karmada-kubeconfig.yaml\"
export KARMADA_HOST_IP=\"${MLS_KARMADA_HOST_IP}\"

mls framework deploy-all --inventory inventory.yaml
' " || handle_error "remote bootstrap & mls deploy-all"

show_progress "$(percent ${STEP})" "Remote CLI deploy"

# ===== End time =====
END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
echo "🎉 100% COMPLETED: All steps finished successfully!"
echo "⏱️ Script finished at: ${END_TIME}"
