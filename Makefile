# Alap — development entry points.
#
# `make setup` takes a fresh checkout to a running build. Everything else
# assumes setup has been run at least once.
#
# Recipes that touch the engine source .env first: the engine reads
# GOOGLE_CLIENT_ID and ZERO_UPSTREAM_DB from the environment (engine/src/main.cpp)
# and does not parse .env itself.

.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

.PHONY: help setup dev app engine connect daemon migrate test clean

help: ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}'

setup: ## Install dependencies, configure postgres, migrate, build the engine
	@./scripts/setup.sh

dev: ## Run postgres + sidecar + zero-cache (foreground)
	@./scripts/dev.sh

app: ## Build and launch Alap.app
	@./scripts/run-app.sh

engine: ## Rebuild the C++ engine
	@cmake --build engine/build -j$$(sysctl -n hw.ncpu)

connect: ## Authorise a new mailbox
	@set -a; source .env; set +a; ./engine/build/mailengined connect

daemon: ## Supervise every connected account (foreground)
	@set -a; source .env; set +a; ./engine/build/mailengined daemon 30

migrate: ## Apply pending database migrations
	@./scripts/migrate.sh

test: ## Run all three suites
	@ctest --test-dir engine/build
	@swift test --package-path app
	@npm test --workspace=@mailapp/sidecar

clean: ## Remove build artefacts (keeps the database and .env)
	@rm -rf engine/build build app/.build
	@echo "removed engine/build, build, app/.build"
