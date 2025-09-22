#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# MLSysOps One-Click Deploy (resumable steps)
# - Supports resume via --from-step=N
# - Asks (or accepts --group=N/groupN) to target groupN-* hosts
# - Clear START/END comments per step for easy editing
###############################################################################

# ----------------------------- CLI & Resume ----------------------------------
START_FROM_STEP=1
GROUP_INPUT=""

for arg in "$@"; do
  case "$arg" in
    --from-step=*) START_FROM_STEP="${arg#*=}";;
    --group=*)     GROUP_INPUT="${arg#*=}";;
  esac
done

echo "[INFO] Will start from step ${START_FROM_STEP}"

# Normalize group: accepts "3" or "group3" (1..7). Defaults to group1 if empty/invalid.
normalize_group() {
  local in="$1"
  if [[ -z "$in" ]]; then echo "group1"; return; fi
  if [[ "$in" =~ ^group([1-7])$ ]]; then echo "group${BASH_REMATCH[1]}"; return; fi
  if [[ "$in" =~ ^([1-7])$ ]]; then echo "group${BASH_REMATCH[1]}"; return; fi
  echo "group1"
}

if [[ -z "$GROUP_INPUT" ]]; then
  read -rp "Enter group number (1..7) [default: 1]: " GROUP_INPUT
fi
GROUP_PREFIX="$(normalize_group "$GROUP_INPUT")"
GROUP_NUM="${GROUP_PREFIX#group}"

GROUP_CONTINUUM="${GROUP_PREFIX}-continuum"
GROUP_CLUSTER="${GROUP_PREFIX}-cluster"
GROUP_NODE1="${GROUP_PREFIX}-node1"
GROUP_NODE2="${GROUP_PREFIX}-node2"

export GROUP_PREFIX GROUP_NUM GROUP_CONTINUUM GROUP_CLUSTER GROUP_NODE1 GROUP_NODE2
echo "[INFO] Selected group: ${GROUP_PREFIX}"
echo "[INFO] Hosts: ${GROUP_CONTINUUM}, ${GROUP_CLUSTER}, ${GROUP_NODE1}, ${GROUP_NODE2}"

# Inventory host we'll use to fetch the IP (default to continuum)
HOST_KEY="${GROUP_CONTINUUM}"
REMOTE_USER="mlsysops"
REMOTE_HOME="/home/${REMOTE_USER}"
ORCH_DIR="mlsysops-framework/orchestrators"

# ----------------------------- Helpers ---------------------------------------
TOTAL_STEPS=12     # Steps 0..11 inclusive
STEP=0

die() {
  echo "[ERROR] $*"
  echo "[INFO] End time: $(date '+%Y-%m-%d %H:%M:%S')"
  exit 1
}
percent() { echo $(( $1 * 100 / TOTAL_STEPS )); }
ok() { echo "[OK] [$1%] $2 completed"; }

run_with_retries() {
  local cmd="$1"; local retries="${2:-5}"; local sleep_s="${3:-20}"
  local attempt=1 rc
  while true; do
    echo "[INFO] Attempt ${attempt}/${retries}: ${cmd}"
    set +e; eval "$cmd"; rc=$?; set -e
    if [[ $rc -eq 0 ]]; then return 0; fi
    if (( attempt >= retries )); then echo "[ERROR] Failed after ${retries} attempts: ${cmd}"; return $rc; fi
    echo "[INFO] Transient error. Sleeping ${sleep_s}s..."; sleep "$sleep_s"
    attempt=$((attempt+1))
  done
}

run_step() {
  local n="$1"; shift
  local title="$1"; shift
  if (( n < START_FROM_STEP )); then
    echo "[SKIP] Step $n (${title})"
    return 1
  fi
  STEP="$n"
  echo
  echo "##############################"
  echo "# STEP ${n} START: ${title}"
  echo "##############################"
  return 0
}

finish_step() {
  echo "############################"
  echo "# STEP ${STEP} END"
  echo "############################"
  ok "$(percent "${STEP}")" "$1"
}

# --------------------- Resumption: preload saved IP if present ---------------
# This prevents "unbound variable" when starting at step >= 8
if [[ -z "${IP_ADDRESS:-}" && -f ".karmada_host_ip" ]]; then
  IP_ADDRESS="$(<.karmada_host_ip)"
  export MLS_KARMADA_HOST_IP="${IP_ADDRESS}"
  echo "[INFO] Preloaded IP from .karmada_host_ip: ${IP_ADDRESS}"
