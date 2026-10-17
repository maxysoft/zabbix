# Zabbix 8.0 + TimescaleDB on Docker Compose

A production-oriented Zabbix stack: PostgreSQL with TimescaleDB, Zabbix server, the web UI over HTTPS, automatic first-run configuration, Telegram and per-environment Slack notifications, nightly database backups with optional encryption, and an install script for the agent that monitors the Docker host.

## What's in the stack

| Service | Image | Purpose |
| --- | --- | --- |
| `postgres-server` | `timescale/timescaledb:2.29.2-pg18` | PostgreSQL 18 with TimescaleDB. Data lives in the named volume `pgdata`. |
| `zabbix-server` | `zabbix/zabbix-server-pgsql` | Zabbix server. Creates the schema and TimescaleDB hypertables on first start and sets the `Admin` password. |
| `zabbix-web` | `zabbix/zabbix-web-nginx-pgsql` | Web UI and API, served by the image's nginx over HTTPS on container port 8443. |
| `zabbix-bootstrap` | built from `bootstrap/Dockerfile` | One-shot job that configures Zabbix through its API on every `docker compose up`. The image is Alpine with `bash`, `curl` and `jq`, because the Zabbix 8.0 server image no longer contains `curl` and `jq`. |
| `zabbix-backup` | built from `backup/Dockerfile` | Nightly `pg_dump` of the Zabbix database into `./backups`, optionally encrypted with `age`. The image is `timescale/timescaledb:2.29.2-pg18` plus the `age` and `age-keygen` binaries. |

