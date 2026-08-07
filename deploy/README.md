# Deploying OpenProject to production

This deploys the OpenProject source in this repository to a single Ubuntu
24.04 server via GitHub Actions + SSH:

- **OpenProject runs in Docker** (custom image built from `docker/prod/Dockerfile`,
  `slim` target - the image the upstream docs recommend for production).
- **PostgreSQL runs natively on the Ubuntu host**, managed by systemd. It is
  **not** a Docker container and does not appear in
  [`docker-compose.prod.yml`](./docker-compose.prod.yml).

## Architecture

```text
GitHub Actions (on push to main / workflow_dispatch)
  -> build openproject-custom:<run_number>-<short_sha> from docker/prod/Dockerfile (slim target)
  -> ssh to the production server
       -> prepare-server.sh   : Docker Engine, fixed-subnet "openproject_net" bridge, dirs, ufw
       -> setup-postgresql.sh : native PostgreSQL 17 (install / configure / verify)
       -> backup.sh           : pg_dump + assets tarball (skipped on first deploy)
       -> docker save | ssh | docker load   : image transfer (no registry)
       -> docker-compose.prod.yml, .env.prod, nginx conf transferred
       -> deploy.sh           : docker compose up -d (seeder runs migrations first, blocking)
       -> health-check.sh
```

```text
Ubuntu 24.04
├── PostgreSQL 17 (native, systemd, port 5432 - not published)
│   ├── database: openproject, owner: openproject
│   └── pg_hba.conf allows only 172.28.1.0/24 (the openproject_net subnet)
├── Docker (openproject_net, subnet 172.28.1.0/24)
│   ├── web      (openproject-custom:<tag>, ./docker/prod/web)
│   ├── worker   (openproject-custom:<tag>, ./docker/prod/worker)
│   ├── seeder   (openproject-custom:<tag>, ./docker/prod/seeder - runs once)
│   ├── cache    (memcached)
│   └── proxy    (nginx, publishes 80/443)
├── /opt/openproject                  (docker-compose.prod.yml, .env.prod, backups/, scripts/)
└── /var/openproject/assets           (OpenProject attachments, bind-mounted into web/worker)
```

OpenProject containers reach PostgreSQL via `host.docker.internal` (mapped to
the `openproject_net` gateway, `172.28.1.1`, via `extra_hosts:
host-gateway`). `pg_hba.conf` only accepts the `openproject` role on the
`openproject` database from `172.28.1.0/24` - not from `0.0.0.0/0`, and not
from the internet. See [`setup-postgresql.sh`](./scripts/setup-postgresql.sh)
and [`prepare-server.sh`](./scripts/prepare-server.sh) for exactly how that
subnet is pinned before PostgreSQL is configured, so the rule never drifts.

## Why no `db` service in Compose

By design. PostgreSQL is native software on the host, not a container - see
`deploy/docker-compose.prod.yml`'s header comment. `DATABASE_URL` (the
mechanism `config/database.production.yml` in this repo reads, confirmed by
inspecting it before writing this) points at `host.docker.internal:5432`.

## GitHub Actions prerequisites

- A GitHub Actions runner able to build Docker images (`ubuntu-latest` works
  out of the box - Docker + buildx are preinstalled).
- No GitHub App/plugin installs required; the workflow only uses
  `actions/checkout@v4`.

## Required GitHub Secrets

| Secret | Purpose |
| --- | --- |
| `SERVER_SSH_KEY` | Private key for the deploy user on the production server. |
| `SSH_KNOWN_HOSTS` | Output of `ssh-keyscan -p <port> <host>`, run once from a trusted machine. Required - the workflow refuses to fall back to `StrictHostKeyChecking=no`. |
| `OPENPROJECT_DB_PASSWORD` | Password for the native PostgreSQL `openproject` role. Never logged; GitHub automatically masks it wherever it appears in step output. |
| `OPENPROJECT_SECRET_KEY_BASE` | Rails `SECRET_KEY_BASE`. Generate **once** with `openssl rand -hex 64` and never rotate it casually - it must stay constant across deployments or existing sessions/encrypted data become unreadable. |
| `OPENPROJECT_COLLABORATION_SECRET` | Optional. Only needed if you run a separate hocuspocus collaborative-editing service and want to wire it in. |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | Optional. Only needed if you want outbound email; the workflow only emits SMTP config when both are set. |

