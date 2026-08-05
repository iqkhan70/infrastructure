# Eats lab — K3s on DigitalOcean

Same SSH / IP-file plumbing as the Kram Eats repo (`deploy/digitalocean/DROPLET_*`).
Create droplets with the **same SSH key** you already use for Eats. Add the same
`SSH_PRIVATE_KEY` GitHub Actions secret to this repo.

Production docker-compose in Eats stays untouched.

## Flow

```
Fill inventory/*_IP  →  push  →  Actions: Bootstrap K3s cluster
                                        ↓
                              SSH (same key as Eats)
                                        ↓
                              K3s master / workers
```

## Inventory (placeholders)

| File | Phase | Purpose |
|------|-------|---------|
| `inventory/MASTER_IP` | 1 | K3s server (control plane; also runs pods in learning mode) |
| `inventory/WORKER1_IP` | 4 | First worker |
| `inventory/WORKER2_IP` | 7 | Second worker |

Replace `YOUR_DROPLET_IP` with the real IP:

```bash
echo '203.0.113.10' > inventory/MASTER_IP
```

## One-time GitHub setup

1. Create this repo on GitHub and push.
2. Repo → Settings → Secrets and variables → Actions → New secret  
   Name: `SSH_PRIVATE_KEY`  
   Value: **same private key** as Eats (the one whose public key is on your DO account).
3. When creating the droplet in DigitalOcean, select that same SSH key.

## Bootstrap master (Phase 1)

1. Create an Ubuntu droplet (e.g. 2 vCPU / 2–4 GB).
2. Put its IP in `inventory/MASTER_IP`, commit, push.
3. Actions → **Bootstrap K3s cluster** → Run workflow → role = `master`.
4. Download the `kubeconfig` artifact (or run locally):

```bash
./scripts/fetch-kubeconfig.sh
export KUBECONFIG=$PWD/kubeconfig.yaml
kubectl get nodes
```

Or bootstrap from your laptop (same `~/.ssh/id_rsa` as Eats deploy):

```bash
./scripts/bootstrap-master.sh
./scripts/fetch-kubeconfig.sh
export KUBECONFIG=$PWD/kubeconfig.yaml
```

## Phase 1 deploy

```bash
kubectl apply -f k8s/phase1/
kubectl get nodes
kubectl get pods -n eats-lab -o wide
kubectl get deployments -n eats-lab
kubectl get services -n eats-lab
kubectl describe pod -n eats-lab <pod>
kubectl logs -n eats-lab <pod>
```

You should see **two catalog pods on the same node**. Do not add workers until
those commands are second nature.

## Later phases (plumbing already stubs them)

| Phase | Action |
|-------|--------|
| 4 | Fill `WORKER1_IP` → run workflow with role `worker1` → optionally `kubectl cordon` master |
| 7 | Fill `WORKER2_IP` → role `worker2` |
| CI/CD | Mirror Eats Actions: build → DOCR → `kubectl apply` / rollout (after week one) |

## Learning vs production scheduling

Master **runs workloads** by default (learning mode). When you want production-like:

```bash
kubectl cordon <master-node-name>
# or
kubectl taint nodes <master-node-name> node-role.kubernetes.io/control-plane=true:NoSchedule
```

## Gradual Compose → K8s (prod planning)

See [docs/COMPOSE_TO_K8S_MIGRATION.md](docs/COMPOSE_TO_K8S_MIGRATION.md) for service migration **order** (identity → catalog → …), hybrid cutover checklist, and what to change in Compose BFFs when pointing at K8s.

## Real Eats catalog (DOCR)


After `DOCR_TOKEN` is on this repo (same DigitalOcean API token style as Eats):

1. Commit/push `k8s/real-eats/` + `.github/workflows/deploy-real-catalog.yml`
2. Actions → **Deploy real Eats catalog (DOCR)** → Run workflow  
   - Tag: `catalog-service-production`
3. Open http://catalog.eats.local/swagger (hosts already point at master IP)

This also deploys **mysql** + **redis** in `eats-lab` (catalog’s real deps from compose). Lab GHCR stand-in is replaced.

## CI/CD into the lab (closes the architecture loop)

```text
git push → GitHub Actions → docker build → GHCR → SSH (same key as Eats) → kubectl apply / rollout
```

Workflow: `.github/workflows/deploy-lab.yml`  
App: `app/catalog/` (VERSION baked into `index.html` at build)

**One-time**

1. Push this repo; `SSH_PRIVATE_KEY` secret already used for bootstrap.
2. After the first successful build, set the GHCR package **Public**:  
   GitHub → Packages → `eats-lab-catalog` → Package settings → Change visibility.
3. Trigger **Deploy lab catalog** (`workflow_dispatch`) or push a change under `app/catalog/`.

Then:

```bash
curl -s http://catalog.eats.local/
# expect: catalog-<shortsha>
```
