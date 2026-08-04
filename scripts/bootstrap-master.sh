#!/usr/bin/env bash
# Install K3s server (control plane) on the master droplet.
# Same SSH conventions as Eats: root@IP, optional SSH_KEY_PATH (default ~/.ssh/id_rsa).
#
# Usage (from repo root):
#   ./scripts/bootstrap-master.sh
#   SSH_KEY_PATH=~/.ssh/id_rsa ./scripts/bootstrap-master.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=load-node-ip.sh
source "$SCRIPT_DIR/load-node-ip.sh" master

DROPLET_USER="${DROPLET_USER:-root}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"
SSH_CMD=(ssh -o StrictHostKeyChecking=accept-new)
if [ -f "$SSH_KEY_PATH" ]; then
  SSH_CMD=(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new)
fi

echo "==> Testing SSH to ${DROPLET_USER}@${NODE_IP}"
if ! "${SSH_CMD[@]}" "${DROPLET_USER}@${NODE_IP}" "echo SSH_OK" >/dev/null; then
  echo "Cannot connect to $NODE_IP. Check inventory/MASTER_IP and SSH key." >&2
  exit 1
fi
echo "==> SSH OK"

echo "==> Installing K3s server on master (workloads allowed — learning mode)"
"${SSH_CMD[@]}" "${DROPLET_USER}@${NODE_IP}" 'bash -s' <<'ENDSSH'
set -euo pipefail

if command -v k3s >/dev/null 2>&1 && systemctl is-active --quiet k3s; then
  echo "K3s already running — skipping install"
else
  # Single-node server; do NOT disable workloads. Cordoning comes later (Phase 4).
  curl -sfL https://get.k3s.io | sh -
fi

# Wait until API is up
for i in $(seq 1 60); do
  if kubectl get nodes >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "--- nodes ---"
kubectl get nodes -o wide
echo "--- k3s token (for workers) ---"
sudo cat /var/lib/rancher/k3s/server/node-token
ENDSSH

echo ""
echo "==> Master ready."
echo "Next (optional local kubeconfig):"
echo "  ./scripts/fetch-kubeconfig.sh"
echo ""
echo "Phase 1 deploy (after kubeconfig):"
echo "  kubectl apply -f k8s/phase1/"
echo "  kubectl get pods -o wide"
