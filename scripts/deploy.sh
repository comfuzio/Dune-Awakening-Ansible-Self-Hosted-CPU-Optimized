#!/usr/bin/env bash
# Deploy (or re-apply) the Dune: Awakening self-hosted stack.
#
#   scripts/deploy.sh                    first run: asks questions, writes config/local.yml
#   scripts/deploy.sh                    later runs: re-uses config/local.yml
#   scripts/deploy.sh --tags k3s         any ansible-playbook option is passed through
#   scripts/deploy.sh --reconfigure      ask the questions again
#
# The Funcom self-host token is asked for on every run (hidden input) and
# handed to Ansible through the environment only. Export DUNE_SELFHOST_TOKEN
# beforehand to skip the question.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
config="$repo/config/local.yml"
cd "$repo"

reconfigure=false
args=()
for arg in "$@"; do
  if [[ "$arg" == --reconfigure ]]; then reconfigure=true; else args+=("$arg"); fi
done

ask() { # ask VAR "Question" [default]; without a default an answer is required
  local answer
  while true; do
    read -r -p "$2${3:+ [$3]}: " answer
    answer="${answer:-${3:-}}"
    [[ -n "$answer" ]] && break
  done
  printf -v "$1" '%s' "$answer"
}

ask_optional() { # ask_optional VAR "Question"
  local answer
  read -r -p "$2: " answer
  printf -v "$1" '%s' "$answer"
}

yaml_str() { # single-quoted YAML scalar
  printf "'%s'" "${1//\'/\'\'}"
}

# Variables below are assigned through printf -v in ask/ask_optional.
# shellcheck disable=SC2154
write_config() {
  echo "== Proxmox"
  ask pve_host        "Proxmox node address"
  ask pve_user        "SSH user on the node" "root"
  ask pve_storage     "Storage for VM disks" "local-lvm"
  ask pve_bridge      "Network bridge" "vmbr0"
  ask tpl_vmid        "Ubuntu 26.04 amd64v3 template VMID (built if missing)" "8010"
  echo "== VM"
  ask vm_id           "Dune VM VMID" "201"
  ask vm_name         "VM name" "dune-server"
  ask vm_cores        "vCPUs" "6"
  ask vm_mem          "RAM (GiB)" "40"
  ask vm_disk         "Disk (GiB)" "110"
  ask vm_addr         "Static address with prefix, e.g. 192.168.1.200/24"
  ask vm_gw           "Gateway"
  ask vm_key          "SSH private key for the VM" "$HOME/.ssh/dune_ed25519"
  echo "== World"
  ask world           "World name" "My Arrakis"
  ask region          "Region (asia, europe, north-america, oceania, south-america)" "europe"
  ask_optional public_ip "Player-facing IP (empty = detect)"

  [[ -f "$vm_key.pub" ]] || { echo "No public key at $vm_key.pub (create one with ssh-keygen -t ed25519 -f $vm_key)" >&2; exit 1; }

  umask 077
  mkdir -p "$(dirname "$config")"
  cat > "$config" <<EOF
# Written by scripts/deploy.sh; edit freely. See config/example.yml for all options.
pve_host: $(yaml_str "$pve_host")
pve_user: $(yaml_str "$pve_user")
pve_storage: $(yaml_str "$pve_storage")
pve_bridge: $(yaml_str "$pve_bridge")
pve_template_vmid: $tpl_vmid
pve_template_build: true
vm_id: $vm_id
vm_name: $(yaml_str "$vm_name")
vm_cores: $vm_cores
vm_memory_gib: $vm_mem
vm_disk_gib: $vm_disk
vm_address: $(yaml_str "$vm_addr")
vm_gateway: $(yaml_str "$vm_gw")
vm_ssh_private_key: $(yaml_str "$vm_key")
vm_ssh_public_key: $(yaml_str "$vm_key.pub")
dune_world_name: $(yaml_str "$world")
dune_world_region: $(yaml_str "$region")
dune_public_ip: $(yaml_str "$public_ip")
EOF
  echo "Saved $config"
}

if [[ ! -f "$config" || "$reconfigure" == true ]]; then
  write_config
fi

if [[ -z "${DUNE_SELFHOST_TOKEN:-}" ]]; then
  read -r -s -p "Funcom self-host token (input hidden; empty to skip world changes): " DUNE_SELFHOST_TOKEN
  echo
fi
export DUNE_SELFHOST_TOKEN

playbook="${ANSIBLE_PLAYBOOK:-}"
if [[ -z "$playbook" ]]; then
  if [[ -x "$repo/.venv/bin/ansible-playbook" ]]; then
    playbook="$repo/.venv/bin/ansible-playbook"
  else
    playbook="$(command -v ansible-playbook)" || { echo "ansible-playbook not found" >&2; exit 1; }
  fi
fi

exec "$playbook" site.yml -e "@$config" "${args[@]}"
