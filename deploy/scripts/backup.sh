#!/usr/bin/env bash
# Runs ON THE PRODUCTION SERVER before a new deployment is rolled out.
#
# Backs up the native PostgreSQL database (via pg_dump, run as the OS
# "postgres" user over the local unix socket - no password needed and
# nothing touches the running cluster's data files while it's up), the
# OpenProject assets/attachments directory, and the current deployment
# configuration, into a timestamped directory under $DEPLOY_PATH/backups.
#
# On a first deployment (no previous deployment recorded yet) this safely
# no-ops instead of failing, per design: there is nothing to back up yet.
set -euo pipefail

DEPLOY_PATH="${DEPLOY_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ASSETS_PATH="${ASSETS_PATH:-/var/openproject/assets}"
DB_NAME="${DB_NAME:-openproject}"
BACKUP_ROOT="${DEPLOY_PATH}/backups"

log() { printf '[backup] %s\n' "$1"; }

cd "$DEPLOY_PATH"

if [ ! -f "current_image_tag" ]; then
	log "No previous deployment found (first deployment) - skipping backup."
	exit 0
fi

TIMESTAMP="$(date -u +%Y%m%d_%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"
chmod 750 "$BACKUP_DIR"

log "Backing up PostgreSQL database '${DB_NAME}' to ${BACKUP_DIR}/database.dump ..."
if ! runuser -u postgres -- pg_dump -d "$DB_NAME" -x -O -Fc -f "${BACKUP_DIR}/database.dump"; then
	echo "ERROR: pg_dump failed." >&2
	rm -rf "$BACKUP_DIR"
	exit 1
fi

log "Backing up OpenProject assets from ${ASSETS_PATH} ..."
if [ -d "$ASSETS_PATH" ]; then
	tar --create --gzip --file "${BACKUP_DIR}/assets.tar.gz" -C "$(dirname "$ASSETS_PATH")" "$(basename "$ASSETS_PATH")"
else
	log "WARNING: ${ASSETS_PATH} does not exist yet, skipping assets backup."
fi

log "Backing up deployment configuration ..."
mkdir -p "${BACKUP_DIR}/config"
cp docker-compose.prod.yml "${BACKUP_DIR}/config/" 2>/dev/null || true
cp .env.prod "${BACKUP_DIR}/config/" 2>/dev/null || true
cp current_image_tag "${BACKUP_DIR}/config/" 2>/dev/null || true
cp deployed-commit.txt "${BACKUP_DIR}/config/" 2>/dev/null || true
chmod -R 640 "${BACKUP_DIR}/config"/* 2>/dev/null || true

# This script runs via sudo; hand the backup back to the deploy user (sudo
# always sets SUDO_USER) so it stays browseable/removable without sudo too.
if [ -n "${SUDO_USER:-}" ]; then
	chown -R "${SUDO_USER}:${SUDO_USER}" "$BACKUP_DIR" 2>/dev/null || true
fi

log "Backup complete: ${BACKUP_DIR}"
