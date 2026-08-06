#!/usr/bin/env bash
# Runs on the K3s master. Env: DOCR_TOKEN (required), NEEDS_RABBIT (0|1).
set -euo pipefail
: "${DOCR_TOKEN:?DOCR_TOKEN required}"
NEEDS_RABBIT="${NEEDS_RABBIT:-0}"

kubectl apply -f /tmp/00-namespace.yaml

kubectl -n eats-lab create secret docker-registry docr-cred \
  --docker-server=registry.digitalocean.com \
  --docker-username="$DOCR_TOKEN" \
  --docker-password="$DOCR_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# Split multi-doc yaml so we can skip Deployments when already Ready (avoids Recreate
# wiping ephemeral MySQL data / long cold starts on every CI run).
split_dir=$(mktemp -d)
trap 'rm -rf "$split_dir"' EXIT
export SPLIT_DIR="$split_dir"
awk '
  BEGIN { n=0; f=sprintf("%s/doc-%03d.yaml", ENVIRON["SPLIT_DIR"], n) }
  /^---$/ { close(f); n++; f=sprintf("%s/doc-%03d.yaml", ENVIRON["SPLIT_DIR"], n); next }
  { print > f }
' /tmp/00-mysql-redis.yaml

MYSQL_READY="$(kubectl -n eats-lab get deploy mysql -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
REDIS_READY="$(kubectl -n eats-lab get deploy redis -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"

for f in "$split_dir"/doc-*.yaml; do
  [ -s "$f" ] || continue
  kind=$(awk '/^kind:/{print $2; exit}' "$f")
  name=$(awk '/^metadata:/{p=1} p && /^  name:/{print $2; exit}' "$f")
  case "$kind" in
    Deployment)
      if [ "$name" = "mysql" ] && [ "${MYSQL_READY:-0}" = "1" ]; then
        echo "mysql already Ready — skip Deployment apply"
        continue
      fi
      if [ "$name" = "redis" ] && [ "${REDIS_READY:-0}" = "1" ]; then
        echo "redis already Ready — skip Deployment apply"
        continue
      fi
      ;;
  esac
  kubectl apply -f "$f"
done

if [ "$NEEDS_RABBIT" = "1" ]; then
  kubectl apply -f /tmp/00-rabbitmq-secret.yaml
  kubectl apply -f /tmp/rabbitmq-service.yaml
  kubectl apply -f /tmp/rabbitmq-ingress.yaml
  RABBIT_READY="$(kubectl -n eats-lab get deploy rabbitmq -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [ "${RABBIT_READY:-0}" = "1" ]; then
    echo "rabbitmq already Ready — skip redeploy"
  else
    for p in $(kubectl -n eats-lab get pods -l app=rabbitmq --no-headers 2>/dev/null | awk '$2 !~ /^1\// {print $1}'); do
      kubectl -n eats-lab delete pod "$p" --force --grace-period=0 2>/dev/null || true
    done
    kubectl apply -f /tmp/rabbitmq-deployment.yaml
  fi
fi
