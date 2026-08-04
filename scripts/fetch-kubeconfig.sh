#!/usr/bin/env bash
# Copy kubeconfig from master and rewrite server to the public droplet IP.
# Usage: ./scripts/fetch-kubeconfig.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=load-node-ip.sh
source "$SCRIPT_DIR/load-node-ip.sh" master

DROPLET_USER="${DROPLET_USER:-root}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"
SSH_CMD=(ssh -o StrictHostKeyChecking=accept-new)
SCP_CMD=(scp -o StrictHostKeyChecking=accept-new)
if [ -f "$SSH_KEY_PATH" ]; then
  SSH_CMD=(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new)
  SCP_CMD=(scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new)
fi

OUT="${REPO_ROOT}/kubeconfig.yaml"
"${SSH_CMD[@]}" "${DROPLET_USER}@${NODE_IP}" "sudo cat /etc/rancher/k3s/k3s.yaml" >"$OUT"

# K3s defaults to 127.0.0.1 — point at the droplet
if [[ "$OSTYPE" == darwin* ]]; then
  sed -i '' "s/127.0.0.1/${NODE_IP}/g" "$OUT"
else
  sed -i "s/127.0.0.1/${NODE_IP}/g" "$OUT"
fi

chmod 600 "$OUT"
echo "Wrote $OUT"
echo "export KUBECONFIG=$OUT"