fi

ensure_ip() {
  # Ensure IP_ADDRESS and MLS_KARMADA_HOST_IP are populated when resuming mid-script
  if [[ -n "${IP_ADDRESS:-}" ]]; then
    : "${MLS_KARMADA_HOST_IP:=${IP_ADDRESS}}"
    export MLS_KARMADA_HOST_IP
    return 0
  fi

  if [[ -f ".karmada_host_ip" ]]; then
    IP_ADDRESS="$(<.karmada_host_ip)"
    export MLS_KARMADA_HOST_IP="${IP_ADDRESS}"
    echo "[INFO] Loaded IP from .karmada_host_ip: ${IP_ADDRESS}"
    return 0
  fi

  if [[ -f "inventory.yml" ]]; then
    echo "[INFO] Parsing inventory.yml for ${HOST_KEY} to recover IP..."
    IP_ADDRESS="$(
      awk -v key="${HOST_KEY}:" '
        $0 ~ key {found=1; next}
        found && /ansible_host:/ {print $2; exit}
      ' inventory.yml
    )"
    if [[ -n "${IP_ADDRESS}" ]]; then
      echo "${IP_ADDRESS}" > .karmada_host_ip
      export MLS_KARMADA_HOST_IP="${IP_ADDRESS}"
      echo "[INFO] Recovered IP ${IP_ADDRESS} and saved to .karmada_host_ip"
      return 0
    fi
  fi

  die "Cannot determine IP address. Please run from an earlier step (e.g. --from-step=3) so inventory.yml and .karmada_host_ip are created."
}

# ----------------------------- Timestamps ------------------------------------
START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
echo "[INFO] Script started at: ${START_TIME}"

# ------------------------- STEP 0: Pre-flight checks -------------------------
if run_step 0 "Pre-flight checks (Terraform/Ansible)"; then
  echo "[INFO] Checking for required dependencies..."

  install_if_missing() {
    local bin_name=$1
    local install_cmd=$2
    if ! command -v "$bin_name" >/dev/null 2>&1; then
      echo "[INFO] $bin_name not found."
      if ! command -v sudo >/dev/null 2>&1; then
        die "sudo not available; install $bin_name manually and re-run."
      fi
      echo "[INFO] Installing $bin_name..."
      eval "$install_cmd" || die "Failed to install $bin_name"
      echo "[INFO] $bin_name installed."
    else
      echo "[INFO] $bin_name present: $(command -v "$bin_name")"
    fi
  }

  # Terraform (Ubuntu/Debian)
  install_if_missing "terraform" "
  sudo apt-get update -y &&
  sudo apt-get install -y gnupg software-properties-common curl &&
  curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg &&
  echo \"deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com \$(lsb_release -cs) main\" | sudo tee /etc/apt/sources.list.d/hashicorp.list &&
  sudo apt-get update -y &&
  sudo apt-get install -y terraform
  "

  # Ansible
  install_if_missing "ansible" "
  sudo apt-get update -y &&
  sudo apt-get install -y ansible
  "

  finish_step "Pre-flight checks"
fi

# ------------------------- STEP 1: SSH key generation ------------------------
if run_step 1 "SSH key generation"; then
  SSH_KEY_PATH="${HOME}/.ssh/id_rsa"
  if [[ ! -f "${SSH_KEY_PATH}.pub" ]]; then
    echo "[INFO] No SSH key at ${SSH_KEY_PATH}.pub, generating..."
    mkdir -p "${HOME}/.ssh"
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH}" -N ""
    echo "[INFO] SSH key generated at ${SSH_KEY_PATH}.pub"
  else
    echo "[INFO] SSH key already exists at ${SSH_KEY_PATH}.pub"
  fi
  finish_step "SSH key generation"
fi

# --------------------- STEP 2: Terraform variables setup ---------------------
if run_step 2 "Terraform variables & per-group token setup"; then
  TFVARS_FILE="terraform.tfvars"
  PUBKEY_PATH="${HOME}/.ssh/id_rsa.pub"

  # 2.a) Ensure terraform.tfvars has the ssh_public_key_path (only once)
  if [[ -f "${TFVARS_FILE}" ]]; then
    echo "[INFO] ${TFVARS_FILE} already exists, leaving it as-is."
  else
    cat > "${TFVARS_FILE}" <<EOF
