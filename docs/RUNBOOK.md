# Bookmark App — Production Runbook

**Mục đích**: Operational knowledge cho VM deploy + incident response cho stack `bookmark-app` (api + postgres + redis + portal + nginx).

**Đọc khi nào**:
- 🆕 **First-time deploy** trên VM mới → § 1 (Prerequisite Checklist)
- 🚨 **Incident** (CD fail, 502, container unhealthy) → § 2 (Incident Recovery Playbook)
- ✅ **Trước mỗi PR merge → main** → § 3 (Pre-Deploy Sanity Check)

**Audience**: On-call DevOps, instructor reviewer, học viên tự host VM.

**Repos liên quan**:
- App (CI/CD source): https://github.com/jaimesHub/bookmark-management
- Deployment (compose + nginx + runbook): https://github.com/jaimesHub/bookmark-deployment

---

## § 1. First-time VM Deploy — Prerequisite Checklist

CD workflow (`bookmark-management/.github/workflows/cd.yml`) **CHỈ touch app container** — KHÔNG provision postgres/redis/nginx (xem § 3 giải thích `--no-deps`). Trước khi CD chạy lần đầu, infra phải được bring up thủ công theo sequence dưới.

> **⚠️ Bài học từ T21 incident (2026-06-11)**: CD fail với `lookup postgres on 127.0.0.11:53: no such host` vì postgres chưa bao giờ được start trên VM. Nếu skip checklist này → mọi deploy đầu tiên sẽ fail.

### Bước 1 — VM baseline + clone deployment repo

Prerequisites trên VM (Ubuntu 22.04+ recommended, ≥ 1 GB RAM):
- Docker Engine + `docker compose` plugin (`docker --version`, `docker compose version`)
- Git, openssl, curl, sudo access
- Firewall: open 22 (SSH) + 80 (HTTP); KHÔNG expose 5432/6379/8080/3000 ra public

```bash
# Clone deployment repo vào /opt (CD workflow expect đúng path này)
sudo mkdir -p /opt && sudo chown $USER:$USER /opt
cd /opt
git clone https://github.com/jaimesHub/bookmark-deployment.git
cd bookmark-deployment

# Verify compose file syntax
docker compose config --quiet && echo "✅ compose OK"
```

### Bước 2 — Generate RSA keys (PROD)

API cần RSA keypair để sign JWT (Lec-6). PROD dùng PKCS#8 private + PKIX public, mount read-only vào container.

```bash
mkdir -p keys
cd keys

# Private key — PKCS#8 format (KHÔNG dùng `openssl genrsa` legacy PKCS#1)
openssl genpkey -algorithm RSA -out private.pem -pkeyopt rsa_keygen_bits:2048

# Public key — PKIX format
openssl rsa -in private.pem -pubout -out public.pem

# Verify header (expect "BEGIN PRIVATE KEY" + "BEGIN PUBLIC KEY")
head -1 private.pem    # → -----BEGIN PRIVATE KEY-----
head -1 public.pem     # → -----BEGIN PUBLIC KEY-----

# Set ownership + permission (single-tenant VM accept world-readable host file;
# container reads as uid=100 anyway, bind mount :ro)
sudo chown root:root private.pem public.pem
sudo chmod 0644 private.pem public.pem
stat -c '%a %U:%G %n' private.pem public.pem
# → 644 root:root private.pem
# → 644 root:root public.pem

cd ..
```

> **Lưu ý chmod 0644**: Đây là trade-off single-tenant VM. Multi-tenant production phải dùng chmod 0400 + container uid stable (1001) — xem ADR-D5 trong DevOps plan để tham khảo.

### Bước 3 — Populate `.env`

```bash
cp .env.example .env

# Generate Postgres password (24 chars alphanumeric, ≥ 143 bits entropy)
PG_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
echo "Generated password length: ${#PG_PASS}"   # Expect: 24

# Inject vào .env (KHÔNG echo password ra log/chat — REDACT)
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$PG_PASS|" .env
unset PG_PASS   # Clear from shell history

# Lock permission (chỉ owner read/write)
chmod 600 .env
stat -c '%a %n' .env   # → 600 .env

# Verify all keys rendered (expect ≥ 13 lines, no placeholder)
grep -c '^[A-Z_]*=' .env
docker compose config --quiet && echo "✅ .env + compose render OK"
```

