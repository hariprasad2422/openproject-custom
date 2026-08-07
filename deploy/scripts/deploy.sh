#!/usr/bin/env bash
# Runs ON THE PRODUCTION SERVER, inside $DEPLOY_PATH, after the new image
# has been loaded into the local Docker daemon and docker-compose.prod.yml /
# .env.prod / nginx config have already been transferred there.
#
# Responsibilities:
#   1. Validate the compose file.
#   2. Record the currently-running image tag so rollback.sh can restore it.
#   3. Bring the stack up. Compose's `depends_on: condition:
#      service_completed_successfully` on web/worker means this call blocks
#      on the seeder (migrations + seed) and fails loudly if it exits
#      non-zero - migrations are never skipped or raced.
#   4. Record the newly deployed image tag + git commit for auditability.
set -euo pipefail

DEPLOY_PATH="${DEPLOY_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"
ENV_FILE="${ENV_FILE:-.env.prod}"
GIT_COMMIT="${GIT_COMMIT:-unknown}"

cd "$DEPLOY_PATH"

log() { printf '[deploy] %s\n' "$1"; }

compose() {
	docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

if [ ! -f "$ENV_FILE" ]; then
	echo "ERROR: $ENV_FILE not found in $DEPLOY_PATH." >&2
	exit 1
fi

# shellcheck disable=SC1090
set -a
. "./$ENV_FILE"
set +a

if [ -z "${IMAGE_NAME:-}" ] || [ -z "${IMAGE_TAG:-}" ]; then
	echo "ERROR: IMAGE_NAME/IMAGE_TAG not set in $ENV_FILE." >&2
	exit 1
fi

log "Validating compose configuration..."
compose config >/dev/null

log "Recording previously deployed image tag (for rollback)..."
PREVIOUS_TAG=""
if [ -f current_image_tag ]; then
	PREVIOUS_TAG="$(cat current_image_tag)"
fi
if [ -n "$PREVIOUS_TAG" ] && [ "$PREVIOUS_TAG" != "${IMAGE_NAME}:${IMAGE_TAG}" ]; then
	echo "$PREVIOUS_TAG" >previous_image_tag
	log "Previous image was $PREVIOUS_TAG."
else
	log "No previous deployment found (or same tag); nothing to record for rollback."
fi

log "Bringing up the OpenProject stack (${IMAGE_NAME}:${IMAGE_TAG})..."
if ! compose up -d --remove-orphans; then
	echo "ERROR: 'docker compose up' failed. This includes migration failures," >&2
	echo "since web/worker wait on the seeder completing successfully." >&2
	echo "--- seeder logs ---" >&2
	compose logs --no-color --tail=200 seeder >&2 || true
	exit 1
fi

SEEDER_EXIT_CODE="$(compose ps -a seeder --format '{{.ExitCode}}' 2>/dev/null || echo "")"
if [ -n "$SEEDER_EXIT_CODE" ] && [ "$SEEDER_EXIT_CODE" != "0" ]; then
	echo "ERROR: seeder container exited with code $SEEDER_EXIT_CODE." >&2
	compose logs --no-color --tail=200 seeder >&2 || true
	exit 1
fi

echo "${IMAGE_NAME}:${IMAGE_TAG}" >current_image_tag
echo "$GIT_COMMIT" >deployed-commit.txt

log "Deployment complete: ${IMAGE_NAME}:${IMAGE_TAG} (commit ${GIT_COMMIT})."