The Docker host itself is monitored by Zabbix agent 2, installed on the host by `scripts/install-agent.sh`. See [Host agent](#host-agent).

The stack runs the Zabbix 8.0 release candidate (8.0.0rc2 at the time of writing) through the `alpine-trunk` tags, the only Zabbix 8.0 images on Docker Hub before the 8.0.0 release. Every image in `compose.yaml` is pinned by digest. Renovate does not update the `alpine-trunk` images, because `trunk` moves on to Zabbix 8.2 after the 8.0.0 release. When the `alpine-8.0-latest` tags are published, change both Zabbix image lines in `compose.yaml` (`zabbix-server` and `zabbix-web`) to `alpine-8.0-latest` and its digest; from then on Renovate opens pull requests for image rebuilds and 8.0.x patch releases. TimescaleDB updates are limited to the versions Zabbix 8.0 supports.

The Nord theme from the original project is included and ported to 8.0. Each user can select it under User settings > Profile > Theme.

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
sudo scripts/install-agent.sh
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
| `BACKUP_AGE_RECIPIENTS` | empty | Comma-separated `age` or SSH public keys. When set, the dumps are encrypted. See [Encrypted backups](#encrypted-backups). |

After you change `.env`, run `docker compose up -d`. Compose recreates the affected containers and the bootstrap job applies the new notification settings.

### Secrets

Secrets live in files under `secrets/`, never in `.env` or in container environment variables. Containers receive only the files they need, mounted read-only.

| File | Created by | Used by |
| --- | --- | --- |
| `secrets/postgres_password` | `setup.sh` | PostgreSQL superuser `postgres` (initialisation and maintenance only) |
| `secrets/zabbix_db_password` | `setup.sh` | Database role `zabbix`: server, web UI, backups |
| `secrets/zabbix_admin_password` | `setup.sh` | Web UI user `Admin`: hashed by PostgreSQL when the database is initialised, used by the bootstrap job |
| `secrets/telegram_bot_token` | you (empty by default) | Telegram media type |
| `secrets/slack_bot_token` | you (empty by default) | Slack media type |
| `secrets/tls/ssl.crt`, `secrets/tls/ssl.key` | `setup.sh` (self-signed) or you | nginx in `zabbix-web` |

`secrets/` is readable by root only. The files inside are mode 0444, because the containers run as non-root users (postgres uid 70, zabbix uid 1997) and Compose cannot change the owner of a file secret. After you edit or replace a file in `secrets/`, run `sudo ./setup.sh` again to restore the permissions, then `docker compose up -d --force-recreate <service>`.

The database passwords are only read when the database is initialised. Changing `postgres_password` or `zabbix_db_password` later requires changing the role password in PostgreSQL as well (`ALTER ROLE ... PASSWORD`).

### Admin password

When PostgreSQL initialises the database on the first start, `config/postgres/initdb/010_zabbix.sh` stores a bcrypt hash of the password from `secrets/zabbix_admin_password` in the table `zbx_admin_seed`. When `zabbix-server` then creates the Zabbix schema, it runs `config/zabbix/admin-password.sql`, which sets that hash as the `Admin` password and drops the table, before the server and the web UI start. The Zabbix 8.0 server image runs such scripts as plain SQL and cannot read the secret file itself, hence the two steps. The default password `zabbix` never works. If the very first start is interrupted before the schema step, the bootstrap job finds the default password and replaces it with the one from the file. The bootstrap job logs in with the same file on every run. The file is only read when the database is initialised, so changing it later does not change the password.

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

The host agent, remote agents in active mode and Zabbix proxies connect to the server on port 10051. By default the port is published on `127.0.0.1` only. To accept remote connections, set `ZBX_SERVER_BIND=0.0.0.0` (or one host address) and run `docker compose up -d`.

Docker writes its own firewall rules for published ports, and these bypass `ufw` and `firewalld` rules on many systems. Use the bind address to limit exposure, and restrict sources in the `DOCKER-USER` iptables chain or in an external firewall. Use PSK or certificate encryption for remote agents and for the host agent; see [Security notes](#security-notes).

### Sizing and resource limits

Memory limits per container are set in `compose.yaml`:

| Service | Limit |
| --- | --- |
| `postgres-server` | 2 GB |
| `zabbix-server` | 1 GB |
| `zabbix-web` | 512 MB |
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

## Host agent

Zabbix agent 2 runs on the Docker host as a system service and reports as the host "Zabbix server". Install it as root after the stack is up:

```sh
sudo scripts/install-agent.sh
```

The script supports Debian 12 and 13, Ubuntu 22.04 and 24.04, and RHEL 9 and 10 with their rebuilds (Rocky Linux, AlmaLinux, Oracle Linux, CentOS Stream). It installs the `zabbix-release` package for Zabbix 8.0 from `repo.zabbix.com`, writes `/etc/zabbix/zabbix_agent2.d/zabbix-compose.conf`, installs `zabbix-agent2`, checks the configuration and enables and restarts the `zabbix-agent2` service. It is safe to run again, for example after you change `ZBX_SERVER_BIND` or `ZBX_SERVER_PORT` in `.env`, or to update the agent.

The agent runs in active mode only. It connects to the Zabbix server port published on the host (`ZBX_SERVER_BIND` and `ZBX_SERVER_PORT` from `.env`; `127.0.0.1` when the bind address is `0.0.0.0`). It listens on no port, because `Server` is empty. The bootstrap job links the template "Linux by Zabbix agent active" to the host "Zabbix server" in place of "Linux by Zabbix agent". It unlinks the old template without clearing it, so Zabbix merges its items into the items of the active template with the same keys, and their history stays. Items of the old template that the active template does not have, such as `zabbix[host,agent,available]` and its trigger "Zabbix agent is not available", are deleted. The job does this only while "Linux by Zabbix agent" is linked to the host, so template changes you make on the host later are kept.

Until Zabbix 8.0.0 is released, agent 2 packages for 8.0 exist only in the `unstable` channel of the Zabbix repository. The current 8.0 `zabbix-release` package enables that channel itself, so the script installs the release candidate (8.0.0rc1 at the time of writing). After the 8.0.0 release, run the script again to install the current `zabbix-release` package and agent.

On other distributions, install Zabbix agent 2 version 8.0 by hand and create `/etc/zabbix/zabbix_agent2.d/zabbix-compose.conf` with your values of `ZBX_SERVER_BIND` and `ZBX_SERVER_PORT`:

```ini
Server=
ServerActive=127.0.0.1:10051
Hostname=Zabbix server
```

A setting in a file under `zabbix_agent2.d` overrides the same setting in `zabbix_agent2.conf`. Check the result with `zabbix_agent2 -T`, then enable and restart the agent service.

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

Patch releases and image rebuilds: merge the Renovate pull request, or update the digests in `compose.yaml` and the two Dockerfiles yourself, then:

```sh
docker compose pull
docker compose up -d --build
```

The Zabbix server upgrades the database schema itself when it starts with a newer version. `zabbix-backup` and `zabbix-bootstrap` are built locally from `backup/Dockerfile` and `bootstrap/Dockerfile`. `docker compose pull` skips them, and `--build` rebuilds them, so a new base image in these files (for example from a Renovate pull request) takes effect.

After an update of the web image, check that `theme/APP.php` still matches the `APP.php` of the new image, and regenerate the Nord stylesheet with `theme/build.sh`, which reads the web image from `compose.yaml`.

#### From Zabbix 7.4

Read the Zabbix 8.0 upgrade notes first. Zabbix 8.0 supports PostgreSQL 15 to 18 and TimescaleDB 2.20 to 2.29; the stack keeps `timescale/timescaledb:2.29.2-pg18`. In 7.4 the agent ran in the container `zabbix-agent`; in 8.0 it runs on the host.

1. Back up: `docker compose run --rm zabbix-backup --once`.
2. Stop the 7.4 server: `docker compose stop zabbix-server`. A running 7.4 server, or one that stopped less than a minute ago without shutting down cleanly, makes the 8.0 server wait before it upgrades the database.
3. Update the files (`git pull`) and compare `.env` with `.env.example` (new: `BACKUP_AGE_RECIPIENTS`).
4. Start the new version and remove the old agent container:

   ```sh
   docker compose up -d --build --remove-orphans
   ```

   The Zabbix server upgrades the database on its first start; follow it with `docker compose logs -f zabbix-server`. The bootstrap job then switches the host "Zabbix server" to the template "Linux by Zabbix agent active" and keeps the item history.
5. Zabbix 8.0 adds the history table `history_json`. Turn it into a TimescaleDB hypertable with the TimescaleDB script of the new server image, then restart the server:

   ```sh
   docker compose exec -T zabbix-server cat /usr/share/doc/zabbix-server-postgresql/timescaledb.sql |
     docker compose exec -T postgres-server psql -U zabbix -d zabbix -v ON_ERROR_STOP=1 -q
   docker compose restart zabbix-server
   ```

   The script skips tables that already are hypertables. Until this step, the server log shows `table "history_json" is not a hypertable`.
6. Install the agent on the host: `sudo scripts/install-agent.sh`.

Until step 6 the host "Zabbix server" receives no agent data. The old agent interface `zabbix-agent:10050` stays on the host but is no longer used.

TimescaleDB: never move to a TimescaleDB version that your Zabbix version does not support. Zabbix 8.0 supports TimescaleDB 2.20 to 2.29 and refuses to start with an unsupported version. `backup/Dockerfile` uses the same TimescaleDB image as `postgres-server`; change both together. To change the TimescaleDB image, stop the database clients, start the new image, update the extension as the `postgres` superuser in every database that has it (the `zabbix` role does not own the extension), then start the rest of the stack:

```sh
docker compose stop zabbix-server zabbix-web zabbix-backup
docker compose pull postgres-server
docker compose up -d postgres-server
for db in zabbix postgres template1; do
  docker compose exec -T postgres-server psql -U postgres -d "$db" -X -c 'ALTER EXTENSION timescaledb UPDATE'
done
docker compose up -d --build
```

PostgreSQL major versions (18 to 19) need a dump and restore into a new volume; see [Restore](#restore).

### Backups

`zabbix-backup` writes a full `pg_dump -Fc` dump every night at `BACKUP_HOUR` (local time in `TZ`) to `./backups/zabbix-YYYYMMDD-HHMMSS.dump`, and deletes dumps older than `BACKUP_KEEP_DAYS`. The backup runs as the `zabbix` database role. `./backups` belongs to the postgres container user (uid 70) with mode 0700, so on the host only root can read it. The dump files have mode 0600. The dumps contain secrets: the Telegram and Slack bot tokens and the password hashes of all users. Protect every copy the same way, and encrypt the dumps (see [Encrypted backups](#encrypted-backups)) before you store them on another machine.

With `BACKUP_EXCLUDE_HISTORY=true` the dumps (named `...-nohistory.dump`) contain the full schema and configuration but no data of the history and trends tables, including their compressed TimescaleDB chunks. Such dumps are much smaller; a restore from them starts with empty graphs.

Run a backup now:

```sh
docker compose run --rm zabbix-backup --once
docker compose run --rm -e BACKUP_EXCLUDE_HISTORY=true zabbix-backup --once
```

If a nightly backup fails, `zabbix-backup` is reported as unhealthy in `docker compose ps` until the next successful run. The result is kept in `backups/.status`, so a restart of the container does not clear it. Copy `./backups` to another machine regularly; a backup on the same disk does not protect against disk loss.

`pg_dump` prints a warning about circular foreign-key constraints on `continuous_agg`. It comes from the TimescaleDB catalog and does not affect the restore.

### Encrypted backups

Set `BACKUP_AGE_RECIPIENTS` in `.env` to encrypt the dumps with [age](https://age-encryption.org). The value is a comma-separated list of public keys: `age` keys (`age1...`) or SSH keys (`ssh-ed25519 AAAA... comment`, `ssh-rsa ...`). Each matching private key can decrypt the dumps. Encrypted dumps are named `zabbix-YYYYMMDD-HHMMSS.dump.age` (or `...-nohistory.dump.age`). `pg_dump` writes straight into `age`, so the unencrypted dump never touches the disk. `zabbix-backup` checks the keys when it starts and stops with an error if one of them is invalid. Old dumps of both kinds are deleted after `BACKUP_KEEP_DAYS`.

Create the key pair on your admin machine, not on the Zabbix server:

```sh
age-keygen -o zabbix-backup-key.txt
```

`age-keygen` prints the public key (`Public key: age1...`). Without a local `age`, `docker compose run --rm --no-deps --entrypoint age-keygen zabbix-backup` on the server prints a new key file to the terminal; copy it to the admin machine and do not store it on the server.

Put the public key into `.env` (`BACKUP_AGE_RECIPIENTS=age1...`) and run `docker compose up -d`. Keep the private key off the Zabbix server, and keep a second copy of it: without the private key, the encrypted dumps cannot be restored. Test a restore once.

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

For an encrypted dump, decrypt it on its way into `pg_restore` and replace the `pg_restore` line above with one of these. With `age` installed, and the key copied to the server for the restore only:

```sh
age -d -i zabbix-backup-key.txt backups/zabbix-YYYYMMDD-HHMMSS.dump.age |
  docker compose exec -T postgres-server pg_restore -U postgres -d zabbix --exit-on-error
```

Without `age` on the server, use the backup image. The key is read from standard input and is not written anywhere:

```sh
docker compose run --rm -T --no-deps --entrypoint age zabbix-backup -d -i - /backups/zabbix-YYYYMMDD-HHMMSS.dump.age < zabbix-backup-key.txt |
  docker compose exec -T postgres-server pg_restore -U postgres -d zabbix --exit-on-error
```

Delete the key from the server after the restore.

To test a dump without touching the live database, use another database name (for example `zabbix_restore`) in the `CREATE DATABASE`, `pg_restore` and `psql` commands and skip the first two lines; drop it afterwards.

To move to a new host, copy `.env` and `secrets/` from the old host (so that the passwords match the dump), run `sudo ./setup.sh` there to fix the permissions, start only `postgres-server` (`docker compose up -d postgres-server`), and follow the steps above.

## Security notes

What the stack does by default:

- The web UI is served over HTTPS only. Plain HTTP (container port 8080) is never published; it is used inside the stack for the health check and by the bootstrap job over the internal network. Server version headers are disabled.
- The web UI and the server port are published on `127.0.0.1` unless you change the bind addresses. PostgreSQL is never published.
- The `backend` network is internal (no internet access). PostgreSQL, the bootstrap job and the backup job are only on this network. `zabbix-server` and `zabbix-web` are also on the `frontend` network: the server needs internet access for Telegram and Slack webhooks and must be reachable for the host agent and remote agents, and the web UI must be published.
- Zabbix connects to PostgreSQL as the role `zabbix`, which owns the database but is not a superuser. The superuser `postgres` is only used to initialise the database and for maintenance (restore, extension updates).
- Secrets are files in a root-only directory, mounted read-only into the containers that need them. Scripts pass secrets through files and pipes, never as command-line arguments, and never print them.
- The default `Admin` password never works: the password from `secrets/zabbix_admin_password` is set when the schema is created, before the server and the web UI start. Guest access stays disabled.
- TimescaleDB telemetry is off.
- The host agent runs in active mode only and opens no port.
- Every container runs as a non-root user with all Linux capabilities dropped and `no-new-privileges`. All of them except the web UI have a read-only root filesystem with `tmpfs` for runtime files.
- Images are pinned by digest. The CI workflow runs shellcheck, validates the Compose file, checks that the Nord stylesheet matches the pinned web image, and scans the images (including the locally built backup image) with Trivy on every push and every week.

The Trivy scan fails on fixable HIGH and CRITICAL vulnerabilities. Findings that do not affect this stack are listed in `.trivyignore.yaml`, each with the reason and an expiry date (`expired_at`). After that date the scan fails again, and each entry must be checked again: delete it when a new image fixes the vulnerability, or extend it with a new reason. The Go command-line tools of the TimescaleDB image (`gosu`, `timescaledb-parallel-copy`, `timescaledb-tune`) are skipped, because they never handle network input.

Exceptions and why they exist:

- `zabbix-web` runs without a read-only root filesystem. Its entrypoint writes the nginx and PHP configuration at every start, for example `/etc/nginx/includes/access-log.conf`, and edits `/etc/nginx/nginx.conf` in place. With `read_only: true` it fails with `/etc/nginx/includes/access-log.conf: Read-only file system`. A `tmpfs` on those directories would hide the configuration files of the image.
- `zabbix-server` keeps the `NET_RAW` capability. ICMP checks use `fping`, which needs raw sockets; without the capability `fping` cannot run ("Operation not permitted").
- `postgres-server` and `zabbix-backup` use `tmpfs` for `/tmp` and the PostgreSQL socket directory; `zabbix-server` uses `tmpfs` for `/tmp` and its internal CA directory, which its entrypoint fills at start.

The host "Zabbix server" accepts active agent data without encryption. With the default `ZBX_SERVER_BIND=127.0.0.1`, only the Docker host itself can send it. With any other bind address, anyone who reaches the server port can send values as "Zabbix server". Keep the default bind, or use PSK encryption for the host agent: put `TLSConnect=psk`, `TLSPSKIdentity=<identity>` and `TLSPSKFile=<key file>` into a separate file in `/etc/zabbix/zabbix_agent2.d/` (`scripts/install-agent.sh` overwrites `zabbix-compose.conf`), restart the agent, and set the same identity and key in the web UI under Data collection > Hosts > Zabbix server > Encryption, with only PSK selected for connections from the host.

## Remote agents

To monitor other machines, install Zabbix agent 2 on them and add them as hosts in the web UI. `scripts/install-agent.sh` is for the Docker host only: it always writes `Hostname=Zabbix server` and the `ServerActive` address of this host. On other machines, install agent 2 by hand from the Zabbix repository and set `Hostname` and `ServerActive` for that machine. For active checks, the agents connect to the server port; see [Exposing the Zabbix server port](#exposing-the-zabbix-server-port). For passive checks, the server connects to the agents on port 10050.

A Docker Compose setup for a remote agent is available at [r4ven-me/zabbix-agent](https://github.com/r4ven-me/zabbix-agent).

## Testing

`scripts/e2e.sh` starts a complete stack in an isolated directory under `.audit/e2e/` with its own project name, ports and secrets, and checks setup, bootstrap (including notifications, the switch to the active agent template without leftover items of the old template, and its idempotency), TLS, the hardening settings, backups (including mode 0600) and a restore. It runs `scripts/install-agent.sh` in a Debian 13 container on the host network and checks that the agent's active checks arrive and that the agent listens on no port. It checks encrypted backups: the dump starts with the `age` header, restores with the private key as described in [Restore](#restore), and an invalid key or a failing `pg_dump` stops the backup without leaving a file. It removes everything at the end. It needs Docker and about 3 GB of free RAM:

```sh
scripts/e2e.sh
```

## Credits

This project is based on [r4ven-me/zabbix](https://github.com/r4ven-me/zabbix) by r4ven-me ([Telegram channel](https://t.me/r4ven_me/)), including the Nord theme. The remote agent setup is [r4ven-me/zabbix-agent](https://github.com/r4ven-me/zabbix-agent).
