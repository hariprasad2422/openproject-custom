#!/usr/bin/env bash
# Idempotent installation and configuration of PostgreSQL running NATIVELY
# on the Ubuntu host (systemd-managed) for OpenProject.
#
# OpenProject requires PostgreSQL 16+ (17 recommended, matches the PGVERSION
# the OpenProject Docker image itself targets) plus the pg_trgm, btree_gist
# and unaccent extensions and an ICU collation, all of which OpenProject's
# own migrations create automatically the first time it connects, as long as
# the "openproject" role owns its database (see db/migrate/extensions/*.rb
# and docs/installation-and-operations/installation/manual/README.md).
#
# Usage: setup-postgresql.sh <install|configure|verify|all>
#
# Required environment variables for "configure" and "verify":
#   OPENPROJECT_DB_PASSWORD   Password for the "openproject" role. Never
#                             echoed. Re-running "configure" re-syncs the
#                             role's password to this value by design (so the
#                             database never silently drifts from the
#                             GitHub secret) -- it does NOT touch schema,
#                             data, or the database itself if it already
#                             exists.
set -euo pipefail

PG_VERSION="${PG_VERSION:-17}"
DB_NAME="${DB_NAME:-openproject}"
DB_USER="${DB_USER:-openproject}"

# Must match prepare-server.sh's DOCKER_NETWORK_SUBNET exactly: this is the
# only network range PostgreSQL will accept "openproject" role connections
# from.
DOCKER_NETWORK_SUBNET="${DOCKER_NETWORK_SUBNET:-172.28.1.0/24}"

PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"
PG_CONF_FILE="${PG_CONF_DIR}/postgresql.conf"
PG_HBA_FILE="${PG_CONF_DIR}/pg_hba.conf"
PG_HBA_MARKER="# BEGIN openproject-docker-access"
PG_HBA_MARKER_END="# END openproject-docker-access"

log() { printf '[setup-postgresql] %s\n' "$1"; }

require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		echo "This script must be run as root (use sudo)." >&2
		exit 1
	fi
}

cmd_install() {
	if command -v psql >/dev/null 2>&1 && dpkg -l "postgresql-${PG_VERSION}" >/dev/null 2>&1; then
		log "PostgreSQL ${PG_VERSION} already installed, skipping install."
	else
		log "Installing PostgreSQL ${PG_VERSION} from the official PostgreSQL apt repository..."
		apt-get update -qq
		apt-get install -yq --no-install-recommends ca-certificates curl gnupg lsb-release

		install -d /usr/share/keyrings
		if [ ! -f /usr/share/keyrings/postgresql.gpg ]; then
			curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
		fi
		local codename
		codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
		echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main" \
			>/etc/apt/sources.list.d/pgdg.list

		apt-get update -qq
		apt-get install -yq --no-install-recommends \
			"postgresql-${PG_VERSION}" \
			"postgresql-contrib-${PG_VERSION}"
	fi

	systemctl enable postgresql
	systemctl start postgresql

	if ! systemctl is-active --quiet postgresql; then
		echo "ERROR: postgresql.service did not reach the active state." >&2
		exit 1
	fi
	log "PostgreSQL ${PG_VERSION} installed and running."
}

# Idempotently ensures a config directive is set in postgresql.conf, only
# writing (and signalling a reload is needed) when the value actually
# differs from what's currently configured. The desired value is compared
# as a plain string (never spliced into a regex) so values like `'*'` are
# compared literally instead of being misinterpreted as regex metacharacters.
# Only safe for values with no sed replacement metacharacters (&, \, |) -
# true for both call sites below.
ensure_conf_setting() {
	local key="$1" value="$2"
	local current
	current="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$PG_CONF_FILE" | tail -n1 | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//; s/[[:space:]]*(#.*)?\$//")"

	if [ "$current" = "$value" ]; then
		return 1
	fi

	if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$PG_CONF_FILE"; then
		sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$PG_CONF_FILE"
	else
		echo "${key} = ${value}" >>"$PG_CONF_FILE"
	fi
	return 0
}

ensure_pg_hba_rule() {
	if grep -qF "$PG_HBA_MARKER" "$PG_HBA_FILE"; then
		# Marker exists; check whether the actual rule content still matches.
		local current
		current="$(sed -n "/${PG_HBA_MARKER}/,/${PG_HBA_MARKER_END}/p" "$PG_HBA_FILE")"
		local expected
		expected="$(pg_hba_block)"
		if [ "$current" = "$expected" ]; then
			return 1
		fi
		# Replace the existing block in place.
		local tmp
		tmp="$(mktemp)"
		awk -v marker="$PG_HBA_MARKER" -v marker_end="$PG_HBA_MARKER_END" '
			$0 ~ marker { skip=1 }
			!skip { print }
			$0 ~ marker_end { skip=0 }
		' "$PG_HBA_FILE" >"$tmp"
		cat "$tmp" >"$PG_HBA_FILE"
		rm -f "$tmp"
		pg_hba_block >>"$PG_HBA_FILE"
		return 0
	fi

	pg_hba_block >>"$PG_HBA_FILE"
	return 0
}

