# Bookmark Deployment — Architecture & Runbook

> Tài liệu này dành cho **operator** (người deploy + troubleshoot).
> Nếu bạn muốn hiểu code app, xem repo [bookmark-management](https://github.com/jaimesHub/bookmark-management).

---

## 1. Overview

**Bookmark App** là URL shortener với UI: nhập URL dài qua web UI → nhận short code → 302 redirect khi access short URL.

**Deployment topology**: 4 service chạy trên 1 VM qua `docker-compose`:

- `nginx` — reverse proxy edge, là service **duy nhất** expose ra internet (port 80). Route theo path prefix.
- `portal` — SolidStart SSR frontend (instructor-provided image `ebvn/bookmark-app-portal:mono`)
- `api` — Go application server (image pull từ Docker Hub, pin SHA)
- `redis` — persistence layer (named volume cho data, AOF enabled)

**Vì sao tách 2 repo** (`bookmark-management` vs `bookmark-deployment`):

- **Khác lifecycle**: app deploy nhiều lần/tuần, infra config thay đổi vài lần/tháng
- **Khác permission boundary**: dev team (commit app repo) vs ops team (commit deployment repo)
- **Rollback độc lập**: đổi image version không ảnh hưởng nginx config và ngược lại

---

## 2. System Diagram

```
                              Internet
                                 │
                                 ▼ (port 80, public)
                        ┌────────────────┐
                        │     nginx      │  bookmark-nginx
                        │  :80 (host)    │  reverse proxy
                        │  :80 (cont.)   │  routing theo path prefix
                        └────────┬───────┘
                                 │
                docker network "bookmark-internal" (bridge)
                                 │
         ┌───────────────┬───────┴──────────┬───────────────┐
         │               │                  │               │
         ▼               ▼                  ▼               ▼
   ┌──────────┐   ┌──────────┐        ┌──────────┐   ┌──────────┐
   │  portal  │   │   api    │ ──────▶│  redis   │   │  (api    │
   │  :3000   │   │  :8080   │ STORE  │  :6379   │   │  serves  │
   │ (expose) │   │ (expose) │ ◀──────│ (expose) │   │  /v1/*)  │
   └──────────┘   └──────────┘  READ  └─────┬────┘   └──────────┘
   bookmark-      bookmark-api              │
   portal         Image:                    ▼
   Image:         jaimes96/                 ┌──────────────┐
   ebvn/          bookmark-app:<sha>        │ named volume │
   bookmark-app-                            │ redis-data   │
   portal:mono                              │ (AOF persist)│
   (SolidStart                              └──────────────┘
    SSR)

   ▣ nginx routing (path-based):
       /                              → portal (FE catch-all)
       /assets/*                      → portal (FE static)
       /bookmark_service/v1/*         → strip prefix → api/v1/*
       /v1/links/redirect/*           → api (passthrough, short URL access)
       /health-check                  → api (ops/healthcheck)

   ▣ Port public ra Internet:   chỉ port 80 (nginx)
   ▣ Cloud firewall + UFW:     allow 22 (SSH) + 80 (HTTP)
   ▣ portal/api/redis:          chỉ reachable trong network nội bộ
                                → "expose:" KHÔNG "ports:" trong docker-compose
```

### 📌 Post-Lec-6 addition (Postgres + RSA)

```
                              Internet
                                 │
                                 ▼ (port 80, public)
                              nginx
                                 │
                 docker network "bookmark-internal"
                                 │
         ┌─────────┬────────┬────┴────┬──────────┐
         ▼         ▼        ▼         ▼          ▼
      portal    api    redis     postgres    (nginx ↑)
                 │        │         │
                 │        │         ▼
                 │        │      ┌─────────────────┐
                 │        ▼      │ postgres-data   │
                 │   ┌────────┐  │ (users, auth)   │
                 │   │redis-  │  │ [NEW Lec-6]     │
                 │   │data    │  └─────────────────┘
                 │   │(AOF)   │
                 │   └────────┘
                 │
                 ▼ (bind-mount :ro)
         ┌────────────────────────────────┐
         │ /opt/bookmark-deployment/keys/ │ host VM
         │   ├── private.pem (chmod 0644) │ → /app/keys/private.pem
         │   └── public.pem  (chmod 0644) │ → /app/keys/public.pem
         │ [NEW Lec-6 RSA load eager-fail]│ (read-only mount)
         └────────────────────────────────┘
```

**Lec-6 changes**:
- ➕ Service `postgres:16-alpine` — persistence cho `users` table (AutoMigrate trong app `main` runs on startup)
- ➕ Mount RSA keys `:ro` từ host → container `/app/keys/` (eager-load on app startup, fail-fast nếu thiếu)
- ➕ Network: postgres reachable nội bộ qua `bookmark-internal` (KHÔNG `ports:`, chỉ `expose: 5432`)
- ➕ Volume named: `bookmark-postgres-data` (survive `docker compose down`, mất khi `down -v` — pattern giống redis)
- 🔄 Redis memory limit: 96M → 64M (nhường RAM cho postgres 192M, VM 1GB headroom tight)

### Service responsibility

| Service | Role | Host port | Container port | Image |
|---|---|---|---|---|
| **nginx** | Reverse proxy + path routing (future: TLS termination) | 80 | 80 | `nginx:1.27-alpine` |
| **portal** | Frontend SSR (SolidStart) — UI shorten + login | (none) | 3000 | `ebvn/bookmark-app-portal:${PORTAL_VERSION}` |
| **api** | Business logic, HTTP handlers | (none) | 8080 | `${DOCKER_USER}/bookmark-app:${APP_VERSION}` |
| **redis** | Key-value store (short_code → long_url) | (none) | 6379 | `redis:7-alpine` |
| **postgres** | User/auth data persistence (users table — Lec-6 NEW) | (none — internal only) | 5432 | `postgres:16-alpine` |

### Network isolation

API và Redis dùng **`expose:`** thay vì **`ports:`** trong `docker-compose.yml` → KHÔNG bind lên host interface → KHÔNG reachable từ host hoặc internet, **chỉ** từ container khác trong cùng network `bookmark-internal`.

Đây là **defense-in-depth**: ngay cả khi UFW + cloud firewall sai cấu hình, port 8080/6379 vẫn không expose ra ngoài vì Docker không publish.

### Resource limits

Stack chạy được trên VM 1GB RAM:

| Service | CPU limit | Memory limit | Memory actual (load nhẹ) |
|---|---|---|---|
| api | 0.5 | 192M | ~20–60 MiB |
| portal | 0.3 | 128M | ~68 MiB |
| redis | 0.3 | 96M | ~10 MiB |
| nginx | 0.2 | 48M | ~9 MiB |
| **Total container** | 1.3 | **464M** | ~146 MiB |
| Docker daemon | — | ~95M peak | — |

Đã giảm 25% backend baseline (256/128/64 MiB) sau pre-flight. Portal thêm 128M với headroom 2x so với idle 68MiB. VM available 503Mi → buffer ~40 MiB sau khi up đủ stack (tight nhưng feasible).

---

## 3. Prerequisites

### Trên máy operator (để deploy + verify)

- `git` — clone repo
- `ssh` — connect tới VM
- `curl` + `jq` — verify endpoint
- (Optional, nếu build image ARM Mac → amd64 VM) `docker` + `docker buildx`

### Trên VM (target deployment)

- **OS**: Ubuntu 22.04 LTS hoặc 24.04 LTS
- **vCPU**: 1 tối thiểu, 2 khuyến nghị
- **RAM**: 1 GB tối thiểu (≥ 470 MiB available), 2 GB khuyến nghị
- **Disk**: 10 GB tối thiểu, 20 GB khuyến nghị
- **Public IP** (hoặc domain) cho HTTP access
- **SSH access** với quyền sudo hoặc root
- **Cloud firewall** (nếu VM ở cloud provider): allow inbound 22 + 80

### Tool cài trên VM (Task #3 cài tự động qua `apt`)

- `docker.io` — Docker Engine 24+
- `docker-compose-v2` — CLI plugin `docker compose`
- `git`
- `ufw` — host firewall

---

## 4. Quick Start

### A. Local (test stack qua localhost trước khi deploy VM)

```bash
# Clone deployment repo
git clone https://github.com/jaimesHub/bookmark-deployment.git
cd bookmark-deployment

# Setup env (defaults OK cho local)
cp .env.example .env

# Start stack
make up

# Đợi services healthy (~15s)
make ps

# Verify health-check qua nginx
make health
# Expect: {"message":"OK","service_name":"bookmark-app","hostname":"bookmark-local-dev",...}

# Test FE qua browser
open http://localhost/
# Expect: SolidStart UI hiện form "Enter your url here" + nút Generate

# Test E2E — shorten URL theo FE path (nginx rewrite prefix)
curl -s -X POST http://localhost/bookmark_service/v1/links/shorten \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","exp":3600}'
# Expect: {"code":"XXXXXXX","message":"Shorten URL generated successfully!"}

# Test redirect (direct API path, không qua FE prefix)
curl -i http://localhost/v1/links/redirect/<CODE>
# Expect: HTTP 302, Location: https://example.com

# Stop (giữ Redis data)
make down
```

### B. Production VM

```bash
# SSH vào VM
ssh root@<vm-ip>

# Cài Docker + tools
apt update
apt install -y docker.io docker-compose-v2 git ufw

# Firewall — CHÚ Ý THỨ TỰ (allow 22 TRƯỚC enable)
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP nginx'
ufw --force enable

# Enable Docker boot
systemctl enable docker

# Clone repo
mkdir -p /opt && cd /opt
git clone https://github.com/jaimesHub/bookmark-deployment.git
cd bookmark-deployment

# Setup .env (CRITICAL: pin SHA cho APP_VERSION, không dùng latest)
cp .env.example .env
nano .env
# Sửa: DOCKER_USER, APP_VERSION=<sha>, APP_HOSTNAME=<vm-name>

# Bảo vệ secrets
chmod 600 .env

# Pull image + start
docker compose pull
docker compose up -d

# Verify
docker compose ps   # 3 services healthy
curl http://localhost/health-check
```

### C. Update image (after new app version pushed to Hub)

```bash
cd /opt/bookmark-deployment
nano .env                # Sửa APP_VERSION=<new-sha>
docker compose pull      # Pull image mới
docker compose up -d     # Recreate api container, no downtime cho nginx/redis
docker compose ps        # Verify healthy
```

### D. Rollback (nếu version mới gặp issue)

```bash
nano .env                # Sửa APP_VERSION về SHA stable trước đó
docker compose pull && docker compose up -d
```

---

## 5. Environment Variables

| Variable | Required | Default | Mô tả |
|---|---|---|---|
| `DOCKER_USER` | ✅ Yes | — | Docker Hub username — nơi pull image API. VD: `jaimes96` |
| `APP_VERSION` | ⚠️ Recommended | `latest` | Tag image API. **Production phải pin SHA cụ thể** (vd: `114e407`), KHÔNG dùng `latest` |
| `PORTAL_VERSION` | ❌ Optional | `mono` | Tag image FE (`ebvn/bookmark-app-portal`). Instructor-provided image, mặc định `mono` |
| `APP_HOSTNAME` | ✅ Yes | — | Tên định danh instance, xuất hiện trong response `/health-check`. Local: `bookmark-local-dev`. Prod: `bookmark-prod-vm1` |
| `SERVICE_NAME` | ❌ Optional | `bookmark-app` | Tên service trong log Zerolog |
| `LOG_LEVEL` | ❌ Optional | `info` | `debug`, `info`, `warn`, `error`. Map vào `API_LOG_LEVEL` của app |
| `APP_ENV` | ❌ Optional | `prod` | `prod` = JSON log structured, `dev` = console pretty-print. Map vào `API_APP_ENV` |
| `NGINX_HOST_PORT` | ❌ Optional | `80` | Port host map ra cho nginx. Đổi nếu port 80 bận (vd `8080`) |
| `POSTGRES_USER` (Lec-6) | ✅ Yes | `bookmark` | DB user. KHÔNG dùng `postgres` (superuser) cho app conn |
| `POSTGRES_PASSWORD` (Lec-6) | ✅ Yes | — | **Strong password ≥ 24 chars random**. Generate: `openssl rand -base64 32 \| tr -d '/+=' \| head -c 32` |
| `POSTGRES_DB` (Lec-6) | ✅ Yes | `bookmark` | Database name — match `DB_NAME` trong api env block |
| `BCRYPT_COST` (Lec-6) | ❌ Optional | `12` | PROD = 12 (~250ms). Đừng giảm xuống dưới 10 (security regression) |
| `RSA_PRIVATE_KEY_PATH` (Lec-6, app env only) | ✅ Yes (PROD) | — | **PROD MUST absolute** `/app/keys/private.pem`. Defense-in-depth tránh future Dockerfile WORKDIR drift |
| `RSA_PUBLIC_KEY_PATH` (Lec-6, app env only) | ✅ Yes (PROD) | — | Symmetric với private. PROD absolute `/app/keys/public.pem` |

### ⚠️ Vì sao `APP_VERSION` nên là SHA, không phải `latest`

- **`latest` không có lịch sử** — không biết VM đang chạy bản nào, không audit-able
- **Rollback dễ dàng**: chỉ cần đổi `APP_VERSION` về SHA bản trước, `make pull && make up -d`
- **Audit trail**: `git log` của repo deployment cho thấy mỗi lần đổi version

### ⚠️ Envconfig prefix mapping

App `bookmark-app` đọc env var theo `envconfig` library với 2 prefix khác nhau (xem source code `internal/api/config.go` + `pkg/redis/config.go`):

| Env var trong compose | Tag trong code | Prefix app code |
|---|---|---|
| `REDIS_ADDR` | `REDIS_ADDR` | "" (rỗng) |
| `SERVICE_NAME` | `SERVICE_NAME` | "" (rỗng) |
| `APP_HOSTNAME` | `APP_HOSTNAME` | "" (rỗng) |
| `API_CONTAINER_PORT` | `CONTAINER_PORT` | `api` (→ `API_CONTAINER_PORT`) |
| `API_LOG_LEVEL` | `LOG_LEVEL` | `api` |
| `API_APP_ENV` | `APP_ENV` | `api` |

→ `.env` dùng tên ngắn (`LOG_LEVEL`, `APP_ENV`), compose tự convert sang tên đầy đủ có prefix khi inject vào container. Xem `docker-compose.yml` block `environment:` để hiểu mapping.

---

## 6. Troubleshooting

### 🔴 6.1 — Container Exited ngay khi `up`

**Triệu chứng**: `docker compose ps` thấy STATUS = `Exited (X)` ngay sau `make up`.

**Debug**:
```bash
docker compose logs <service-name> --tail=50
docker inspect <container-name> --format='{{.State.ExitCode}} - {{.State.Error}}'
```

**Nguyên nhân thường gặp**:
- **API**: env var sai → app exit khi load config. Check `.env` có đủ `DOCKER_USER`, `APP_VERSION`, `APP_HOSTNAME`.
- **API**: image platform mismatch — log có "exec format error" → image build cho ARM nhưng VM AMD (xem **6.5**).
- **Nginx**: `default.conf` syntax sai → exit 1 với message rõ ràng trong log.
- **Redis**: nếu mount volume sai permission → exit. Verify `docker volume inspect bookmark-redis-data`.

---

### 🟡 6.2 — API container `(unhealthy)` với log "404 HEAD /health-check"

**Triệu chứng**: `docker compose ps` thấy api `Up X minutes (unhealthy)`. `docker compose logs api` có dòng `[GIN] HEAD "/health-check" | 404`.

**Root cause** (đã gặp ở Task #2 Step 8): Healthcheck dùng `wget --spider` → wget gửi **HEAD** request, nhưng Gin chỉ tự đăng ký **GET** handler → trả 404 → wget exit 8 → container marked unhealthy.

**Fix**: Trong `docker-compose.yml`, healthcheck KHÔNG dùng `--spider`. Dùng:
```yaml
test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:8080/health-check"]
```

`-O /dev/null` discard response body nhưng vẫn là GET method. Verify:
```bash
docker exec bookmark-api wget -q -O /dev/null http://localhost:8080/health-check
echo $?   # 0 = OK
```

---

### 🟡 6.3 — API healthcheck trả 500 "redis: connection refused [::1]:6379"

**Triệu chứng**: api `(unhealthy)`, log có `redis: failed to dial tcp [::1]:6379: connect: connection refused`.

**Root cause** (đã gặp ở Task #2 Step 8): App đọc env tag `REDIS_ADDR` (host:port format, không phải URL scheme). Nếu compose dùng `REDIS_URL: redis://redis:6379` → app không pickup → fallback default `localhost:6379` → fail vì không có redis trên localhost của container api.

**Fix**: Trong `docker-compose.yml` block `api.environment`:
```yaml
REDIS_ADDR: redis:6379           # ✅ KHÔNG phải REDIS_URL
API_CONTAINER_PORT: 8080         # ✅ Có prefix API_
API_LOG_LEVEL: ${LOG_LEVEL:-info}
API_APP_ENV: ${APP_ENV:-prod}
```

**Lý do prefix `API_`**: code dùng `envconfig.Process("api", cfg)` → tag `CONTAINER_PORT` resolve thành env `API_CONTAINER_PORT`. Trace ngược caller trong `internal/api/config.go` để verify prefix.

---

### 🟡 6.4 — Nginx `(unhealthy)` với "Connection refused" dù curl từ host OK

**Triệu chứng**: nginx `(unhealthy)`, nhưng `curl http://localhost/health-check` từ host VM trả 200 OK.

**Root cause** (đã gặp ở Task #2 Step 8): BusyBox wget trong `nginx:alpine` resolve `localhost` → `::1` (IPv6) trước. Nginx default `listen 80;` chỉ bind **IPv4** → wget connection refused.

**Fix**: Dùng `127.0.0.1` thay vì `localhost` trong healthcheck:
```yaml
test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1/health-check"]
```

---

### 🔴 6.5 — `docker compose pull` báo "no matching manifest for linux/amd64"

**Triệu chứng**: 
```
no matching manifest for linux/amd64 in the manifest list entries: 
no match for platform in manifest: not found
```

**Root cause** (đã gặp ở Task #3 Step 5): Image build trên Mac Apple Silicon mặc định cho **linux/arm64**. VM Ubuntu x86_64 cần **linux/amd64** manifest → không tìm thấy → pull fail.

**Fix**: Rebuild image với explicit platform + push lại:
```bash
# Trên máy build (Mac)
cd <app-repo>
docker buildx build \
  --platform linux/amd64 \
  -t <user>/bookmark-app:<sha> \
  -t <user>/bookmark-app:latest \
  --push \
  .

# Verify manifest có amd64
docker buildx imagetools inspect <user>/bookmark-app:<sha>
# Expect: Platform: linux/amd64

# Trên VM, retry
docker compose pull
```

**Multi-arch alternative** (chạy được cả Mac arm64 dev + VM amd64 prod):
```bash
docker buildx build --platform linux/amd64,linux/arm64 ...
```

Chậm hơn (QEMU emulate platform không phải host) nhưng image chạy được cả 2.

---

### 🟢 6.6 — Endpoint trả 502 Bad Gateway

**Triệu chứng**: `curl http://<vm>/health-check` → `502 Bad Gateway`.

**Nguyên nhân**: nginx live nhưng api **chưa healthy** hoặc đang restart.

**Debug**:
```bash
docker compose ps                                              # Api có healthy không?
docker compose logs api --tail=30                              # Error gì?
docker exec bookmark-nginx wget -q -O /dev/null http://api:8080/health-check
echo $?                                                        # Từ nginx call api được không?
```

**Fix**: Đợi api healthy (có thể mất 10-15s sau `up`). Nếu vẫn fail → debug api theo **6.2** / **6.3**.

---

### 🟢 6.7 — Port 80 đã bị dùng (`bind: address already in use`)

**Triệu chứng**: `make up` báo:
```
Error: ports are not available: bind: address already in use
```

**Debug**:
```bash
sudo lsof -i :80
# Hoặc: sudo ss -tlnp | grep :80
```

**Fix** (2 options):
1. Stop service đang chiếm: `sudo systemctl stop apache2` (hoặc nginx system)
2. Đổi `NGINX_HOST_PORT=8080` trong `.env` → truy cập qua `http://<ip>:8080/`

---

### 🟡 6.9 — FE load OK nhưng nút Generate không trả response (CORS / 404 / 502)

**Triệu chứng**: Browser mở `http://<host>/` thấy UI SolidStart, nhập URL + click Generate → không có short code, browser console có error.

**Debug** (browser DevTools Network tab):
- Request URL có dạng `http://<host>/bookmark_service/v1/links/shorten` không?
- Status code? 200/404/502/CORS?

**Nguyên nhân thường gặp**:
- **404**: nginx `default.conf` thiếu `location /bookmark_service/` block hoặc rewrite sai. Verify:
  ```bash
  docker exec bookmark-nginx cat /etc/nginx/conf.d/default.conf | grep -A3 bookmark_service
  ```
- **502 Bad Gateway**: api chưa healthy hoặc nginx rewrite path sai. Test rewrite:
  ```bash
  docker exec bookmark-nginx wget -O - http://api:8080/v1/links/shorten -d ... # xem api có resolve được không
  ```
- **CORS**: FE + BE cùng host (qua nginx) nên KHÔNG có CORS issue. Nếu thấy CORS error → có ai đó dùng IP khác giữa FE và API gọi.

**Fix**: Xem **6.2** / **6.3** nếu api unhealthy. Xem `nginx/default.conf` location `/bookmark_service/` đã có `rewrite` chưa.

---

### 🟢 6.10 — Portal container `(unhealthy)` hoặc OOM kill

**Triệu chứng**: `docker compose ps` thấy `bookmark-portal` `(unhealthy)` hoặc `Exited (137)` (OOM kill).

**Debug**:
```bash
docker compose logs portal --tail=50
docker inspect bookmark-portal --format='{{.State.OOMKilled}}'  # true nếu OOM
docker stats bookmark-portal --no-stream
```

**Nguyên nhân thường gặp**:
- **OOM kill** (exit 137): Memory limit 128M quá tight. Idle ~68MB nhưng spike khi SSR render. Fix: tăng `deploy.resources.limits.memory` lên 192M trong compose. Nếu VM quá tight RAM → giảm limit api (chỉ dùng 20-60MB).
- **Healthcheck fail** (Node script không chạy được): Image alpine? Verify `node -e ...` syntax. Có thể fallback dùng `wget`:
  ```yaml
  test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:3000/"]
  ```
- **Cold-start lâu**: SolidStart SSR có thể mất 15-20s. Tăng `start_period: 30s`.

---

### 🟢 6.8 — Data Redis mất sau `down && up`

**Triệu chứng**: Tạo short URL → `make down` → `make up` → redirect 404.

**Nguyên nhân**: User dùng `make down-clean` (= `docker compose down -v`) thay vì `make down`. Cờ `-v` xoá volume.

**Fix**: Dùng `make down` (không `-v`). Verify volume tồn tại:
```bash
docker volume ls | grep bookmark
docker volume inspect bookmark-redis-data
```

Nếu volume đã xoá → data mất vĩnh viễn. Cần test rollback từ backup (nếu có — xem **Hardening Checklist** § 7).

---

### 🔴 6.11 — api `(unhealthy)` với log "failed to connect to postgres" (Lec-6 NEW)

**Triệu chứng**: api container `(unhealthy)` hoặc `Exited (1)`, log có dòng tương tự `failed to connect: dial tcp postgres:5432: connect: connection refused` hoặc `password authentication failed for user "bookmark"`.

**Root cause**: Postgres chưa healthy, hoặc credentials trong `.env` không khớp với password lúc init Postgres volume.

**Debug**:
```bash
docker compose logs postgres --tail=20                                    # Postgres init ok?
docker exec bookmark-postgres pg_isready -U bookmark -d bookmark -h 127.0.0.1
docker exec bookmark-api env | grep DB_                                    # api thấy đúng env?
```

**Fix**:
- Nếu Postgres chưa healthy → wait 20-30s (cold start init data dir lần đầu), retry.
- Nếu `password authentication failed`: `.env` `POSTGRES_PASSWORD` đã bị đổi sau khi volume tạo → Postgres reject login. Sửa 1 trong 2 cách:
  ```bash
  # A. Reset password trong DB (khuyến nghị — giữ data)
  docker exec bookmark-postgres psql -U postgres -c "ALTER USER bookmark PASSWORD '<new>';"

  # B. Recreate volume (DESTRUCTIVE — mất hết data)
  docker compose down -v
  docker compose up -d
  ```

---

### 🔴 6.12 — api exit on startup với "load rsa keys: no such file" (Lec-6 NEW)

**Triệu chứng**: api `Exited (1)` ngay sau `up`, log có `FTL ... load rsa keys error="..." private_path=/app/keys/private.pem`.

**Root cause**: Keys chưa tồn tại trên host VM, hoặc mount path/permission sai.

**Debug**:
```bash
ls -la /opt/bookmark-deployment/keys/                       # Host: files có không + chmod?
docker exec bookmark-api ls -la /app/keys/                  # Container: mount đến nơi?
docker exec bookmark-api id                                  # Container user: app (non-root)?
```

**Fix**: Re-run VM provisioning (T16 — xem `assignments/t16-vm-provisioning-execution.md` Bước 3 + 4):
```bash
cd /opt/bookmark-deployment
sudo mkdir -p keys
sudo openssl genpkey -algorithm RSA -out keys/private.pem -pkeyopt rsa_keygen_bits:2048
sudo openssl rsa -pubout -in keys/private.pem -out keys/public.pem
sudo chown root:root keys/private.pem keys/public.pem
sudo chmod 0644 keys/private.pem keys/public.pem            # 0644 (KHÔNG 0600 — container user `app` non-root)
docker compose up -d --force-recreate api
```

**⚠️ Trap chmod**: chmod 0600 sẽ làm container user `app` không đọc được → app exit "permission denied" → dùng **0644** cho Lec-6 single-tenant VM (defense layers: `.gitignore` block commit, bind mount `:ro`).

---

### 🟠 6.13 — AutoMigrate timeout trên cold start (Lec-6 NEW)

**Triệu chứng**: api `(unhealthy)` sau ~15-30s, log có `gorm: connection failed during AutoMigrate` hoặc healthcheck retries exhausted.

**Root cause**: Postgres init data dir lần đầu mất ~10-15s; api `start_period: 15s` có thể không đủ trên VM chậm/cold.

**Fix**: 2 options:
1. Tăng `api.healthcheck.start_period` 15s → 30s trong `docker-compose.yml`, restart stack.
2. Start postgres riêng trước, đợi healthy, rồi mới start api:
   ```bash
   docker compose up -d postgres
   sleep 25
   docker compose ps postgres   # verify "healthy"
   docker compose up -d api
   ```

---

## 7. Production Hardening Checklist

Deployment hiện tại là **learning-grade**, chưa phải production-grade. Bảng dưới liệt kê những gì CHƯA có và roadmap nâng cấp:

### Checklist 12 items

| # | Hạng mục | Trạng thái | Lý do skip ở Lec 4 | Khi nào nên làm |
|---|---|---|---|---|
| 1 | **HTTPS / TLS** (Let's Encrypt + cert-manager) | ❌ Chưa có | Cần domain (Task #5 optional). HTTP đủ cho smoke test | Trước khi public ra real user. **CRITICAL** nếu có login/auth |
| 2 | **CI/CD pipeline** (GitHub Actions auto-build amd64 + push + SSH deploy) | ❌ Chưa có | Manual deploy là learning objective | Khi deploy frequency > 1 lần/tuần |
| 3 | **Centralized logging** (Loki / ELK / CloudWatch Logs) | ❌ Chưa có | Single-VM, `docker logs` đủ debug | Khi có > 1 VM hoặc cần lưu log > 1 tuần |
| 4 | **Monitoring + Alerting** (Prometheus + Grafana, PagerDuty webhook) | ❌ Chưa có | Out of curriculum | Khi có SLA cam kết uptime hoặc oncall rotation |
| 5 | **Backup automation** (Redis RDB → S3, daily, 7-day retention) | ❌ Chưa có | Learning project, data loss chấp nhận được | **MINIMUM cho production** — data có giá trị nghiệp vụ |
| 6 | **Image scanning** (Trivy, Snyk, Docker Scout) | ❌ Chưa có | Nice-to-have cho learning | Khi push image lên public registry hoặc compliance |
| 7 | **SSH hardening** (disable password auth, fail2ban, đổi port 22) | ⚠️ Một phần (UFW + key-auth) | Disable password + fail2ban là +30 phút setup | Khi VM exposed internet > 1 tháng — brute-force attack mỗi giờ |
| 8 | **Redis AUTH password** | ❌ Chưa có | Redis chỉ reachable nội bộ qua compose network | Khi network isolation không đảm bảo 100% (multi-tenant VM, K8s NetworkPolicy chưa setup) |
| 9 | **Rate limiting** (nginx `limit_req_zone`) | ❌ Chưa có | Out of scope, low traffic | Khi có signal bị abuse hoặc cost concern (Redis fill up) |
| 10 | **Secret management** (Vault, AWS Secrets Manager, Doppler) | ❌ Chưa có (`.env` chmod 600) | Đủ cho learning + 1 env | Khi có > 1 deployment env (staging + prod), hoặc cần rotate secrets |
| 11 | **Multi-replica + load balancing** (nginx upstream với multiple api instances) | ❌ Chưa có (1 api replica) | Single VM = single point of failure chấp nhận được | Khi traffic vượt 1 VM capacity hoặc cần HA |
| 12 | **Reboot test PASS end-to-end** | ⏸️ Deferred | Task #3 Step 8 defer post-Task #4 | Trước khi declare "production ready" |
| 13 | **Postgres backup automation** (cron `pg_dump` → S3, daily, 7-day retention) | ❌ Chưa có | R-06-02 defer Lec-7 | Trước khi prod traffic (data Lec-6 = users/auth, MUST backup) |
| 14 | **Postgres SSL/TLS** (`sslmode=verify-full`) | ❌ Chưa có | Postgres chỉ reachable nội bộ qua compose network | Khi Postgres reachable ngoài network nội bộ (multi-VM, managed DB) |
| 15 | **RSA keys in Vault/AWS Secrets Manager** | ❌ Chưa có (host bind mount, chmod 0644) | Single-tenant VM + learning project; Vault tăng complexity | Khi multi-VM hoặc rotate frequency > 1 lần/quý, hoặc compliance audit |
| 16 | **Connection pooling** (PgBouncer trước Postgres) | ❌ Chưa có | GORM default pool ~10 conn, đủ Lec-6/7 traffic | Khi concurrent connection > 100 hoặc thấy "too many connections" error |

### Roadmap 3 phase (nếu nâng cấp production)

**Phase 1 — Quick Wins** (1–2 ngày, low complexity)
- Item #1 HTTPS via Let's Encrypt (certbot + nginx config)
- Item #7 fail2ban + disable SSH password auth (sshd_config + PasswordAuthentication no)
- Item #8 Redis AUTH password (env `REDIS_PASSWORD` + compose) 
- Item #9 Nginx rate limit (10 req/s per IP cho /shorten endpoint)
- Item #12 Run reboot test (Option A inspection + actual reboot khi VM stable)

**Phase 2 — Mid-term** (1 tuần, medium complexity)
- Item #2 GitHub Actions CI/CD:
  - Trigger: push tag → build multi-arch → push Hub → SSH deploy
  - Required secrets: `DOCKER_USERNAME`, `DOCKER_PAT`, `SSH_PRIVATE_KEY`, `VM_IP`
- Item #5 Redis backup cron:
  - Script `docker exec bookmark-redis redis-cli BGSAVE`
  - Copy `/data/dump.rdb` → S3 (aws cli) daily 3h sáng
  - Lifecycle policy 7-day retention

**Phase 3 — Long-term** (2–4 tuần, high complexity)
- Item #3 + #4 Observability stack:
  - Loki container (mount `/var/log/journal` + Docker JSON logs)
  - Prometheus scrape nginx + app `/metrics` (cần app expose Prometheus metrics)
  - Grafana dashboard cho RPS, latency p95, error rate, Redis memory
  - Alertmanager → Slack/PagerDuty webhook
- Item #11 Multi-replica:
  - Đổi single VM → 2-3 VM behind LB (AWS ALB, Cloudflare Tunnel)
  - Stateful: Redis cluster mode hoặc replicate
- Item #6 + #10 Compliance:
  - Trivy scan trong CI (block build nếu CVE HIGH)
  - Migration `.env` → Vault (vault agent inject secrets)

### Critical-path items cho production minimum viable

Nếu **buộc** phải lên production NGAY mà chỉ làm được ít nhất:
1. ✅ Item #1 HTTPS (TLS termination ở nginx) — non-negotiable nếu có auth/login
2. ✅ Item #5 Backup (data Redis có giá trị) — không có backup = không phải production
3. ✅ Item #7 SSH hardening — VM exposed internet = high attack surface
4. ✅ Item #12 Reboot test — verify recovery story

Còn lại có thể defer 1-2 tuần đầu khi traffic thấp.

---

## 📞 Liên hệ / References

- **App repo**: https://github.com/jaimesHub/bookmark-management
- **Deployment repo**: https://github.com/jaimesHub/bookmark-deployment (file này)
- **Image registry**: https://hub.docker.com/r/jaimes96/bookmark-app
- **Health-check URL**: `http://<vm-ip-or-host>/health-check`
- **Course context**: EBVN Academy Golang Backend Bootcamp — Lecture 4 (Deployment)

### Task plans (dev workflow)

- [Task #1 — App finalization](../../assignments/Lecture-04-app-finalization.md) (hostname config + Docker Hub push)
- [Task #2 — Deployment repo](../../assignments/Lecture-04-deployment-repo.md) (docker-compose + nginx — repo này)
- [Task #3 — VM deploy](../../assignments/Lecture-04-vm-deploy.md) (SSH + Docker + UFW + deploy)
- [Task #4 — Documentation](../../assignments/Lecture-04-documentation.md) (file này)
