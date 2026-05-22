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

## 🔗 Repos liên quan

- **App**: https://github.com/jaimesHub/bookmark-management
- **Image**: https://hub.docker.com/r/jaimes96/bookmark-app

## 📝 License

Course project — EBVN Academy Golang Backend Bootcamp.
