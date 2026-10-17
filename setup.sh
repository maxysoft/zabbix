#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

PG_UID=70

die() { echo "setup.sh: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo ./setup.sh): secrets/ must be a root-only directory and backups/ must belong to the postgres container user (uid $PG_UID)."

if [ ! -f .env ]; then
  cp .env.example .env
  chmod 0644 .env
  echo "Created .env from .env.example."
fi

umask 077
mkdir -p secrets/tls backups

for name in postgres_password zabbix_db_password zabbix_admin_password; do
  if [ ! -s "secrets/$name" ]; then
    pw=$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | cut -c1-40)
    [ "${#pw}" -eq 40 ] || die "could not generate a random password"
    printf '%s' "$pw" > "secrets/$name"
    echo "Generated secrets/$name."
  fi
done

for name in telegram_bot_token slack_bot_token; do
  [ -e "secrets/$name" ] || : > "secrets/$name"
done

if [ ! -s secrets/tls/ssl.crt ] && [ ! -s secrets/tls/ssl.key ]; then
  command -v openssl >/dev/null || die "openssl not found: install it (e.g. apt install openssl)"
  url=$(sed -n 's/^ZBX_PUBLIC_URL=//p' .env | tail -n 1 | tr -d "\"'")
  host=${url#*://}
  host=${host%%/*}
  host=${host%:*}
  [[ $host =~ ^[A-Za-z0-9.-]+$ ]] || die "cannot read a host name from ZBX_PUBLIC_URL in .env"
  if [[ $host =~ ^[0-9.]+$ ]]; then san="IP:$host"; else san="DNS:$host"; fi
  [ "$host" = localhost ] || san="$san,DNS:localhost"
  (cd secrets/tls && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -days 825 -subj "/CN=$host" -addext "subjectAltName=$san" \
    -keyout ssl.key -out ssl.crt)
  echo "Created a self-signed TLS certificate for $host in secrets/tls/."
elif [ ! -s secrets/tls/ssl.crt ] || [ ! -s secrets/tls/ssl.key ]; then
  die "only one of secrets/tls/ssl.crt and secrets/tls/ssl.key exists: add the missing file, or delete both to create a new self-signed certificate."
fi

chown -R root:root secrets
chmod 0700 secrets
chmod 0755 secrets/tls
find secrets -type f -exec chmod 0444 {} +
chown "$PG_UID:$PG_UID" backups
chmod 0700 backups

cat <<EOF

Setup complete. Next steps:
  1. Review .env (ZBX_PUBLIC_URL, TZ, bind addresses, notification settings).
  2. Optional: write bot tokens into secrets/telegram_bot_token and secrets/slack_bot_token,
     then run sudo ./setup.sh again to fix their permissions.
  3. Start the stack: docker compose up -d
  4. Install the agent on this host: sudo scripts/install-agent.sh
The web UI user is Admin. Its password is in secrets/zabbix_admin_password (sudo cat secrets/zabbix_admin_password).
EOF