### Bước 4 — Bring up infra (postgres + redis)

CD chỉ recreate `api` với `--no-deps` flag, **KHÔNG** auto-start postgres/redis. Phải start infra trước:

```bash
# Pull infra images (postgres 16-alpine + redis 7-alpine)
docker compose pull postgres redis

# Start infra detached
docker compose up -d postgres redis

# Wait healthy (postgres ~20-30s cold start, redis < 5s)
sleep 30
docker compose ps postgres redis
# Expect:
# NAME               STATUS                   PORTS
# bookmark-postgres  Up (healthy)             5432/tcp
# bookmark-redis     Up (healthy)             6379/tcp
```

### Bước 5 — Smoke test infra

Verify postgres accept connection + Redis ping:

```bash
# Postgres — pg_isready trong container
docker compose exec -T postgres pg_isready -U "${POSTGRES_USER:-bookmark}" -d "${POSTGRES_DB:-bookmark}" -h 127.0.0.1
# Expect: /var/run/postgresql:5432 - accepting connections

# Redis — ping
docker compose exec -T redis redis-cli ping
# Expect: PONG
```

### Bước 6 — Trigger CD (first deploy)

Lúc này infra ready, CD có thể deploy `api`:

**Option A** — Push commit lên `main` (auto-trigger CI build → CD deploy)
**Option B** — Manual dispatch:

```bash
# Trigger CD với SHA mong muốn (vd: latest commit hash)
gh workflow run cd.yml -R jaimesHub/bookmark-management -F image_tag=<sha>

# Watch run
gh run list -R jaimesHub/bookmark-management --workflow=cd.yml --limit 1
gh run watch <run-id> -R jaimesHub/bookmark-management
```

### Bước 7 — Post-deploy verify

```bash
# Tất cả 5 containers healthy
docker compose ps
# Expect: api, postgres, redis, portal, nginx — all "Up (healthy)"

# External smoke test qua nginx
curl -sS http://localhost/health-check
# Expect: {"message":"OK","service_name":"bookmark-app","instance_id":"..."}

# Register endpoint (Lec-6)
curl -sS -X POST http://localhost/v1/users/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"smoke","email":"smoke@example.com","password":"Passw0rd!","display_name":"Smoke"}'
# Expect: 201 + user object (KHÔNG có password_hash trong response)
```

### ✅ Acceptance criteria (first-time deploy DONE)

- [ ] 5 containers UP + healthy
- [ ] `curl /health-check` → 200 OK
- [ ] Register endpoint → 201
- [ ] `docker compose logs api | grep -i error` → empty
- [ ] `docker stats --no-stream` → tổng memory < 800 MB (1 GB VM target)

---

## § 2. Incident Recovery Playbook

### Symptom A — CD deploy fail: `lookup postgres on 127.0.0.11:53: no such host`

**Triệu chứng**:
- CD step "Deploy" fail sau 60s healthcheck timeout
- `docker compose logs api` trên VM hiện:
  ```
  failed to connect to database: dial tcp: lookup postgres on 127.0.0.11:53: no such host
  ```
- `docker compose ps` show api container restarting, **không thấy** postgres container

**Root cause**: Postgres container chưa exist trên VM. CD dùng `--no-deps` flag (intentional, xem § 3) → KHÔNG auto-start postgres → api boot fail.

**Tại sao xảy ra**:
- First-time deploy nhưng § 1 prerequisite checklist bị skip
- HOẶC postgres bị `docker compose down` thủ công (mất container + reuse named volume)

**Recovery steps** (SSH vào VM):

