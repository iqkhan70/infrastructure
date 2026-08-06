#!/usr/bin/env bash
# Runs on the K3s master. Env: SERVICE, FULL_IMAGE.
set -euo pipefail
: "${SERVICE:?}"
: "${FULL_IMAGE:?}"

sed -E "s|^([[:space:]]+image:).*registry\\.digitalocean\\.com.*|\\1 ${FULL_IMAGE}|" \
  "/tmp/${SERVICE}.yaml" > "/tmp/${SERVICE}.live.yaml"
kubectl apply -f "/tmp/${SERVICE}.live.yaml"

for p in $(kubectl -n eats-lab get pods -l "app=${SERVICE}" --no-headers 2>/dev/null | awk '$2 !~ /^1\// && $3 ~ /BackOff|ErrImage|ImagePull/ {print $1}'); do
  echo "Deleting stuck pod: $p"
  kubectl -n eats-lab delete pod "$p" --force --grace-period=0 2>/dev/null || true
done
