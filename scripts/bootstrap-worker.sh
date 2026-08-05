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

# Preserve role — load-node-ip.sh overwrites ROLE when we load master next.
WORKER_ROLE="$ROLE"

# shellcheck source=load-node-ip.sh
source "$SCRIPT_DIR/load-node-ip.sh" "$WORKER_ROLE"
WORKER_IP="$NODE_IP"

# shellcheck source=load-node-ip.sh
source "$SCRIPT_DIR/load-node-ip.sh" master
MASTER_IP="$NODE_IP"

if [ "$WORKER_IP" = "$MASTER_IP" ]; then
  echo "Error: ${WORKER_ROLE} IP ($WORKER_IP) is the same as MASTER_IP." >&2
  echo "Workers need a separate droplet. Leave inventory/${WORKER_ROLE^^}_IP as YOUR_DROPLET_IP until you create one." >&2
  exit 1
fi

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

echo "==> Checking worker can reach master API :6443"
if ! "${SSH_CMD[@]}" "${DROPLET_USER}@${WORKER_IP}" "bash -c 'timeout 5 bash -c \"</dev/tcp/${MASTER_IP}/6443\" 2>/dev/null' || nc -z -w 5 ${MASTER_IP} 6443"; then
  echo "Worker cannot reach https://${MASTER_IP}:6443. Open that port (and DO Cloud Firewall) between droplets." >&2
  exit 1
fi

# DO droplets of the same size often share a hostname; K3s rejects duplicate names.
NODE_NAME="$WORKER_ROLE"
echo "==> Joining ${WORKER_ROLE} (${WORKER_IP}) as node name '${NODE_NAME}' → https://${MASTER_IP}:6443"
if ! "${SSH_CMD[@]}" "${DROPLET_USER}@${WORKER_IP}" \
  "hostnamectl set-hostname ${NODE_NAME}; curl -sfL https://get.k3s.io | K3S_URL=https://${MASTER_IP}:6443 K3S_TOKEN=${TOKEN} K3S_NODE_NAME=${NODE_NAME} sh -"; then
  echo "==> Join failed — dumping k3s-agent logs:" >&2
  "${SSH_CMD[@]}" "${DROPLET_USER}@${WORKER_IP}" \
    "journalctl -u k3s-agent -n 80 --no-pager || true" >&2
  exit 1
fi

echo "==> Cluster nodes (from master):"
"${SSH_CMD[@]}" "${DROPLET_USER}@${MASTER_IP}" "kubectl get nodes -o wide"

echo "==> ${WORKER_ROLE} joined."