```bash
ssh <user>@<vm-ip>
cd /opt/bookmark-deployment

# 1. Confirm postgres missing
docker compose ps
# Nếu KHÔNG thấy bookmark-postgres → confirmed root cause

# 2. Bring up postgres (named volume `bookmark-postgres-data` sẽ được reuse nếu đã tồn tại)
docker compose up -d postgres

# 3. Wait healthy (cold start ~20-30s lần đầu, ~5s nếu volume đã có data)
sleep 30
docker compose ps postgres
# Expect: Up (healthy)

# 4. Verify accept connection
docker compose exec -T postgres pg_isready -U "${POSTGRES_USER:-bookmark}" -d "${POSTGRES_DB:-bookmark}" -h 127.0.0.1
# Expect: accepting connections

# 5. Recreate api để re-attempt DB connect
docker compose up -d --force-recreate api

# 6. Wait api healthy
sleep 20
docker compose ps api
# Expect: Up (healthy)

# 7. Re-run failed CD job (verify script works on healthy infra)
gh run rerun <failed-run-id> --repo jaimesHub/bookmark-management --failed
gh run watch <failed-run-id> --repo jaimesHub/bookmark-management
# Expect: success
```

**Prevention**: Đảm bảo § 1 Bước 4 + 5 complete trước khi merge PR đầu tiên touch CD.

---

### Symptom B — Nginx 502 Bad Gateway sau khi recreate api

**Triệu chứng**:
- `docker compose ps` show all 5 containers healthy
- `curl http://localhost/health-check` → `502 Bad Gateway`
- `docker compose logs nginx --tail=20` show:
  ```
  upstream connect() failed (113: Host is unreachable) while connecting to upstream
  ```

**Root cause**: Nginx container running lâu (vài ngày → vài tuần) cache resolved IP của api container cũ. Sau `docker compose up -d --force-recreate api`, api có IP mới (Docker dynamic IP allocation) → nginx vẫn try IP cũ → connection fail.

**Tại sao xảy ra**:
- Nginx default DNS cache không expire trong run-time (no `resolver` directive với `valid=` timeout)
- Docker Compose recreate container → new bridge IP → DNS stale

**Recovery steps**:

```bash
# 1. Confirm api healthy + new IP
docker inspect bookmark-api -f '{{.State.Health.Status}} {{.NetworkSettings.Networks.bookmark-internal.IPAddress}}'
# Expect: healthy <new-ip>

# 2. Restart nginx (force re-resolve upstream DNS)
docker compose restart nginx

# 3. Wait healthy
sleep 5
docker compose ps nginx
# Expect: Up (healthy)

# 4. Verify
curl -sS http://localhost/health-check
# Expect: {"message":"OK",...}
```

**Long-term mitigation** (out-of-scope cho runbook hiện tại, track riêng R-06-08):
- Option 1: Add `resolver 127.0.0.11 valid=10s;` vào `nginx/default.conf` + dùng variable upstream pattern
- Option 2: Switch sang dynamic upstream module hoặc Envoy

Short-term: **luôn `docker compose restart nginx` ngay sau khi recreate api** (apply trong CD workflow nếu cần).

---

### Symptom C — Container unhealthy persistent (api memory OOM)

**Triệu chứng**:
- `docker compose ps` show api status `Up (unhealthy)` lặp lại
- `docker stats --no-stream` show api memory > 180 MB (gần limit 192M)
- `docker compose logs api --tail=50` có entry exit code 137 hoặc "killed"

**Root cause**: api container chạm memory limit (192M) trong compose deploy block.

**Recovery steps**:

```bash
# 1. Temporary relax limit (edit docker-compose.yml api.deploy.resources.limits.memory: 192M → 256M)
vim docker-compose.yml

# 2. Recreate api với limit mới
docker compose up -d --force-recreate api

# 3. Monitor 5 phút
watch -n 30 'docker stats --no-stream bookmark-api'
```

**Investigation cần làm sau recovery**:
- Heap profile (`go tool pprof http://localhost:8080/debug/pprof/heap`) nếu pprof endpoint enabled
- Check Lec-6+ feature flags (RSA key cache, AutoMigrate lifecycle) → có thể leak

---

## § 3. Pre-Deploy Sanity Check (Mọi lần deploy)

Trước khi merge PR vào `main` (trigger CI build + CD deploy), verify checklist này:

### ✅ Checklist

