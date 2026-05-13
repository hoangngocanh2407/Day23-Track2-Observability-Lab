## Day 23 Track 2 — Observability Lab orchestration (MINGW64 / Git Bash)
##
## Quick start:
##   make setup    - one-time: pull images, create .env
##   make up       - start the 7-service stack
##   make smoke    - verify all services healthy
##   make demo     - run end-to-end demo (load + alert + trace + drift)
##   make verify   - rubric gate — exit 0 if all checkpoints pass
##   make down     - stop the stack
##   make clean    - stop + remove volumes (destructive)

SHELL := /bin/bash
COMPOSE ?= docker compose
PYTHON := python

.PHONY: help setup up down restart logs smoke load alert trace drift demo verify lint-dashboards clean

help:
	@grep -E '^##|^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sed -E 's/^## ?//; s/:.*## /\t/' | column -t -s '	'

setup: ## one-time install + .env scaffold
	@test -f .env || cp .env.example .env
	@bash 00-setup/pull-images.sh
	@$(PYTHON) 00-setup/verify-docker.py

up: ## start the stack
	$(COMPOSE) up -d
	@echo "Stack starting. Run 'make smoke' to verify (allow ~30s for first start)."

down: ## stop the stack (preserves volumes)
	$(COMPOSE) down

restart: down up ## stop + start

logs: ## tail logs from all services
	$(COMPOSE) logs -f --tail=50

smoke: ## health-check all 7 services
	@echo "Checking services..."
	@curl -fsS http://localhost:8000/healthz     > /dev/null 2>&1 && echo "  app:            OK" || echo "  app:            FAIL"
	@curl -fsS http://localhost:9090/-/healthy   > /dev/null 2>&1 && echo "  prometheus:     OK" || echo "  prometheus:     FAIL"
	@curl -fsS http://localhost:9093/-/healthy    > /dev/null 2>&1 && echo "  alertmanager:   OK" || echo "  alertmanager:   FAIL"
	@curl -fsS http://localhost:3000/api/health | grep -q '"database":"ok"' && echo "  grafana:        OK" || echo "  grafana:        FAIL"
	@curl -fsS http://localhost:3100/ready        > /dev/null 2>&1 && echo "  loki:           OK" || echo "  loki:           FAIL"
	@curl -fsS http://localhost:16686/            > /dev/null 2>&1 && echo "  jaeger:         OK" || echo "  jaeger:         FAIL"
	@curl -fsS http://localhost:8888/metrics      > /dev/null 2>&1 && echo "  otel-collector: OK" || echo "  otel-collector: FAIL"
	@echo "Done."

load: ## run baseline locust load (concurrency=10, 60s)
	cd 02-prometheus-grafana/load-test && \
	  locust -f locustfile.py --headless -u 10 -r 2 -t 60s --host http://localhost:8000

alert: ## trigger an alert by killing the app, wait, then restore
	@echo "Step 1: killing app container..."
	@docker stop day23-app > /dev/null 2>&1
	@echo "Step 2: waiting up to 90s for ServiceDown alert to fire..."
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do \
		sleep 5; \
		alerts=$$(curl -s http://localhost:9093/api/v2/alerts 2>/dev/null); \
		count=$$(echo "$$alerts" | grep -o '"state":"active"' | wc -l); \
		if [ "$$count" -gt 0 ]; then \
			echo "  Alert fired after $$((i*5))s ($$count active)"; \
			break; \
		else \
			echo "  No alert yet ($$((i*5))s)..."; \
		fi; \
	done
	@echo "Step 3: restoring app..."
	@docker start day23-app > /dev/null 2>&1
	@echo "Step 4: waiting up to 60s for alert to resolve..."
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
		sleep 5; \
		alerts=$$(curl -s http://localhost:9093/api/v2/alerts 2>/dev/null); \
		count=$$(echo "$$alerts" | grep -o '"state":"active"' | wc -l); \
		if [ "$$count" -eq 0 ]; then \
			echo "  Alert resolved after $$((i*5))s"; \
			echo "Alert demo complete!"; \
			exit 0; \
		fi; \
	done
	@echo "Alert did not resolve within 60s" && exit 1

trace: ## generate one traced request and print its trace_id
	@curl -sS -X POST http://localhost:8000/predict \
	  -H 'Content-Type: application/json' \
	  -d '{"prompt":"hello"}' | $(PYTHON) -c 'import json,sys; d=json.load(sys.stdin); print("trace_id:",d.get("trace_id","?"))'

drift: ## run drift detection (CLI mode)
	cd 04-drift-detection && $(PYTHON) scripts/drift_detect.py

demo: ## end-to-end demo (load -> alert -> trace -> drift)
	$(MAKE) load
	$(MAKE) alert
	$(MAKE) trace
	$(MAKE) drift

verify: ## rubric gate — exits 0 only if all checkpoints pass
	$(PYTHON) scripts/verify.py

lint: lint-dashboards

lint-dashboards: ## validate Grafana dashboard JSONs
	$(PYTHON) scripts/lint-dashboards.py 02-prometheus-grafana/grafana/dashboards/ai-service-overview.json 02-prometheus-grafana/grafana/dashboards/slo-burn-rate.json 02-prometheus-grafana/grafana/dashboards/cost-and-tokens.json

clean: ## stop stack + remove volumes (DESTRUCTIVE)
	$(COMPOSE) down -v