## Required GitHub (repository or environment) Variables

| Variable | Example | Notes |
| --- | --- | --- |
| `DEPLOY_HOST` | `203.0.113.10` | |
| `DEPLOY_USER` | `deploy` | Must be able to `sudo` (for Docker/PostgreSQL install) and, after the first run, be a member of the `docker` group. |
| `DEPLOY_PORT` | `22` | Optional, defaults to `22`. |
| `DEPLOY_PATH` | `/opt/openproject` | Optional, defaults to `/opt/openproject`. |
| `OPENPROJECT_HOST_NAME` | `openproject.example.com` | Public hostname; used by nginx `server_name` and OpenProject's `OPENPROJECT_HOST__NAME`. |
| `OPENPROJECT_HTTPS` | `false` | Only set to `true` once TLS certs are actually in place (see below) - `docker-compose.prod.yml`'s proxy publishes 443, but nothing terminates TLS there until you provide certs. |
| `APP_PORT` | `80` | Public HTTP port. |
| `IMAGE_NAME` | `openproject-custom` | Local image name; never the public `openproject/openproject` image. |
| `DB_NAME` | `openproject` | Optional, defaults to `openproject`. |
| `DB_USER` | `openproject` | Optional, defaults to `openproject`. |

## First deployment (clean Ubuntu 24.04 + SSH only)

1. Provision the Ubuntu 24.04 server; ensure the `DEPLOY_USER` account exists
   with SSH key auth and passwordless (or interactive) `sudo`.
2. Generate `SSH_KNOWN_HOSTS`:
   ```shell
   ssh-keyscan -p <DEPLOY_PORT> <DEPLOY_HOST> > known_hosts.txt
   ```
   Paste the contents into the `SSH_KNOWN_HOSTS` secret.
3. Generate `OPENPROJECT_SECRET_KEY_BASE` once: `openssl rand -hex 64`.
4. Choose `OPENPROJECT_DB_PASSWORD` and store it as a secret.
5. Set the GitHub Variables above (at minimum `DEPLOY_HOST`, `DEPLOY_USER`,
   `OPENPROJECT_HOST_NAME`).
6. Push to `main` (or run the workflow manually via **Actions -> Deploy
   OpenProject to Production -> Run workflow**).
