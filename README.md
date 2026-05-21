# Bookmark Deployment

Repo deployment cho `bookmark-app` — chứa docker-compose, nginx config, runbook.

## Quick Start (local)

```bash
cp .env.example .env
# Edit .env nếu cần (DOCKER_USER, APP_VERSION...)
make up
make health    # Verify health-check trả 200
```

## Documentation
- [Architecture & Runbook](./docs/ARCHITECTURE.md) — system diagram + chi tiết deploy

## Repos liên quan
  - App: https://github.com/jaimesHub/bookmark-management
  - Image: https://hub.docker.com/r/jaimes96/bookmark-app/