pg_hba_block() {
	cat <<EOF
${PG_HBA_MARKER}
# Managed by deploy/scripts/setup-postgresql.sh - do not edit by hand.
# Allows the "openproject" role to reach only the "openproject" database,
# only from containers on the fixed-subnet Docker network (see
# prepare-server.sh), using SCRAM password authentication.
host    ${DB_NAME}    ${DB_USER}    ${DOCKER_NETWORK_SUBNET}    scram-sha-256
${PG_HBA_MARKER_END}
EOF
}

cmd_configure() {
	: "${OPENPROJECT_DB_PASSWORD:?OPENPROJECT_DB_PASSWORD must be set}"

	if [ ! -f "$PG_CONF_FILE" ]; then
		echo "ERROR: $PG_CONF_FILE not found. Run '$0 install' first." >&2
		exit 1
	fi

	local needs_reload=0

	# listen_addresses stays permissive at the bind level; pg_hba.conf below
	# is the actual access-control boundary (narrowest safe: one CIDR, one
	# db, one role). Binding to a specific docker-bridge IP is avoided
	# because that interface may not exist yet at postgresql startup time.
	if ensure_conf_setting "listen_addresses" "'*'"; then
		needs_reload=1
	fi
	if ensure_conf_setting "password_encryption" "scram-sha-256"; then
		needs_reload=1
	fi

	if ensure_pg_hba_rule; then
		needs_reload=1
	fi

	# Create role if missing; otherwise only sync its password so re-runs
	# never touch an existing role's other attributes. runuser (not `su -c
	# "string"`) is used throughout so the password never has to survive a
	# second round of shell re-parsing/escaping.
	local role_exists
	role_exists="$(runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'")"
	if [ "$role_exists" = "1" ]; then
		log "Role '${DB_USER}' already exists, syncing password only."
		runuser -u postgres -- psql -v pw="$OPENPROJECT_DB_PASSWORD" -c "ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD :'pw'"
	else
		log "Creating role '${DB_USER}'."
		runuser -u postgres -- psql -v pw="$OPENPROJECT_DB_PASSWORD" -c "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD :'pw'"
	fi

	local db_exists
	db_exists="$(runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")"
	if [ "$db_exists" = "1" ]; then
		log "Database '${DB_NAME}' already exists, leaving data untouched."
	else
		log "Creating database '${DB_NAME}' owned by '${DB_USER}'."
		runuser -u postgres -- createdb -O "${DB_USER}" -E unicode "${DB_NAME}"
	fi

	# Ensure ownership matches even if the database pre-existed under a
	# different owner (idempotent no-op if already correct).
	runuser -u postgres -- psql -tAc "ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER}" >/dev/null

	if [ "$needs_reload" -eq 1 ]; then
		log "Configuration changed, reloading PostgreSQL..."
		systemctl reload postgresql
	else
		log "No configuration changes needed, skipping reload."
	fi
}

cmd_verify() {
	: "${OPENPROJECT_DB_PASSWORD:?OPENPROJECT_DB_PASSWORD must be set}"

	if ! systemctl is-active --quiet postgresql; then
		echo "ERROR: postgresql.service is not active." >&2
		systemctl status postgresql --no-pager || true
		exit 1
	fi
	log "postgresql.service is active."

	local role_exists db_exists
	role_exists="$(runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | tr -d '[:space:]')"
	db_exists="$(runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | tr -d '[:space:]')"

	if [ "$role_exists" != "1" ]; then
		echo "ERROR: role '${DB_USER}' does not exist." >&2
		exit 1
	fi
	if [ "$db_exists" != "1" ]; then
		echo "ERROR: database '${DB_NAME}' does not exist." >&2
		exit 1
	fi
	log "Role and database exist."

	# Real SQL connectivity test authenticating as the openproject role over
	# TCP/localhost, exercising the same auth path (SCRAM) containers use.
	if ! PGPASSWORD="$OPENPROJECT_DB_PASSWORD" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT 1" >/dev/null; then
		echo "ERROR: could not authenticate as '${DB_USER}' against '${DB_NAME}' over TCP." >&2
		exit 1
	fi
	log "TCP authentication as '${DB_USER}' succeeded."

	local trusted_missing=0
	for ext in pg_trgm btree_gist unaccent; do
		if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_available_extensions WHERE name='${ext}'" | grep -q 1; then
			echo "ERROR: extension '${ext}' is not available (postgresql-contrib-${PG_VERSION} missing?)." >&2
			trusted_missing=1
		fi
	done
	[ "$trusted_missing" -eq 0 ] || exit 1
	log "Required extensions (pg_trgm, btree_gist, unaccent) are available."

	log "PostgreSQL verification passed."
}

main() {
	require_root
	local action="${1:-all}"
	case "$action" in
	install) cmd_install ;;
	configure) cmd_configure ;;
	verify) cmd_verify ;;
	all)
		cmd_install
		cmd_configure
		cmd_verify
		;;
	*)
		echo "Usage: $0 <install|configure|verify|all>" >&2
		exit 1
		;;
	esac
}

main "$@"
