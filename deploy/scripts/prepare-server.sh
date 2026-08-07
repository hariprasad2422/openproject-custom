#!/usr/bin/env bash
# Idempotent bootstrap for a clean Ubuntu 24.04 production host.
#
# Installs Docker Engine + Compose plugin, creates the fixed-subnet Docker
# network that native PostgreSQL will be reachable on, creates the
# OpenProject deployment directories, and opens only 22/80/443 in ufw.
#
# PostgreSQL itself is installed/configured by setup-postgresql.sh, not here,
# so that the "install docker" and "install database" concerns stay separate
# and independently re-runnable.
set -euo pipefail

# --- Configuration -----------------------------------------------------
DEPLOY_PATH="${DEPLOY_PATH:-/opt/openproject}"
ASSETS_PATH="${ASSETS_PATH:-/var/openproject/assets}"
DEPLOY_USER_NAME="${DEPLOY_USER_NAME:-$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")}"

# Fixed subnet for the OpenProject Docker network. PostgreSQL's pg_hba.conf
# is configured (by setup-postgresql.sh) to only accept connections from this
# exact range, so it must be created here, before PostgreSQL is configured,
# and must never change without updating both scripts.
DOCKER_NETWORK_NAME="${DOCKER_NETWORK_NAME:-openproject_net}"
DOCKER_NETWORK_SUBNET="${DOCKER_NETWORK_SUBNET:-172.28.1.0/24}"
DOCKER_NETWORK_GATEWAY="${DOCKER_NETWORK_GATEWAY:-172.28.1.1}"

log() { printf '[prepare-server] %s\n' "$1"; }

require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		echo "This script must be run as root (use sudo)." >&2
		exit 1
	fi
}

install_prerequisites() {
	log "Installing base utilities..."
	apt-get update -qq
	apt-get install -yq --no-install-recommends \
		ca-certificates \
		curl \
		gnupg \
		lsb-release \
		ufw \
		gettext-base
}

install_docker() {
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		log "Docker Engine + Compose plugin already installed, skipping."
		return
	fi

	log "Installing Docker Engine via the official Docker apt repository..."
	install -m 0755 -d /etc/apt/keyrings
	if [ ! -f /etc/apt/keyrings/docker.asc ]; then
		curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
		chmod a+r /etc/apt/keyrings/docker.asc
	fi

	local arch codename
	arch="$(dpkg --print-architecture)"
	codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

	cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable
EOF

	apt-get update -qq
	apt-get install -yq --no-install-recommends \
		docker-ce \
		docker-ce-cli \
		containerd.io \
		docker-buildx-plugin \
		docker-compose-plugin

	systemctl enable docker
	systemctl start docker
}

ensure_deploy_user_in_docker_group() {
	if [ -n "$DEPLOY_USER_NAME" ] && id "$DEPLOY_USER_NAME" >/dev/null 2>&1; then
		if ! id -nG "$DEPLOY_USER_NAME" | tr ' ' '\n' | grep -qx docker; then
			log "Adding $DEPLOY_USER_NAME to the docker group..."
			usermod -aG docker "$DEPLOY_USER_NAME"
		fi
	fi
}

create_docker_network() {
	if docker network inspect "$DOCKER_NETWORK_NAME" >/dev/null 2>&1; then
		local existing_subnet
		existing_subnet="$(docker network inspect "$DOCKER_NETWORK_NAME" -f '{{(index .IPAM.Config 0).Subnet}}')"
		if [ "$existing_subnet" != "$DOCKER_NETWORK_SUBNET" ]; then
			echo "ERROR: Docker network '$DOCKER_NETWORK_NAME' already exists with subnet $existing_subnet, expected $DOCKER_NETWORK_SUBNET." >&2
			echo "Refusing to recreate it automatically because that would invalidate PostgreSQL's pg_hba.conf rule and could drop it in place while containers are attached." >&2
			exit 1
		fi
		log "Docker network '$DOCKER_NETWORK_NAME' already exists with the expected subnet, skipping."
		return
	fi

	log "Creating Docker network '$DOCKER_NETWORK_NAME' ($DOCKER_NETWORK_SUBNET)..."
	docker network create \
		--driver bridge \
		--subnet "$DOCKER_NETWORK_SUBNET" \
		--gateway "$DOCKER_NETWORK_GATEWAY" \
		"$DOCKER_NETWORK_NAME"
}

create_directories() {
	log "Creating deployment directories..."
	mkdir -p \
		"$DEPLOY_PATH" \
		"$DEPLOY_PATH/releases" \
		"$DEPLOY_PATH/backups" \
		"$DEPLOY_PATH/nginx" \
		"$ASSETS_PATH"

	# Deploy path is only writable by the deploy user + root, never world-writable.
	if [ -n "$DEPLOY_USER_NAME" ] && id "$DEPLOY_USER_NAME" >/dev/null 2>&1; then
		chown -R "$DEPLOY_USER_NAME":"$DEPLOY_USER_NAME" "$DEPLOY_PATH"
	fi
	chmod 750 "$DEPLOY_PATH" "$DEPLOY_PATH/backups"

	# Assets are written by the container's "app" user (uid 1000 by default in
	# the OpenProject image). Keep group-writable rather than world-writable.
	chown -R 1000:1000 "$ASSETS_PATH"
	chmod 750 "$ASSETS_PATH"
}

configure_firewall() {
	log "Configuring ufw (allow 22, 80, 443 only; PostgreSQL 5432 stays unexposed)..."
	ufw --force default deny incoming
	ufw --force default allow outgoing
	ufw allow 22/tcp
	ufw allow 80/tcp
	ufw allow 443/tcp
	# Explicitly not exposing 5432: PostgreSQL is only reachable from the host
	# and from containers on $DOCKER_NETWORK_NAME, both of which bypass ufw's
	# public-interface rules entirely (loopback + docker-managed bridge).
	if ! ufw status | grep -q "Status: active"; then
		ufw --force enable
	fi
}

main() {
	require_root
	install_prerequisites
	install_docker
	ensure_deploy_user_in_docker_group
	create_docker_network
	create_directories
	configure_firewall
	log "Server preparation complete."
	log "Docker network: $DOCKER_NETWORK_NAME ($DOCKER_NETWORK_SUBNET, gateway $DOCKER_NETWORK_GATEWAY)"
	log "Deployment path: $DEPLOY_PATH"
	log "Assets path: $ASSETS_PATH"
}

main "$@"
