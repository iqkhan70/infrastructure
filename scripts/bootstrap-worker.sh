#!/usr/bin/env bash
# Join a worker to the K3s master.
# Usage:
#   ./scripts/bootstrap-worker.sh worker1
#   ./scripts/bootstrap-worker.sh worker2
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLE="${1:-}"

if [ -z "$ROLE" ] || { [ "$ROLE" != "worker1" ] && [ "$ROLE" != "worker2" ]; }; then
  echo "Usage: $0 worker1|worker2" >&2
  exit 1
fi

# shellcheck source=load-node-ip.sh
source "$SCRIPT_DIR/load-node-ip.sh" "$ROLE"
WORKER_IP="$NODE_IP"

# shellcheck source=load-node-ip.sh
source "$SCRIPT_DIR/load-node-ip.sh" master
MASTER_IP="$NODE_IP"

DROPLET_USER="${DROPLET_USER:-root}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"
SSH_CMD=(ssh -o StrictHostKeyChecking=accept-new)
if [ -f "$SSH_KEY_PATH" ]; then
  SSH_CMD=(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new)
fi

echo "==> Fetching join token from master ${MASTER_IP}"
TOKEN=$("${SSH_CMD[@]}" "${DROPLET_USER}@${MASTER_IP}" "sudo cat /var/lib/rancher/k3s/server/node-token" | tr -d '[:space:]')
if [ -z "$TOKEN" ]; then
  echo "Failed to read K3s node token from master. Is K3s installed?" >&2
  exit 1
fi

echo "==> Joining ${ROLE} (${WORKER_IP}) to https://${MASTER_IP}:6443"
"${SSH_CMD[@]}" "${DROPLET_USER}@${WORKER_IP}" \
  "curl -sfL https://get.k3s.io | K3S_URL=https://${MASTER_IP}:6443 K3S_TOKEN=${TOKEN} sh -"

echo "==> Cluster nodes (from master):"
"${SSH_CMD[@]}" "${DROPLET_USER}@${MASTER_IP}" "kubectl get nodes -o wide"

echo "==> ${ROLE} joined."
