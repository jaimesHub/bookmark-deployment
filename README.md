# Bookmark Deployment

Repo deployment cho **bookmark-app** — chứa `docker-compose.yml`, nginx config, Makefile, runbook.

3 services: `nginx` (reverse proxy, port 80) → `api` (Go app) → `redis` (storage).

## ⚡ Quick Start

```bash
git clone https://github.com/jaimesHub/bookmark-deployment.git
cd bookmark-deployment
cp .env.example .env       # Defaults OK cho local; edit cho production
make up                    # Start 3 services
make health                # Verify (curl health-check qua nginx)
```

**Endpoint**: `http://localhost/health-check` (local) hoặc `http://<vm-ip>/health-check` (production).

## 📖 Documentation

- **[Architecture & Runbook](./docs/ARCHITECTURE.md)** — System diagram, prerequisites, env vars, troubleshooting, production hardening checklist

## 🛠️ Makefile Targets

| Command | Mô tả |
|---|---|
| `make help` | Liệt kê tất cả targets |
| `make up` | Start stack detached |
| `make down` | Stop stack (giữ Redis volume) |
| `make down-clean` | Stop + xoá volume (⚠️ mất data) |
| `make ps` | Container status |
| `make logs` / `logs-api` | Tail logs |
| `make pull` | Pull image mới nhất từ Hub |
| `make health` | Curl `/health-check` qua nginx |
| `make config` | Validate compose YAML |

## 🔄 Rollback Procedure

Khi deploy mới trên `bookmark-app` gây issue trên production VM, rollback về SHA cũ.

### Option A — Re-run CD workflow (recommended)

Dispatch CD workflow với SHA muốn rollback về:

```bash
gh workflow run cd.yml -R jaimesHub/bookmark-management -F image_tag=<previous_sha>
```

CD sẽ:
1. Verify image `jaimes96/bookmark-app:<previous_sha>` tồn tại trên Docker Hub (HTTP 200 check)
2. SSH vào VM → update `.env` APP_VERSION → `docker compose pull api` → `docker compose up -d --no-deps api`
3. Wait healthy (60s timeout) → external smoke test qua nginx port 80

Operator find previous SHA: 
- From CD run log: `→ Prev APP_VERSION=<sha> | New APP_VERSION=<sha>` (printed on every deploy)
- Or git history: `git log --oneline origin/main`

**Verified working**: rollback test 2026-05-29 runs `26644245441` (downgrade `80fea5a → e6b9e3b`) + `26644603378` (restore).

### Option B — SSH direct (emergency bypass)

Khi CD workflow itself broken (vd GH Actions outage), bypass via SSH:

```bash
ssh <user>@<vm-ip>
cd /opt/bookmark-deployment

# Capture current state
PREV=$(grep '^APP_VERSION=' .env | cut -d= -f2 | cut -d'#' -f1 | tr -d ' ')
echo "Current APP_VERSION: $PREV"

# Update .env to target SHA
sed -i "s|^APP_VERSION=.*|APP_VERSION=<target_sha>|" .env

# Pull + recreate api container (don't touch redis/nginx/portal)
docker compose pull api && docker compose up -d --no-deps api

# Verify
sleep 10
curl http://localhost/health-check     # Expected: {"message":"OK",...}
```

### Defensive check

CD workflow has fail-fast guards (won't touch VM if pre-conditions broken):
- `/opt/bookmark-deployment` directory must exist (else: `❌ Lec 4 deployment chưa setup`)
- `.env` file must exist (else: `❌ .env missing — cp .env.example .env + populate APP_VERSION + DOCKER_USER`)

Run safe even from clean VM state.

## 🔗 Repos liên quan

- **App**: https://github.com/jaimesHub/bookmark-management
- **Image**: https://hub.docker.com/r/jaimes96/bookmark-app

## 📝 License

Course project — EBVN Academy Golang Backend Bootcamp.