- [ ] **CI build PASS** trên feature branch (`gh pr checks <pr-number>`)
- [ ] **VM infra healthy**: SSH vào VM, run `docker compose ps`, confirm 3 infra containers (`postgres`, `redis`, `nginx`) status `Up (healthy)`
- [ ] **Image tag mới ≠ current**: `grep APP_VERSION .env` vs PR commit SHA — đảm bảo CD sẽ deploy code mới (không phải re-deploy cùng image)
- [ ] **No active incidents**: `docker compose logs --tail=100 | grep -i error` → empty hoặc benign
- [ ] **Memory headroom**: `docker stats --no-stream` → tổng usage < 80% RAM VM (cushion cho api recreate)

### Pre-deploy command snippet

```bash
ssh <user>@<vm-ip> '
  cd /opt/bookmark-deployment
  echo "=== Containers ==="
  docker compose ps
  echo "=== Current APP_VERSION ==="
  grep "^APP_VERSION=" .env
  echo "=== Memory ==="
  docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}"
  echo "=== Errors (last 100 log lines per container) ==="
  for svc in api postgres redis nginx portal; do
    echo "--- $svc ---"
    docker compose logs --tail=100 $svc 2>&1 | grep -iE "error|panic|fatal" | head -5 || echo "(clean)"
  done
'
```

### Design rationale — Tại sao CD dùng `--no-deps`?

Reference: `bookmark-management/.github/workflows/cd.yml` line 111

```bash
docker compose up -d --no-deps api
```

**Intentional design** — KHÔNG phải bug:

1. **Separation of concerns**: CI/CD pipeline chỉ touch **app code** (image tag rotation). Infrastructure ownership (postgres data lifecycle, redis persistence, nginx config) thuộc về DevOps Leader / VM admin — quản lý qua manual procedure (§ 1) và compose file commit.

2. **Safety**: `--no-deps` ngăn CD vô tình:
   - Restart postgres → potential data loss nếu volume mount sai
   - Restart nginx → drop connections đang active
   - Restart redis → flush in-memory cache không cần thiết

3. **Faster deploys**: chỉ recreate 1 container (api) thay vì cả stack → downtime < 5s thay vì 30s+.

4. **Predictability**: deploy hoạt động giống nhau ở mọi state — miễn là infra healthy, app deploy success. Nếu infra unhealthy, fail fast (vd Symptom A) thay vì silent fix mà ẩn root cause.

**Trade-off** (acknowledged): Implicit prerequisite — operator MUST đảm bảo infra ready trước (§ 1). T21 incident chính là bài học khi prerequisite này không explicit. Mitigation: runbook (file này) + future pre-deploy gate trong CD (R-06-06b).

---

## Lessons Learned (T21 Incident Postmortem — 2026-06-11)

| # | Lesson | Reflected in |
|---|--------|-------------|
| 1 | Implicit task dependency = silent failure waiting to happen | § 1 explicit Prerequisite Checklist; PM track "Blocks/Blocked by" column (R-06-07) |
| 2 | Healthcheck timeout UX kém cho missing prerequisite | § 2 Symptom A nhận diện root cause nhanh; future pre-deploy gate R-06-06b sẽ fail-fast |
| 3 | Nginx upstream DNS cache lâu hơn expectation | § 2 Symptom B + recovery; long-term fix track R-06-08 |
| 4 | Design intent của `--no-deps` cần được document explicit | § 3 "Design rationale" + cross-ref từ cd.yml comment (planned R-06-06b) |

---

## References

- **CD workflow**: [bookmark-management/.github/workflows/cd.yml](https://github.com/jaimesHub/bookmark-management/blob/main/.github/workflows/cd.yml)
- **docker-compose.yml**: [bookmark-deployment/docker-compose.yml](https://github.com/jaimesHub/bookmark-deployment/blob/main/docker-compose.yml)
- **Architecture overview**: [./ARCHITECTURE.md](./ARCHITECTURE.md)
- **Rollback procedure**: [../README.md § Rollback Procedure](../README.md#-rollback-procedure)
- **T21 incident postmortem**: `go-ebvn/assignments/techlead-lec-6-fix-plan.md § Lessons Learned`

---

**Last updated**: 2026-06-11 — Lec-6 deploy cycle (R-06-06a)  
**Maintainer**: DevOps Leader role (per `go-ebvn/ROLES.md`)
