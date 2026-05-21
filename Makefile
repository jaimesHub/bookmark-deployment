.PHONY: help up down restart logs ps pull config clean

## help: Hiển thị các target có sẵn
help:
	@echo "Bookmark Deployment — Makefile targets:"
	@echo "  make up         - Start all services (detached)"
	@echo "  make down       - Stop all services (giữ volume)"
	@echo "  make down-clean - Stop + xoá luôn volume Redis (mất data)"
	@echo "  make restart    - Restart all services"
	@echo "  make logs       - Tail logs all services"
	@echo "  make logs-api   - Tail logs API only"
	@echo "  make ps         - Hiện status containers"
	@echo "  make pull       - Pull latest images từ Docker Hub"
	@echo "  make config     - Validate + in compose config"
	@echo "  make health     - Curl health-check qua nginx"

## up: Start stack
up:
	@test -f .env || (echo "❌ Thiếu .env. Copy từ .env.example trước: cp .env.example .env" && exit 1)
	docker compose up -d
	@echo "⏳ Đợi services healthy..."
	@sleep 5
	@$(MAKE) ps

## down: Stop stack (giữ data)
down:
	docker compose down

## down-clean: Stop + xoá volume (mất data Redis)
down-clean:
	docker compose down -v

## restart
restart:
	docker compose restart

## logs: Follow logs all
logs:
	docker compose logs -f --tail=100

## logs-api: Follow logs API only
logs-api:
	docker compose logs -f --tail=100 api

## ps: Status
ps:
	docker compose ps

## pull: Pull image mới nhất từ Hub (cho deploy update)
pull:
	docker compose pull

## config: Validate
config:
	docker compose config

## health: Test endpoint qua nginx
health:
	@curl -sf http://localhost/health-check | jq . || echo "❌ Health-check FAIL"
