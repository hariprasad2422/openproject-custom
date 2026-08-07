#!/usr/bin/env bash
# Runs ON THE PRODUCTION SERVER after a deployment (or rollback).
#
# Verifies: native PostgreSQL is running, the expected containers are up,
# and the application actually answers HTTP requests - with retries, since
# OpenProject can take a while to finish booting. Never prints .env.prod or
# any secret value.
set -euo pipefail

DEPLOY_PATH="${DEPLOY_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"
ENV_FILE="${ENV_FILE:-.env.prod}"
RETRIES="${HEALTH_CHECK_RETRIES:-30}"
RETRY_DELAY_SECONDS="${HEALTH_CHECK_RETRY_DELAY_SECONDS:-10}"

cd "$DEPLOY_PATH"

log() { printf '[health-check] %s\n' "$1"; }

compose() {
	docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

# shellcheck disable=SC1090
set -a
. "./$ENV_FILE"
set +a
APP_PORT="${APP_PORT:-80}"

on_failure() {
	echo "=== HEALTH CHECK FAILED ===" >&2
	echo "--- systemctl status postgresql ---" >&2
	systemctl status postgresql --no-pager >&2 || true
	echo "--- docker compose ps ---" >&2
	compose ps -a >&2 || true
	echo "--- recent web logs ---" >&2
	compose logs --no-color --tail=100 web >&2 || true
	echo "--- recent worker logs ---" >&2
	compose logs --no-color --tail=50 worker >&2 || true
	exit 1
}

log "Checking native PostgreSQL service..."
if ! systemctl is-active --quiet postgresql; then
	echo "ERROR: postgresql.service is not active." >&2
	on_failure
fi
log "postgresql.service is active."

log "Checking required containers are running..."
for service in web worker cache proxy; do
	state="$(compose ps --format '{{.State}}' "$service" 2>/dev/null || echo "missing")"
	if [ "$state" != "running" ]; then
		echo "ERROR: service '$service' is not running (state: $state)." >&2
		on_failure
	fi
done
seeder_status="$(compose ps -a --format '{{.ExitCode}}' seeder 2>/dev/null || echo "")"
if [ -n "$seeder_status" ] && [ "$seeder_status" != "0" ]; then
	echo "ERROR: seeder exited with code $seeder_status." >&2
	on_failure
fi
log "web, worker, cache, proxy are running; seeder completed successfully."

log "Checking HTTP health endpoint (up to ${RETRIES} attempts, ${RETRY_DELAY_SECONDS}s apart)..."
attempt=1
until curl --fail --silent --show-error --max-time 10 "http://localhost:${APP_PORT}/health_checks/default" >/dev/null; do
	if [ "$attempt" -ge "$RETRIES" ]; then
		echo "ERROR: /health_checks/default did not respond successfully after ${RETRIES} attempts." >&2
		on_failure
	fi
	log "Attempt ${attempt}/${RETRIES} not ready yet, retrying in ${RETRY_DELAY_SECONDS}s..."
	attempt=$((attempt + 1))
	sleep "$RETRY_DELAY_SECONDS"
done

log "Health check passed: /health_checks/default is responding."
