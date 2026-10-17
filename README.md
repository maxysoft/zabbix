# Zabbix 7.4 + TimescaleDB on Docker Compose

A production-oriented Zabbix stack: PostgreSQL with TimescaleDB, Zabbix server, the web UI over HTTPS, an agent that monitors the Docker host, automatic first-run configuration, Telegram and per-environment Slack notifications, and nightly database backups.

## What's in the stack

| Service | Image | Purpose |
| --- | --- | --- |
| `postgres-server` | `timescale/timescaledb:2.29.2-pg18` | PostgreSQL 18 with TimescaleDB. Data lives in the named volume `pgdata`. |
| `zabbix-server` | `zabbix/zabbix-server-pgsql` | Zabbix server. Creates the schema and TimescaleDB hypertables on first start and sets the `Admin` password. |
| `zabbix-web` | `zabbix/zabbix-web-nginx-pgsql` | Web UI and API, served by the image's nginx over HTTPS on container port 8443. |
| `zabbix-agent` | `zabbix/zabbix-agent2` | Agent 2 that monitors the Docker host as the host "Zabbix server". |
| `zabbix-bootstrap` | `zabbix/zabbix-server-pgsql` | One-shot job that configures Zabbix through its API on every `docker compose up`. |
| `zabbix-backup` | `timescale/timescaledb:2.29.2-pg18` | Nightly `pg_dump` of the Zabbix database into `./backups`. |

The stack runs Zabbix 7.4 (7.4.15 at the time of writing) through the `alpine-7.4-latest` tags. Every image in `compose.yaml` is pinned by digest. Renovate opens pull requests for image rebuilds and 7.4.x patch releases; TimescaleDB updates are limited to the versions Zabbix 7.4 supports.

The Nord theme from the original project is included and ported to 7.4. Each user can select it under User settings > Profile > Theme.

## Requirements

