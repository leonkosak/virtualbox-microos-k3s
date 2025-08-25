#!/usr/bin/env bash
# setup-k3s.sh
# Idempotent single-node k3s setup on openSUSE MicroOS (Container Host)
# NAT-aware for VirtualBox
# Handles container-selinux/AppArmor requirements automatically

set -euo pipefail

# -------------------------------
# Configuration
# -------------------------------
VM_IP="${1:-}"                # optional VM IP (for bridged mode)
FORCE_MODE="${FORCE_MODE:-}"  # "nat" | "bridged" override
NAT_PORT="${NAT_PORT:-6443}"  # forwarded host port for VirtualBox NAT
K3S_VERSION="${K3S_VERSION:-}"# optional k3s version pin
HOSTNAME="$(hostname)"

log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }

# -------------------------------
# Helper functions
# -------------------------------
detect_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'; }
in_subnet_10_0_2() { [[ "$1" =~ ^10\.0\.2\.[0-9]+$ ]]; }
detect_mode() {
  [[ "$FORCE_MODE" == "nat" || "$FORCE_MODE" == "bridged" ]] && echo "$FORCE_MODE" && return
  local ip=${VM_IP:-$(detect_ip)}
  local gw=$(ip route | awk '/default/ {print $3; exit}')
  if in_subnet_10_0_2 "$ip" || [[ "$gw" == "10.0.2.2" ]]; then echo "nat"; else echo "bridged"; fi
}

# -------------------------------
# Step 0: Ensure k3s security context
# -------------------------------
if [[ ! -f /usr/local/bin/k3s ]] || ! sudo restorecon -n /usr/local/bin/k3s >/dev/null 2>&1; then
  log "Installing container-selinux and Rancher MicroOS RPMs..."
  sudo transactional-update pkg install -y container-selinux
  sudo transactional-update pkg install -y https://rpm.rancher.io/k3s/stable/common/microos/noarch/k3s-common-*.rpm
  warn "Reboot required. Re-run script after reboot."
  exit 0
fi

# -------------------------------
# Step 1: Required packages
# -------------------------------
if ! rpm -q openssh >/dev/null 2>&1; then
  log "Installing openssh..."
  sudo transactional-update pkg install -y openssh
  warn "Reboot required. Re-run script afterwards."
  exit 0
fi

if rpm -q zram-generator-defaults >/dev/null 2>&1; then
  log "Removing zram swap generator..."
  sudo transactional-update pkg remove -y zram-generator-defaults
  warn "Reboot required. Re-run script afterwards."
  exit 0
fi

# -------------------------------
# Step 2: Kernel modules & sysctl
# -------------------------------
sudo tee /etc/modules-load.d/kubernetes.conf >/dev/null <<'EOF'
br_netfilter
overlay
EOF
for mod in br_netfilter overlay; do
  lsmod | grep -q "$mod" || sudo modprobe "$mod" || true
done

sudo tee /etc/sysctl.d/90-kubernetes.conf >/dev/null <<'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
sudo sysctl --system >/dev/null

# -------------------------------
# Step 3: Networking
# -------------------------------
[[ -z "$VM_IP" ]] && VM_IP="$(detect_ip || true)"
MODE="$(detect_mode)"
log "Network mode: $MODE, VM IP: $VM_IP"

# -------------------------------
# Step 4: k3s config
# -------------------------------
sudo mkdir -p /etc/rancher/k3s
CONFIG_FILE=/etc/rancher/k3s/config.yaml
if [[ ! -f "$CONFIG_FILE" ]]; then
  log "Creating k3s config..."
  sudo tee "$CONFIG_FILE" >/dev/null <<EOF
write-kubeconfig-mode: "0644"
node-ip: ${VM_IP}
tls-san:
  - ${VM_IP}
  - ${HOSTNAME}
EOF
fi

# -------------------------------
# Step 5: Install/upgrade k3s
# -------------------------------
if ! command -v k3s >/dev/null 2>&1; then
  log "Installing k3s..."
  [[ -n "$K3S_VERSION" ]] && curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh - || curl -sfL https://get.k3s.io | sh -
else
  log "k3s already installed → upgrading if needed..."
  [[ -n "$K3S_VERSION" ]] && curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh - || curl -sfL https://get.k3s.io | sh -
fi

# -------------------------------
# Step 6: kubeconfig
# -------------------------------
mkdir -p "${HOME}/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
sudo chown "$(id -u):$(id -g)" "${HOME}/.kube/config"

if [[ "$MODE" == "nat" ]]; then
  sed -i "s|server: https://.*:6443|server: https://127.0.0.1:${NAT_PORT}|" "${HOME}/.kube/config" || true
else
  [[ -n "$VM_IP" ]] && sed -i "s|server: https://.*:6443|server: https://${VM_IP}:6443|" "${HOME}/.kube/config" || true
fi

# -------------------------------
# Step 7: Check
# -------------------------------
if kubectl get nodes >/dev/null 2>&1; then
  log "k3s is reachable."
else
  warn "k3s not ready yet. Check: journalctl -u k3s -f"
fi

log "Setup complete. Safe to rerun anytime."
