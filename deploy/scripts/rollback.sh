#!/usr/bin/env bash
# Runs ON THE PRODUCTION SERVER when a deployment fails.
#
# Restores the previously deployed OpenProject image/configuration and
# restarts the application containers.
#
# IMPORTANT - what this script deliberately does NOT do:
#   - It never touches PostgreSQL. Data is never dropped or restored here.
#   - It never re-runs the seeder / database migrations.
# If the failed deployment ran migrations against the database, rolling the
# application back to older code that doesn't know about the new schema can
# itself be unsafe (missing columns/tables from the app's point of view).
# There is no generic, automatic way to reverse a migration safely, so this
# is a deliberate limitation: restore the application, but leave the
# database exactly as it is and require a human decision for anything
# migration-related. See deploy/README.md "Rollback" section.
set -euo pipefail

DEPLOY_PATH="${DEPLOY_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"
ENV_FILE="${ENV_FILE:-.env.prod}"

cd "$DEPLOY_PATH"

log() { printf '[rollback] %s\n' "$1"; }

compose() {
	docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

if [ ! -f previous_image_tag ]; then
	echo "ERROR: no previous_image_tag file found - nothing recorded to roll back to." >&2
	echo "This is expected on a first deployment; a failed first deployment has no prior version to restore." >&2
	exit 1
fi

PREVIOUS="$(cat previous_image_tag)"
PREV_IMAGE_NAME="${PREVIOUS%%:*}"
PREV_IMAGE_TAG="${PREVIOUS##*:}"

log "Capturing logs from the failed deployment before rolling back..."
FAILURE_LOG_DIR="${DEPLOY_PATH}/backups/rollback_$(date -u +%Y%m%d_%H%M%S)"
mkdir -p "$FAILURE_LOG_DIR"
chmod 750 "$FAILURE_LOG_DIR"
compose logs --no-color --tail=500 >"${FAILURE_LOG_DIR}/compose.log" 2>&1 || true
compose ps -a >"${FAILURE_LOG_DIR}/compose-ps.txt" 2>&1 || true
log "Failure logs saved to ${FAILURE_LOG_DIR}"

log "Restoring previous image: ${PREVIOUS}"
sed -i \
	-e "s|^IMAGE_NAME=.*|IMAGE_NAME=${PREV_IMAGE_NAME}|" \
	-e "s|^IMAGE_TAG=.*|IMAGE_TAG=${PREV_IMAGE_TAG}|" \
	"$ENV_FILE"

log "Stopping the failed application containers (leaving PostgreSQL and volumes untouched)..."
compose stop web worker proxy 2>&1 || true

log "Starting the previous version (skipping the seeder - no migrations are re-run on rollback)..."
compose up -d --no-deps cache web worker proxy

echo "${PREVIOUS}" >current_image_tag

log "Rollback complete: application restored to ${PREVIOUS}."
log "Database was NOT modified. Verify application/data compatibility manually if the failed deployment had already run migrations."