ssh_public_key_path = "${PUBKEY_PATH}"
EOF
    echo "[INFO] Wrote ${TFVARS_FILE} with ssh_public_key_path."
  fi

  # 2.b) Load / capture the Hetzner token for the selected group
  TOKEN_FILE=".hcloud_tokens"
  if [[ -f "${TOKEN_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${TOKEN_FILE}"
    echo "[INFO] Loaded tokens from ${TOKEN_FILE}"
  fi

  # Resolve token name dynamically, e.g. HCTOKEN_GROUP3
  TOKEN_VAR="HCTOKEN_GROUP${GROUP_NUM}"
  HCTOKEN="${!TOKEN_VAR:-}"

  if [[ -z "${HCTOKEN}" ]]; then
    echo -n "Enter Hetzner token for group ${GROUP_NUM} (${TOKEN_VAR}): "
    read -r HCTOKEN
    read -r -p "Save this token into ${TOKEN_FILE} for future runs? [y/N]: " SAVE_TOK
    if [[ "${SAVE_TOK}" =~ ^[Yy]$ ]]; then
      if [[ ! -f "${TOKEN_FILE}" ]]; then
        umask 177
        : > "${TOKEN_FILE}"
      fi
      if grep -q "^${TOKEN_VAR}=" "${TOKEN_FILE}" 2>/dev/null; then
        sed -i "s|^${TOKEN_VAR}=.*|${TOKEN_VAR}=\"${HCTOKEN}\"|" "${TOKEN_FILE}"
      else
        echo "${TOKEN_VAR}=\"${HCTOKEN}\"" >> "${TOKEN_FILE}"
      fi
      chmod 600 "${TOKEN_FILE}" || true
      echo "[INFO] Saved ${TOKEN_VAR} to ${TOKEN_FILE} (600)."
    fi
  fi

  if [[ -z "${HCTOKEN}" ]]; then
    die "No Hetzner token available for group ${GROUP_NUM} (${TOKEN_VAR})."
  fi

  # 2.c) Write an override file for the selected group's token
  cat > hcloud.auto.tfvars <<EOF
hcloud_token = "${HCTOKEN}"
EOF
  echo "[INFO] Wrote $(pwd)/hcloud.auto.tfvars"

  # 2.d) Generate group.auto.tfvars (vm_names)
  cat > group.auto.tfvars <<EOF
vm_names = [
  "${GROUP_PREFIX}-continuum",
  "${GROUP_PREFIX}-cluster", "${GROUP_PREFIX}-node1", "${GROUP_PREFIX}-node2",
]
EOF
  echo "[INFO] Wrote $(pwd)/group.auto.tfvars:"
  cat group.auto.tfvars

  # 2.e) Init Terraform
  terraform init
  finish_step "Terraform tfvars + per-group token + group.auto.tfvars + init"
fi

# --------------------------- STEP 3: terraform apply -------------------------
if run_step 3 "Terraform apply"; then
  terraform apply -auto-approve || die "terraform apply failed"
  finish_step "Terraform apply"
fi

# ------- STEP 4: Extract IP for ${HOST_KEY} from inventory.yml ---------------
if run_step 4 "Extract IP for ${HOST_KEY} from inventory.yml"; then
  [[ -f "inventory.yml" ]] || die "inventory.yml not found after terraform apply"

  IP_ADDRESS=$(awk -v key="${HOST_KEY}:" '
    $0 ~ key {found=1; next}
    found && /ansible_host:/ {print $2; exit}
  ' inventory.yml)

  [[ -n "${IP_ADDRESS}" ]] || die "Could not extract ansible_host for ${HOST_KEY}"
  echo "[INFO] ${HOST_KEY} IP: ${IP_ADDRESS}"
  export MLS_KARMADA_HOST_IP="${IP_ADDRESS}"
  echo "${IP_ADDRESS}" > .karmada_host_ip
  finish_step "IP extraction"
fi

# ------- STEP 5: Copy inventory.yml into orchestrators tree (local) ----------
if run_step 5 "Copy inventory.yml into ${ORCH_DIR}"; then
  cp inventory.yml "${ORCH_DIR}/inventory.yml" || die "copy inventory.yml to ${ORCH_DIR}"
  finish_step "Copy inventory.yml locally"
fi

# ---------------- STEP 6: Run k3s-install (serial + retries) -----------------
if run_step 6 "Ansible: k3s-install (serial + retries)"; then
  pushd "${ORCH_DIR}" >/dev/null || die "cd ${ORCH_DIR}"
  run_with_retries "ansible-playbook -i inventory.yml k3s-install.yml --forks 1" 5 20 \
    || die "k3s-install playbook failed"
  popd >/dev/null
  finish_step "k3s-install"
fi

# ----------------- STEP 7: Run karmada-install (serial) ----------------------
if run_step 7 "Ansible: karmada-install (serial)"; then
  pushd "${ORCH_DIR}" >/dev/null || die "cd ${ORCH_DIR}"
  ansible-playbook -i inventory.yml karmada-install.yml --forks 1 \
    || die "karmada-install playbook failed"
  popd >/dev/null
  finish_step "karmada-install"
fi

# -------- STEP 8: Clean known_hosts for the extracted IP (local) -------------
if run_step 8 "Clean known_hosts for ${IP_ADDRESS}"; then
  ensure_ip
  ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "${IP_ADDRESS}" >/dev/null 2>&1 || true
  finish_step "known_hosts cleanup"
fi

# -------- STEP 9: Copy inventory.yml to remote host via SCP ------------------
if run_step 9 "SCP inventory.yml to ${REMOTE_USER}@${IP_ADDRESS}:${REMOTE_HOME}/inventory.yaml"; then
  ensure_ip
  scp -o StrictHostKeyChecking=no \
      "$(pwd)/inventory.yml" \
      "${REMOTE_USER}@${IP_ADDRESS}:${REMOTE_HOME}/inventory.yaml" \
      || die "scp inventory.yml to remote failed"
  echo "[INFO] Inventory uploaded to ${REMOTE_USER}@${IP_ADDRESS}:${REMOTE_HOME}/inventory.yaml"
  finish_step "SCP inventory to remote"
fi

# ---- STEP 10: Remote bootstrap Python venv + mls CLI + deploy-all -----------
if run_step 10 "Remote bootstrap & mls framework deploy-all"; then
  ensure_ip
  echo "[INFO] STEP 10: Starting remote bootstrap on ${REMOTE_USER}@${IP_ADDRESS}"
  ssh -o StrictHostKeyChecking=no "${REMOTE_USER}@${IP_ADDRESS}" \
    REMOTE_HOME="${REMOTE_HOME}" MLS_KARMADA_HOST_IP="${MLS_KARMADA_HOST_IP}" bash -s <<'REMOTE_BOOT'
set -Eeuo pipefail
export PS4='+ [REMOTE BOOT] ${0##*/}:${LINENO}: '
set -x
trap 'echo "[REMOTE BOOT][ERROR] Failed at line $LINENO"' ERR

wait_for_apt() {
  while pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null; do
    sleep 5
  done
}

cd "${REMOTE_HOME}"

# Get repo
if [[ ! -d "${REMOTE_HOME}/mlsysops-framework" ]]; then
  git clone https://github.com/mlsysops-eu/mlsysops-framework "${REMOTE_HOME}/mlsysops-framework"
fi
cd "${REMOTE_HOME}/mlsysops-framework"
git fetch --all --prune || true

# Prefer cli-hackaton if available, else main
if git show-ref --verify --quiet refs/remotes/origin/cli-hackaton; then
  git switch -C cli-hackaton origin/cli-hackaton
else
  git switch -C main origin/main || git switch main
fi

# Python env
wait_for_apt
sudo apt-get update -y
wait_for_apt
if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip git; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3.10-venv python3-pip git
fi

python3 -m venv "${REMOTE_HOME}/.venv"
source "${REMOTE_HOME}/.venv/bin/activate"

cd "${REMOTE_HOME}/mlsysops-framework/mlsysops-cli/"
pip install --upgrade pip setuptools wheel
pip install -e .

# Shell completion (best-effort)
if ! grep -q "_MLS_COMPLETE=bash_source mls" "${REMOTE_HOME}/.bashrc"; then
  echo 'eval "$(_MLS_COMPLETE=bash_source mls)"' >> "${REMOTE_HOME}/.bashrc"
fi

# >>> Order required before mls call <<<
export KUBECONFIG="${REMOTE_HOME}/karmada-kubeconfig.yaml"
export KARMADA_HOST_IP="${MLS_KARMADA_HOST_IP}"
echo "[REMOTE BOOT] KUBECONFIG=${KUBECONFIG}"
echo "[REMOTE BOOT] KARMADA_HOST_IP=${KARMADA_HOST_IP}"

mls framework deploy-all --inventory "${REMOTE_HOME}/inventory.yaml"
REMOTE_BOOT
  finish_step "Remote CLI deploy"
fi

# ---- STEP 11: Remote ensure Docker + docker compose up (mlconnector) --------
# ---- STEP 11: Remote ensure Docker + docker compose up (mlconnector) --------
if run_step 11 "Remote Docker setup & docker compose up (mlconnector)"; then
  ensure_ip
  echo "[INFO] STEP 11: Starting remote Docker setup on ${REMOTE_USER}@${IP_ADDRESS}"
  ssh -o StrictHostKeyChecking=no "${REMOTE_USER}@${IP_ADDRESS}" API_IP="${IP_ADDRESS}" bash -s <<'REMOTE_DOCKER'
set -Eeuo pipefail
export PS4='+ [REMOTE DOCKER] ${0##*/}:${LINENO}: '
set -x
trap 'echo "[REMOTE DOCKER][ERROR] Failed at line $LINENO"' ERR

wait_for_apt() {
  while pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null; do
    sleep 5
  done
}

echo "[INFO] Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
  echo "[INFO] Installing Docker..."
  wait_for_apt
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER" || true
else
  echo "[INFO] Docker present: $(docker --version)"
fi

# Compose plugin or legacy
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  echo "[INFO] Installing docker-compose..."
  sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
  COMPOSE_CMD="docker-compose"
fi

# Go to mlconnector folder
MC_DIR="${HOME}/mlsysops-framework/mlconnector"
if [[ ! -d "$MC_DIR" ]]; then
  echo "[ERROR] mlconnector directory not found at $MC_DIR"
  exit 1
fi
cd "$MC_DIR"

# ----- Create or update .env BEFORE compose up -----
ENV_PATH="$MC_DIR/.env"
if [[ ! -f "$ENV_PATH" ]]; then
  echo "[INFO] .env not found. Creating $ENV_PATH ..."
  # single-quoted heredoc to preserve the $ in POSTGRES_PASSWORD literally
  cat > "$ENV_PATH" <<'EOF'
POSTGRES_DB=mlmodel
POSTGRES_USER=postgres
POSTGRES_PASSWORD=54rCNF5rbZWd$
DB_HOST_NAME=database
DB_PORT=5432
DB_DRIVER=postgresql+asyncpg

DOCKER_USERNAME=mlconnector
DOCKER_PASSWORD=ADe4lNotHav3Draf7U1tima73lyOffering
DOCKER_REGISTRY_URL=registry.hackathon.mlsysops.eu

AWS_ACCESS_URL=https://s3.sky-flok.com
AWS_ACCESS_KEY_ID=SKYW3IVWRKC7LN4L7QCNNTJDO7RQBSRD
AWS_SECRET_ACCESS_KEY=MDBpDso0hZymB4nVXU0nLAbzqdYfREqDo1gl2pWjbyub4UAi72LNhIDbLgIzHXhq
AWS_S3_BUCKET_DATA=mlsysops-data

NOTHBOUND_API_ENDPOINT=http://__API_IP__:8000
SIDE_API_ENDPOINT=http://__API_IP__:8090
EOF
  # inject the continuum IP we SSHed to
  sed -i "s|__API_IP__|${API_IP}|g" "$ENV_PATH"
  chmod 600 "$ENV_PATH" || true
  echo "[INFO] Wrote $ENV_PATH with API IP ${API_IP}"
else
  echo "[INFO] Using existing $ENV_PATH (not overwriting). Ensuring endpoints match current IP..."
  sed -i -E "s|^(NOTHBOUND_API_ENDPOINT=).*|\1http://${API_IP}:8000|; s|^(SIDE_API_ENDPOINT=).*|\1http://${API_IP}:8090|" "$ENV_PATH"
fi

# ----- Compose up (explicitly pass the env file to be safe) -----
echo "[INFO] Running: $COMPOSE_CMD --env-file \"$ENV_PATH\" up -d"
sudo $COMPOSE_CMD --env-file "$ENV_PATH" up -d

echo "[INFO] Containers:"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
REMOTE_DOCKER
  finish_step "Docker compose up"
fi


# ------------------------------- Done ----------------------------------------
END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
echo
echo "[SUCCESS] 100% COMPLETED."
echo "[INFO] Started : ${START_TIME}"
echo "[INFO] Finished: ${END_TIME}"