- A Linux host with Docker Engine 25 or later and the Docker Compose plugin v2.24 or later.
- About 2 GB of free RAM for a small installation. See [Sizing](#sizing-and-resource-limits).
- Root access (sudo) to run `setup.sh`.
- The Docker service enabled at boot (`systemctl enable --now docker`). The containers use `restart: unless-stopped`, so the stack starts again with the Docker daemon. No systemd unit is needed.

## Quick start

```sh
sudo git clone https://github.com/r4ven-me/zabbix.git /opt/zabbix
cd /opt/zabbix
sudo cp .env.example .env
sudo nano .env
sudo ./setup.sh
docker compose up -d
```

Set at least `ZBX_PUBLIC_URL` in `.env` before you run `setup.sh`, because the self-signed certificate is created for its host name. `setup.sh` creates `.env` from `.env.example` if it is missing, generates the database and Admin passwords, creates empty bot token files, creates a self-signed TLS certificate and the `backups` directory. It is safe to run again: it never overwrites an existing secret, it only fixes file permissions.

The first start creates the database schema, which takes one to a few minutes. `docker compose up -d` returns when the database, server and web UI are healthy and the bootstrap job has started. Check the bootstrap result with:

```sh
docker compose logs zabbix-bootstrap
```

Open `ZBX_PUBLIC_URL` (by default `https://localhost:8443`) and log in as `Admin`. The password is in `secrets/zabbix_admin_password`:

```sh
sudo cat secrets/zabbix_admin_password
```

Your browser warns about the self-signed certificate until you replace it or trust it. See [TLS certificate](#tls-certificate).

## Configuration reference

### .env

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZBX_WEB_BIND` | `127.0.0.1` | Host address the HTTPS web UI is published on. Use `0.0.0.0` or a LAN address to reach it from other machines. |
| `ZBX_WEB_PORT` | `8443` | Host port of the HTTPS web UI. |
| `ZBX_SERVER_BIND` | `127.0.0.1` | Host address of the Zabbix server port (10051) for remote agents and proxies. |
| `ZBX_SERVER_PORT` | `10051` | Host port of the Zabbix server. |
| `ZBX_PUBLIC_URL` | `https://localhost:8443` | URL users open in the browser. It is set as the frontend URL, used in notification links and as the name in the self-signed certificate. |
| `ZBX_SERVER_NAME` | `Zabbix` | Name shown in the title and header of the web UI. |
| `TZ` | `UTC` | Time zone of all containers and of the web UI. Backups run at `BACKUP_HOUR` in this time zone. |
| `TELEGRAM_CHAT_ID` | empty | Telegram chat that receives alerts. See [Telegram](#telegram). |
| `SLACK_CHANNELS` | empty | Slack channel per environment, for example `prod:#alerts-prod,test:#alerts-test`. See [Slack](#slack). |
| `BACKUP_HOUR` | `3` | Hour (0-23, local time) of the nightly backup. |
| `BACKUP_KEEP_DAYS` | `7` | Backups older than this number of days are deleted. |
| `BACKUP_EXCLUDE_HISTORY` | `false` | `true` leaves history and trends data out of the nightly backup. See [Backups](#backups). |

After you change `.env`, run `docker compose up -d`. Compose recreates the affected containers and the bootstrap job applies the new notification settings.

### Secrets

Secrets live in files under `secrets/`, never in `.env` or in container environment variables. Containers receive only the files they need, mounted read-only.

| File | Created by | Used by |
| --- | --- | --- |
| `secrets/postgres_password` | `setup.sh` | PostgreSQL superuser `postgres` (initialisation and maintenance only) |
| `secrets/zabbix_db_password` | `setup.sh` | Database role `zabbix`: server, web UI, backups |
| `secrets/zabbix_admin_password` | `setup.sh` | Web UI user `Admin`: set when `zabbix-server` creates the schema, used by the bootstrap job |
| `secrets/telegram_bot_token` | you (empty by default) | Telegram media type |
| `secrets/slack_bot_token` | you (empty by default) | Slack media type |
| `secrets/tls/ssl.crt`, `secrets/tls/ssl.key` | `setup.sh` (self-signed) or you | nginx in `zabbix-web` |

`secrets/` is readable by root only. The files inside are mode 0444, because the containers run as non-root users (postgres uid 70, zabbix uid 1997) and Compose cannot change the owner of a file secret. After you edit or replace a file in `secrets/`, run `sudo ./setup.sh` again to restore the permissions, then `docker compose up -d --force-recreate <service>`.

The database passwords are only read when the database is initialised. Changing `postgres_password` or `zabbix_db_password` later requires changing the role password in PostgreSQL as well (`ALTER ROLE ... PASSWORD`).

### Admin password

When `zabbix-server` creates the database schema on the first start, it sets the `Admin` password from `secrets/zabbix_admin_password` before the server and the web UI start. The default password `zabbix` never works. If the very first start is interrupted before that step, the bootstrap job finds the default password and replaces it with the one from the file. The bootstrap job logs in with the same file on every run. The file is only read at schema creation, so changing it later does not change the password.

To rotate the Admin password, change it in the web UI and write the same password into `secrets/zabbix_admin_password` (`sudo nano secrets/zabbix_admin_password`, then `sudo ./setup.sh`). If the file does not match the UI password, the bootstrap job fails with the API error and a hint about the file, and the notification settings are not applied.

### TLS certificate

`setup.sh` creates a self-signed certificate for the host name in `ZBX_PUBLIC_URL` (plus `localhost`), valid for 825 days. To use a real certificate:

1. Copy the full certificate chain to `secrets/tls/ssl.crt` and the private key to `secrets/tls/ssl.key`.
2. Run `sudo ./setup.sh` to fix the permissions.
3. Run `docker compose up -d --force-recreate zabbix-web`.

To create a new self-signed certificate, for example after changing `ZBX_PUBLIC_URL`, delete both files and run `sudo ./setup.sh`.

The web image already sends HSTS (`max-age=63072000`) and a report-only Content Security Policy. Because of HSTS, browsers remember to use HTTPS for the host name; do not serve plain HTTP on the same name later.

If you prefer a reverse proxy (for example with automatic Let's Encrypt certificates), keep `ZBX_WEB_BIND=127.0.0.1` and point the proxy at `https://127.0.0.1:8443`.

`config/nginx/dhparam.pem` is the standard RFC 7919 `ffdhe2048` group. It is public and needs no change.

### Exposing the Zabbix server port

Remote agents in active mode and Zabbix proxies connect to the server on port 10051. By default the port is published on `127.0.0.1` only. To accept remote connections, set `ZBX_SERVER_BIND=0.0.0.0` (or one host address) and run `docker compose up -d`.

Docker writes its own firewall rules for published ports, and these bypass `ufw` and `firewalld` rules on many systems. Use the bind address to limit exposure, and restrict sources in the `DOCKER-USER` iptables chain or in an external firewall. Use PSK or certificate encryption for remote agents.

### Sizing and resource limits

Memory limits per container are set in `compose.yaml`:

| Service | Limit |
| --- | --- |
| `postgres-server` | 2 GB |
| `zabbix-server` | 1 GB |
| `zabbix-web` | 512 MB |
| `zabbix-agent` | 256 MB |
| `zabbix-backup` | 512 MB |
| `zabbix-bootstrap` | 128 MB |

To change them, create `compose.override.yaml` next to `compose.yaml`; Compose reads it automatically:

```yaml
services:
  postgres-server:
    deploy:
      resources:
        limits:
          memory: 8g
  zabbix-server:
    environment:
      ZBX_CACHESIZE: 256M
      ZBX_STARTPOLLERS: "10"
```

The TimescaleDB image tunes PostgreSQL (`shared_buffers`, `work_mem`, `max_connections=200` and others) from the memory limit only once, when the database is initialised. To re-tune after changing the limit:

```sh
docker compose exec postgres-server timescaledb-tune --yes --quiet \
  --memory=8GB --max-conns=200 --conf-path=/var/lib/postgresql/18/docker/postgresql.conf
docker compose restart postgres-server
```

Zabbix server settings are set with `ZBX_*` environment variables, as described in the documentation of the `zabbix/zabbix-server-pgsql` image.

## Notifications

The bootstrap job configures notifications on every `docker compose up`.

### Telegram

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy the token.
2. Add the bot to the chat or group that should receive alerts and find the chat id (for example with the `getUpdates` method of the Bot API). Group ids are negative numbers.
3. Write the token into `secrets/telegram_bot_token` (`sudo nano secrets/telegram_bot_token`).
4. Set `TELEGRAM_CHAT_ID` in `.env`.
5. Run `sudo ./setup.sh`, then `docker compose up -d`.

The bootstrap job sets the token on the built-in "Telegram" media type and enables it, gives the `Admin` user a Telegram media entry for the chat, and enables the default action "Report problems to Zabbix administrators". That action notifies the "Zabbix administrators" group, which contains `Admin`, about every problem. Telegram stays untouched while the token or `TELEGRAM_CHAT_ID` is empty.

The bootstrap job manages the Telegram media of `Admin`: on every run it keeps one Telegram entry for `TELEGRAM_CHAT_ID` and removes all other Telegram entries of `Admin`. To notify more chats, give another user its own Telegram media.

### Slack

One Zabbix instance can send problems of different environments to different Slack channels. The environment of a problem comes from the event tag `env`.

1. Create a Slack app with a bot token (`xoxb-...`). The built-in Zabbix Slack media type expects the scopes `chat:write`, `im:write`, `groups:write` and `reactions:write`.
2. Invite the bot to every target channel (`/invite @your-bot`).
3. Write the token into `secrets/slack_bot_token`.
4. Set `SLACK_CHANNELS` in `.env`, for example `SLACK_CHANNELS=prod:#alerts-prod,test:#alerts-test`. Environment names may contain letters, digits, `_` and `-`.
5. Run `sudo ./setup.sh`, then `docker compose up -d`.
6. Tag your hosts (or their templates) with `env=prod` or `env=test`. Host and template tags are copied to the problem events. Problems without an `env` tag are not sent to Slack.

For each environment the bootstrap job creates:

- a user `slack-<env>` with a Slack media entry for the channel and a random password that is not stored anywhere;
- an action `Slack: env=<env>` that sends problems with the tag `env=<env>` to that user, and also notifies about recoveries and updates.

The `slack-<env>` users have the role "Slack notifications", which is of type Super admin so that the users can see every host and no alert is dropped because of missing permissions. The role has API access and all optional UI sections disabled; Zabbix requires one UI section to stay enabled, so "Monitoring > Problems" is left on. The users are members of the group "Slack notifications", which has no frontend access, so nobody can log in as these users.

To add an environment, append it to `SLACK_CHANNELS` and run `docker compose up -d`. To change a channel, edit it the same way. When you remove an environment from `SLACK_CHANNELS`, or empty the variable, the action of each removed environment is disabled, not deleted. This also happens while `secrets/slack_bot_token` is empty; new environments are only set up when the token is set.

## Operations

### Status and logs

```sh
docker compose ps
docker compose logs -f zabbix-server
docker compose logs zabbix-bootstrap
```

Logs use the `json-file` driver with rotation (5 files of 10 MB per container).

To run the bootstrap job without restarting anything: `docker compose up -d zabbix-bootstrap` or `docker compose run --rm zabbix-bootstrap`.

### Upgrades

Back up before every upgrade.

Patch releases and image rebuilds (7.4.x): merge the Renovate pull request, or update the digests in `compose.yaml` yourself, then:

```sh
docker compose pull
docker compose up -d
```

The Zabbix server upgrades the database schema itself when it starts with a newer version.

Zabbix 8.0 (next LTS): read the Zabbix upgrade notes first. In `compose.yaml`, change all four Zabbix image lines (`zabbix-server`, `zabbix-web`, `zabbix-agent` and `zabbix-bootstrap`) to the 8.0 tag and its digest. Check which TimescaleDB versions Zabbix 8.0 supports, and change `allowedVersions` of the TimescaleDB rule in `renovate.json` to that range. Check that `theme/APP.php` still matches the `APP.php` of the new web image, and regenerate the Nord stylesheet with `theme/build.sh`, which reads the web image from `compose.yaml`. Then pull and start as above.

TimescaleDB: never move to a TimescaleDB version that your Zabbix version does not support. Zabbix 7.4 supports TimescaleDB 2.13 to 2.29 and refuses to start with 2.30 or later. To change the TimescaleDB image, stop the database clients, start the new image, update the extension as the `postgres` superuser in every database that has it (the `zabbix` role does not own the extension), then start the rest of the stack:

```sh
docker compose stop zabbix-server zabbix-web zabbix-backup
docker compose pull postgres-server
docker compose up -d postgres-server
for db in zabbix postgres template1; do
  docker compose exec -T postgres-server psql -U postgres -d "$db" -X -c 'ALTER EXTENSION timescaledb UPDATE'
done
docker compose up -d
```

PostgreSQL major versions (18 to 19) need a dump and restore into a new volume; see [Restore](#restore).

### Backups

`zabbix-backup` writes a full `pg_dump -Fc` dump every night at `BACKUP_HOUR` (local time in `TZ`) to `./backups/zabbix-YYYYMMDD-HHMMSS.dump`, and deletes dumps older than `BACKUP_KEEP_DAYS`. The backup runs as the `zabbix` database role. `./backups` belongs to the postgres container user (uid 70) with mode 0700, so on the host only root can read it. The dumps contain secrets: the Telegram and Slack bot tokens and the password hashes of all users. Protect every copy the same way, and encrypt dumps before you store them on another machine.

With `BACKUP_EXCLUDE_HISTORY=true` the dumps (named `...-nohistory.dump`) contain the full schema and configuration but no data of the history and trends tables, including their compressed TimescaleDB chunks. Such dumps are much smaller; a restore from them starts with empty graphs.

Run a backup now:

```sh
docker compose run --rm zabbix-backup --once
docker compose run --rm -e BACKUP_EXCLUDE_HISTORY=true zabbix-backup --once
```

If a nightly backup fails, `zabbix-backup` is reported as unhealthy in `docker compose ps` until the next successful run. The result is kept in `backups/.status`, so a restart of the container does not clear it. Copy `./backups` to another machine regularly; a backup on the same disk does not protect against disk loss.

`pg_dump` prints a warning about circular foreign-key constraints on `continuous_agg`. It comes from the TimescaleDB catalog and does not affect the restore.

### Restore

Run these commands as root in `/opt/zabbix`. The restore needs the `postgres` superuser and the same TimescaleDB version that wrote the dump. Replace the file name with your dump.

```sh
docker compose stop zabbix-server zabbix-web zabbix-backup
docker compose exec -T postgres-server psql -U postgres -c 'DROP DATABASE zabbix WITH (FORCE)'
docker compose exec -T postgres-server psql -U postgres -c 'CREATE DATABASE zabbix OWNER zabbix'
docker compose exec -T postgres-server psql -U postgres -d zabbix -c 'SELECT timescaledb_pre_restore()'
docker compose exec -T postgres-server pg_restore -U postgres -d zabbix --exit-on-error < backups/zabbix-YYYYMMDD-HHMMSS.dump
docker compose exec -T postgres-server psql -U postgres -d zabbix -c 'SELECT timescaledb_post_restore()'
docker compose up -d
```

To test a dump without touching the live database, use another database name (for example `zabbix_restore`) in the `CREATE DATABASE`, `pg_restore` and `psql` commands and skip the first two lines; drop it afterwards.

To move to a new host, copy `.env` and `secrets/` from the old host (so that the passwords match the dump), run `sudo ./setup.sh` there to fix the permissions, start only `postgres-server` (`docker compose up -d postgres-server`), and follow the steps above.

## Security notes

What the stack does by default:

- The web UI is served over HTTPS only. Plain HTTP (container port 8080) is never published; it is used inside the stack for the health check and by the bootstrap job over the internal network. Server version headers are disabled.
- The web UI and the server port are published on `127.0.0.1` unless you change the bind addresses. PostgreSQL is never published.
- The `backend` network is internal (no internet access). PostgreSQL, the agent, the bootstrap job and the backup job are only on this network. `zabbix-server` and `zabbix-web` are also on the `frontend` network: the server needs internet access for Telegram and Slack webhooks and remote agents, and the web UI must be published.
- Zabbix connects to PostgreSQL as the role `zabbix`, which owns the database but is not a superuser. The superuser `postgres` is only used to initialise the database and for maintenance (restore, extension updates).
- Secrets are files in a root-only directory, mounted read-only into the containers that need them. Scripts pass secrets through files and pipes, never as command-line arguments, and never print them.
- The default `Admin` password never works: the password from `secrets/zabbix_admin_password` is set when the schema is created, before the server and the web UI start. Guest access stays disabled.
- TimescaleDB telemetry is off.
- Every container except the agent runs as a non-root user with all Linux capabilities dropped and `no-new-privileges`. All of them except the web UI have a read-only root filesystem with `tmpfs` for runtime files.
- Images are pinned by digest. The CI workflow runs shellcheck, validates the Compose file, checks that the Nord stylesheet matches the pinned web image, and scans the images with Trivy on every push and every week.

The Trivy scan fails on fixable HIGH and CRITICAL vulnerabilities. Findings that do not affect this stack are listed in `.trivyignore.yaml`, each with the reason and an expiry date (`expired_at`). After that date the scan fails again, and each entry must be checked again: delete it when a new image fixes the vulnerability, or extend it with a new reason. The Go command-line tools of the TimescaleDB image (`gosu`, `timescaledb-parallel-copy`, `timescaledb-tune`) are skipped, because they never handle network input.

Exceptions and why they exist:

- `zabbix-web` runs without a read-only root filesystem. Its entrypoint writes the nginx and PHP configuration at every start, for example `/etc/nginx/includes/access-log.conf`, and edits `/etc/nginx/nginx.conf` in place. With `read_only: true` it fails with `/etc/nginx/includes/access-log.conf: Read-only file system`. A `tmpfs` on those directories would hide the configuration files of the image.
- `zabbix-server` keeps the `NET_RAW` capability. ICMP checks use `fping`, which needs raw sockets; without the capability `fping` cannot run ("Operation not permitted").
- `zabbix-agent` runs with `privileged: true` and `pid: host`, so that it can monitor the Docker host (processes, CPU, memory, devices) instead of only its own container. This is a deliberate trade-off: a compromised agent container has root-equivalent access to the host. The agent only accepts connections from `zabbix-server` and is only reachable on the internal network. If you only want to monitor the stack itself, remove `privileged` and `pid` from the agent service.
- `postgres-server` and `zabbix-backup` use `tmpfs` for `/tmp` and the PostgreSQL socket directory; `zabbix-server` uses `tmpfs` for `/tmp` and its internal CA directory, which its entrypoint fills at start.

## Remote agents

To monitor other machines, install Zabbix agent 2 on them and add them as hosts in the web UI. For active checks, the agents connect to the server port; see [Exposing the Zabbix server port](#exposing-the-zabbix-server-port). For passive checks, the server connects to the agents on port 10050.

A Docker Compose setup for a remote agent is available at [r4ven-me/zabbix-agent](https://github.com/r4ven-me/zabbix-agent).

## Testing

`scripts/e2e.sh` starts a complete stack in an isolated directory under `.audit/e2e/` with its own project name, ports and secrets, and checks setup, bootstrap (including notifications and its idempotency), the agent connection, TLS, the hardening settings, backups and a restore. It removes everything at the end. It needs Docker and about 3 GB of free RAM:

```sh
scripts/e2e.sh
```

## Credits

This project is based on [r4ven-me/zabbix](https://github.com/r4ven-me/zabbix) by r4ven-me ([Telegram channel](https://t.me/r4ven_me/)), including the Nord theme. The remote agent setup is [r4ven-me/zabbix-agent](https://github.com/r4ven-me/zabbix-agent).
