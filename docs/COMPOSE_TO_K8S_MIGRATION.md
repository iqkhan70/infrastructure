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

## Database rule (lab vs real hybrid) — non-negotiable for actual cutover

We are **not** migrating the whole stack at once, so we **cannot** afford a second “prod” MySQL/Redis for services that move to K8s. Data stays where Compose already owns it.

### Lab (current catalog.eats.local) — OK for learning

| Piece | What we use today |
|-------|-------------------|
| Image | DOCR `kram:catalog-service-production` (real app bits) |
| MySQL | **In-cluster lab** Service `mysql` (`eats-lab`) |
| Connection | `ConnectionStrings__CatalogDb=server=mysql;…;database=traditional_eats_catalog;…` |
| Redis | In-cluster `redis:6379` |

Separate lab DB is **good** for experiments without touching live menus/users.

**Do not** point lab catalog at prod MySQL until CatalogService supports skipping seed/migrate (e.g. `SEED_DATA=false`) in a **rebuilt** DOCR image — every pod start currently runs `Migrate()` + category ensure seed. Secret template for later: `k8s/real-eats/eats-prod-mysql.secret.example.yaml`.

### Real / hybrid work — must use prod data plane

When we start **actual** cutover (Identity/Catalog serving real traffic):

```text
K8s Pods (identity / catalog / …)
        │
        │  ConnectionStrings* / Redis__* / RabbitMQ__*
        ▼
Prod Compose droplet (or managed later)
  ├── mysql   (traditional_eats_identity, traditional_eats_catalog, …)
  ├── redis
  └── rabbitmq   (shared MassTransit bus — stays until almost everything has moved)
```

**Rules**

1. **One source of truth for SQL.** Prod MySQL stays on the Compose env (until we deliberately move the DB later — not part of early waves).
2. **K8s apps point at that MySQL** via connection strings (host = prod DB reachable address — private IP, VPN, or DO private network — **not** the lab ClusterDNS name `mysql`).
3. **Same database names** Compose already uses (`traditional_eats_identity`, `traditional_eats_catalog`, etc.).
4. **No dual-write.** Stop the Compose container for a moved service so only K8s pods write that schema (BFFs still on Compose call K8s URLs).
5. **Firewall / network first.** Cluster workers must be allowed to reach prod MySQL:3306 (and Redis) before flipping BFF URLs.

### RabbitMQ — same shared-bus rule

Compose already runs **one** RabbitMQ that MassTransit publishers/consumers use (`RabbitMQ__HostName: rabbitmq`, shared user/password). While any consumer or publisher remains on Compose and others move to K8s, they **must share that broker** — otherwise you get a split brain: Identity on K8s publishes to lab Rabbit while Order on Compose never sees the message.

| Phase | RabbitMQ |
|-------|----------|
| **Lab only** | Optional in-cluster Rabbit (we used one for MassTransit demos). Fine for learning; **not** for hybrid prod traffic. |
| **Hybrid (Identity/Catalog/… on K8s, rest on Compose)** | **Prod Compose RabbitMQ stays.** K8s pods set `RabbitMQ__HostName` (or equivalent) to a host the cluster can reach — prod droplet private IP / DNS — plus the **same** user/password/vhost as Compose `.env`. Open AMQP **5672** (and management only if needed) from workers → prod. |
| **Later** | Move Rabbit to managed (DO/CloudAMQP) or K8s **only when** almost all MassTransit clients live on the new side — still one broker, cut DNS/env once. |

**Do not** run Compose Rabbit **and** a second “prod” Rabbit for migrated services. Dual brokers without a bridge = lost events (notifications, order workflows, etc.).

Services that use Rabbit today (from Compose): identity, order, customer, notification, chat, and others with `RabbitMQ__HostName` — all stay on the **same** hostname until you intentionally migrate the broker.

**Why this matters for gradual migration**

- BFFs, orders, and other Compose services keep reading/writing the **same** tables **and** consuming the **same** queues/exchanges.
- Moving only compute (Identity/Catalog processes) onto K8s for HPA would fork data **or** messaging if we used a separate SQL **or** a separate Rabbit.
- Lab MySQL/Rabbit in this repo stay for demos only; Wave 1+ replaces those connection strings / hostnames with **prod** hosts.

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

### 3. Same data plane (prod MySQL stays; K8s only runs the app)

See **Database rule** above. Summary for cutover day:

- K8s Identity/Catalog connection strings → **prod** MySQL/Redis (Compose droplet), **not** lab `server=mysql`.
- Same DB names as Compose (`traditional_eats_identity`, `traditional_eats_catalog`, …).
- Cluster network open to that MySQL/Redis.
- Do **not** provision a second production SQL “for K8s” while other services remain on Compose.

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
| **0 – Lab** | Catalog (DOCR image, **lab** MySQL/Redis/Ingress) | None to real prod. Safe sandbox. |
| **1 – First hybrid** | Identity + Catalog (**prod** MySQL/Redis connection strings) | BFF/chat URL env; stop Compose identity+catalog; open DB network path; Ingress hostnames. |
| **2 – Read path** | Restaurant | BFF `Services__RestaurantService` (+ any HttpClients). |
| **3 – Write spikes** | Order | BFF + payment/order callers; careful with payment coupling. |
| **4 – Edge aggregators** | BFFs (optional) | Edge upstreams; larger blast radius. |
| **Later** | Chat, notification, payment, AI, docs/reviews, edge | As metrics demand. |

---

## Explicit non-goals (for now)

- Rewriting all services onto K8s at once.
- Moving MySQL/Rabbit “because K8s” before apps need it.
- Running a **separate production SQL** or **separate production RabbitMQ** for K8s-moved services while Compose still owns the rest of the product.
- Treating catalog lab (Development + in-cluster lab MySQL) as production cutover.

---

## Related paths in this repo

- Lab catalog (learning): `k8s/phase1` … `k8s/phase10`, `k8s/cicd`
- Real DOCR catalog on lab cluster: `k8s/real-eats/`, `.github/workflows/deploy-real-catalog.yml`
- Cluster bootstrap: `.github/workflows/bootstrap-cluster.yml`, `inventory/`