7. The workflow installs Docker + native PostgreSQL 17, creates the
   `openproject` role/database, skips the backup step (nothing to back up
   yet), builds and ships the image, runs the seeder (`db:structure:load` +
   `db:seed` via OpenProject's own `docker/prod/seeder`), starts web/worker/
   cache/proxy, and health-checks `/health_checks/default`.
8. Visit `http://<OPENPROJECT_HOST_NAME>` and log in as `admin` / the
   password shown in the seeder's output (only visible in the very first
   run's logs - change it immediately).

## Normal (subsequent) deployment

Push to `main`. The pipeline is identical, except:

- **Backup existing deployment** now runs for real (`pg_dump` + assets
  tarball) before anything is touched.
- **Migrations**: the seeder container re-runs `db:migrate` (idempotent - no
  pending migrations means it's a no-op) before web/worker are (re)started,
  because `web`/`worker` `depends_on: seeder: condition:
  service_completed_successfully`. A failing migration fails the seeder
  container, which fails `docker compose up`, which fails the `Deploy
  OpenProject` step, which fails the workflow and triggers the rollback
  handler.
- PostgreSQL install/configure/verify steps are idempotent no-ops if nothing
  changed (see "Idempotency" below).

## Idempotency

- `prepare-server.sh`: re-running skips Docker install if already present,
  and refuses (rather than silently recreating) if `openproject_net` exists
  with an unexpected subnet.
- `setup-postgresql.sh configure`: creates the `openproject` role/database
  only if missing; **always re-syncs the role's password** to the current
  `OPENPROJECT_DB_PASSWORD` secret (by design, so the DB never silently
  drifts from the secret - don't rotate that secret casually); only reloads
  PostgreSQL if `postgresql.conf`/`pg_hba.conf` actually changed.
- `backup.sh`: no-ops safely on the first deployment (checked via the
  absence of `$DEPLOY_PATH/current_image_tag`).

## Database backup / restore

Backups land in `/opt/openproject/backups/<UTC timestamp>/`:
`database.dump` (custom-format `pg_dump`), `assets.tar.gz`, and a `config/`
copy of that deployment's compose file, `.env.prod`, and image tag.

Manual backup: `sudo /opt/openproject/scripts/backup.sh`

Restore the database (⚠️ run manually, deliberately not automated):

```shell
sudo systemctl stop postgresql   # or at least stop app containers first:
#   cd /opt/openproject && docker compose stop web worker
sudo -u postgres dropdb openproject
sudo -u postgres createdb -O openproject openproject
sudo -u postgres pg_restore -d openproject /opt/openproject/backups/<timestamp>/database.dump
sudo systemctl start postgresql
```

Restore assets:

```shell
sudo tar -xzf /opt/openproject/backups/<timestamp>/assets.tar.gz -C /var/openproject/
```

## Rollback

`scripts/rollback.sh` runs automatically when any deploy-pipeline step fails
(the workflow's `Collect failure diagnostics and roll back` step). It:

1. Dumps `docker compose logs`/`ps -a` to `backups/rollback_<timestamp>/`.
2. Restores `IMAGE_NAME`/`IMAGE_TAG` in `.env.prod` to the previously
   deployed image (recorded in `current_image_tag` by the prior successful
   `deploy.sh` run).
3. Restarts `web`/`worker`/`cache`/`proxy` on the old image, **without**
   re-running the seeder.
4. Runs `health-check.sh` again.

**What it never does:** touch PostgreSQL, drop/restore the database, or
revert migrations. If the failed deployment already ran a migration,
rolling the *application* back to older code that doesn't know about the
new schema can itself be unsafe - there is no generic, automatic way to
reverse a migration. Treat a rollback after a failed migration as "the app
is back on old code" only; deciding whether the database also needs manual
attention is a human call.

Manual rollback: `cd /opt/openproject && sudo ./scripts/rollback.sh` (only
works if `previous_image_tag` exists, i.e. at least one prior successful
deployment happened).

## Health checks

`scripts/health-check.sh` checks, with retries (OpenProject can take a
while to boot):

1. `systemctl is-active postgresql`
2. `docker compose ps` - `web`/`worker`/`cache`/`proxy` running, `seeder`
   exited `0`
3. `curl http://localhost:$APP_PORT/health_checks/default`

On failure it prints `systemctl status postgresql`, `docker compose ps -a`,
and recent `web`/`worker` logs (never secrets/env files) to stderr, then
exits non-zero.

Manual run: `cd /opt/openproject && ./scripts/health-check.sh` (no `sudo`
needed - `systemctl is-active` and `docker compose` are usable by the
deploy user).

## Server restart behavior

- `systemctl enable docker` and `systemctl enable postgresql` are both set
  by `prepare-server.sh`/`setup-postgresql.sh`.
- Every service in `docker-compose.prod.yml` uses `restart: unless-stopped`,
  so `dockerd` restarting containers on boot brings the stack back up
  automatically once Docker itself starts.
- Test with `sudo reboot`, then `systemctl is-active postgresql` and
  `docker compose -f /opt/openproject/docker-compose.prod.yml --env-file
  /opt/openproject/.env.prod ps`.

## Firewall

`prepare-server.sh` configures `ufw` to allow only `22`, `80`, `443`
(default-deny everything else inbound). PostgreSQL's `5432` is **never**
opened in `ufw` - it is only reachable via `127.0.0.1` (local) and the
`openproject_net` Docker bridge (`172.28.1.0/24`), neither of which crosses
a public interface.

## HTTPS / domain configuration

By default the proxy serves plain HTTP
(`deploy/nginx/openproject.conf.template`) and `OPENPROJECT_HTTPS=false`.
To enable HTTPS:

1. Obtain a certificate (e.g. via `certbot`) for `OPENPROJECT_HOST_NAME` and
   place `fullchain.pem`/`privkey.pem` under
   `/opt/openproject/nginx/certs/` on the server.
2. Set the `OPENPROJECT_HTTPS` GitHub Variable to `true`.
3. Re-run the workflow. `Transfer deployment files` will render
   `deploy/nginx/openproject.conf.https.template` instead (redirects 80 ->
   443, terminates TLS) and `.env.prod` will set `OPENPROJECT_HTTPS=true`,
   which makes OpenProject itself emit secure-only cookies and HSTS.

Never set `OPENPROJECT_HTTPS=true` before certs are actually in place - that
locks out plain-HTTP access via secure-only session cookies.

## Docker commands

```shell
cd /opt/openproject

docker compose -f docker-compose.prod.yml --env-file .env.prod ps
docker compose -f docker-compose.prod.yml --env-file .env.prod logs --tail=200
docker compose -f docker-compose.prod.yml --env-file .env.prod logs -f
docker compose -f docker-compose.prod.yml --env-file .env.prod restart web worker
```

`docker compose down -v` and `docker system prune -a --volumes` are
deliberately never used anywhere in this pipeline - they would destroy the
assets bind mount contents or unrelated Docker state. Don't run them
manually either unless you specifically intend to wipe everything.

## Native PostgreSQL commands

```shell
sudo systemctl status postgresql
sudo systemctl restart postgresql
sudo -u postgres psql
sudo -u postgres psql -l
```

## Troubleshooting

- **`Deploy OpenProject` fails with seeder logs about migrations**: check
  `docker compose logs seeder` on the server; the workflow already prints
  the last 200 lines automatically. Fix the migration issue in code, don't
  patch it on the server (the server never runs anything but the image CI
  built).
- **Health check fails only on the HTTP step, containers look fine**: the
  app may just still be booting - `health-check.sh` retries for ~5 minutes
  by default (`HEALTH_CHECK_RETRIES` / `HEALTH_CHECK_RETRY_DELAY_SECONDS`
  env vars if you need longer).
- **`setup-postgresql.sh verify` fails on TCP auth**: confirm
  `OPENPROJECT_DB_PASSWORD` in the GitHub secret actually matches what's in
  `.env.prod`'s `DATABASE_URL` on the server (they're generated from the
  same secret every run, so a mismatch usually means the secret changed
  without the intent of rotating the DB password - see Idempotency above).
- **Containers can't reach PostgreSQL**: confirm `docker network inspect
  openproject_net` shows subnet `172.28.1.0/24`, and that
  `/etc/postgresql/17/main/pg_hba.conf` has the `openproject-docker-access`
  block with that exact subnet.

## One-time manual actions

- Creating the `DEPLOY_USER` account and its SSH key pair on the server
  (this pipeline never creates OS user accounts).
- Generating and storing `SSH_KNOWN_HOSTS` and `OPENPROJECT_SECRET_KEY_BASE`.
- Changing the default `admin` password after the very first deployment.
- Obtaining/renewing TLS certificates if HTTPS is enabled (not automated
  here - bring your own `certbot` cron job or equivalent on the host).
