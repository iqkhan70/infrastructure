#!/usr/bin/env bash
# Load node IP from inventory file (borrowed from Eats load-droplet-ip.sh).
# Usage: source scripts/load-node-ip.sh [master|worker1|worker2]
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY_DIR="$(cd "$SCRIPT_DIR/../inventory" && pwd)"
ROLE="${1:-master}"

case "$ROLE" in
  master)
    IP_FILE="${INVENTORY_DIR}/MASTER_IP"
    ;;
  worker1)
    IP_FILE="${INVENTORY_DIR}/WORKER1_IP"
    ;;
  worker2)
    IP_FILE="${INVENTORY_DIR}/WORKER2_IP"
    ;;
  *)
    echo "Error: Unknown role '$ROLE'. Use: master | worker1 | worker2" >&2
    exit 1
    ;;
esac

if [ ! -f "$IP_FILE" ]; then
  echo "Error: IP file not found at $IP_FILE" >&2
  echo "Create it with your Droplet IP, e.g.: echo '1.2.3.4' > $IP_FILE" >&2
  exit 1
fi

NODE_IP=$(grep -v '^#' "$IP_FILE" | grep -v '^$' | head -1 | tr -d '[:space:]')

if [ -z "$NODE_IP" ] || [ "$NODE_IP" = "YOUR_DROPLET_IP" ]; then
  echo "Error: Put your Droplet IP in $IP_FILE (replace YOUR_DROPLET_IP)." >&2
  exit 1
fi

export NODE_IP
export DROPLET_IP="$NODE_IP"
export ROLE
echo "Loaded $ROLE IP: $NODE_IP"
