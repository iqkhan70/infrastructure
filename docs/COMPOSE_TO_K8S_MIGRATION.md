# Gradual Compose → Kubernetes migration

Keep **Eats production Docker Compose untouched** as the system of record. Move services to K8s only when horizontal scale matters. Prefer a **hybrid** cutover: BFFs/edge stay on Compose; hot services run on K8s; Compose containers for those services are stopped once traffic is pointed at the cluster.

**Priorities for this business right now**

- Horizontal scaling plumbing > fancy multi-region HA.
- Manual restart is acceptable.
- No big-bang rewrite.

---

## Migration order (highest load / scale impact first)

| Priority | Service | Why |
|----------|---------|-----|
| **1** | **identity-service** | Login/register/refresh storms; central session path. Best first HPA candidate. |
| **2** | **catalog-service** | Menu/browse is read-heavy; scales out cleanly. Lab/DOCR path already proven. |
| **3** | **restaurant-service** | Home/search/list traffic — read-mostly, same pattern as catalog. |
| **4** | **order-service** | Meal-time spikes; write-heavy and couples to payment — after identity + reads are stable. |
| **5** | **web-bff / mobile-bff** | Every client request funnels here; move when BFF CPU is the bottleneck. Higher blast radius (all routes). |
| **6** | **chat-service** | Concurrent connections / sockets scale differently from REST. |
| **7** | **notification-service** | Bursty via RabbitMQ; scale for event storms, not page load. |
| **8** | **customer-service** | Steady but usually behind identity/BFF. |
| **9** | **payment-service** | Critical, but move late among money paths (blast radius / Stripe coupling). |
| **10** | **ai-service** | Costly per call, often lower QPS until AI traffic is real. |
| **11** | **document-service / review-service** | Lower or optional traffic. |
| **12** | **edge** | Keep on Compose longest as the single public front door. |
| **—** | **mysql / redis / rabbitmq** | Do **not** move “for app scale” first. Scaled apps should talk to the **existing** shared data plane (or managed later). |

**First two for a real hybrid cutover:** **identity** + **catalog**  
(or identity + restaurant if list/search load dominates menus).

Lab work so far (catalog on K3s) is learning + DOCR plumbing — not yet a prod cutover.

---

## Target hybrid shape (after first two services)

```text
Users → edge (Compose) → web-bff / mobile-bff (Compose)
                            ├─ identity  → K8s (replicas + HPA)
                            ├─ catalog   → K8s (replicas + HPA)
                            └─ others    → Compose (for now)
```

Compose remains the default and the **fast rollback** path.

---

## Cutover checklist (per service moved to K8s)

When Identity and/or Catalog go live on K8s, Compose must **call the new endpoints** and **stop the old containers**. Deploying to K8s alone is not enough.

### 1. Stable URLs

Give each moved service a durable address (Ingress / LB), e.g.:

- `https://identity.<domain>`
- `https://catalog.<domain>`

Do not rely on Docker DNS names (`identity-service`) from outside the Compose network, or bare droplet IPs long term.

### 2. Point callers at those URLs

Update Compose env (`.env` / `docker-compose.prod.yml` substitutions). At minimum for **identity + catalog**:

| Caller | Settings to change |
|--------|--------------------|
| **web-bff** | `Services__IdentityService`, `Services__CatalogService` |
| **mobile-bff** | `Services__IdentityService`, `Services__CatalogService` |
| **chat-service** | `HttpClients__IdentityService__BaseAddress` (calls identity today) |

Today these default to Compose DNS, e.g.:

- `http://identity-service:5000`
- `http://catalog-service:5003`

After cutover they become the K8s Ingress/LB base URLs.

Any other service that hardcodes those Docker hostnames must be updated the same way.

### 3. Same data plane

K8s workloads must use the **same** databases and Redis as prod Compose:

- Identity → `traditional_eats_identity` (same MySQL)
- Catalog → `traditional_eats_catalog` (same MySQL)
- Shared Redis as configured in prod

Cluster nodes need network reachability to that MySQL/Redis (firewall / private network). Do **not** stand up a second empty DB for “prod” traffic.

### 4. Same secrets / auth contract

Align JWT issuer/audience/secret, connection strings, and internal API keys so tokens and service-to-service calls keep working. You are swapping **where** the process runs, not the API contract.

### 5. Disable only the Compose siblings

After BFFs talk to K8s successfully:

```bash
# example — stop only what you moved
docker compose -f deploy/digitalocean/docker-compose.prod.yml stop identity-service catalog-service
```

Leave **edge**, **BFFs**, other microservices, **mysql**, **redis**, **rabbitmq** running. Avoid two identities (or two catalogs) writing at once.

### 6. Smoke test + rollback

**Smoke:** login/refresh, a catalog read via BFF/edge, health checks.

**Rollback:**

1. Point env URLs back to `http://identity-service:5000` / `http://catalog-service:5003`.
2. `docker compose … start identity-service catalog-service` (or `up -d`).
3. Restart BFFs so they pick up env.

### 7. K8s side (horizontal plumbing)

For each migrated service:

- `replicas` ≥ 2
- `topologySpreadConstraints` (or equivalent) across workers
- readiness + liveness probes
- resource requests/limits
- HPA when metrics are trusted (CPU/RPS)

That is the “if we suddenly get big” lever — without migrating the whole mesh.

---

## Suggested waves

| Wave | Move to K8s | Prod changes |
|------|-------------|--------------|
| **0 – Lab** | Catalog (DOCR image, lab DB/Ingress) | None to real prod. Done for learning. |
| **1 – First hybrid** | Identity + Catalog (prod DB/Redis) | BFF/chat URL env; stop Compose identity+catalog; Ingress hostnames. |
| **2 – Read path** | Restaurant | BFF `Services__RestaurantService` (+ any HttpClients). |
| **3 – Write spikes** | Order | BFF + payment/order callers; careful with payment coupling. |
| **4 – Edge aggregators** | BFFs (optional) | Edge upstreams; larger blast radius. |
| **Later** | Chat, notification, payment, AI, docs/reviews, edge | As metrics demand. |

---

## Explicit non-goals (for now)

- Rewriting all services onto K8s at once.
- Moving MySQL/Rabbit “because K8s” before apps need it.
- Treating catalog lab (Development + separate lab MySQL) as production cutover.

---

## Related paths in this repo

- Lab catalog (learning): `k8s/phase1` … `k8s/phase10`, `k8s/cicd`
- Real DOCR catalog on lab cluster: `k8s/real-eats/`, `.github/workflows/deploy-real-catalog.yml`
- Cluster bootstrap: `.github/workflows/bootstrap-cluster.yml`, `inventory/`
