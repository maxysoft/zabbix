#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=https://repo.zabbix.com/zabbix/8.0/release
CONF=/etc/zabbix/zabbix_agent2.d/zabbix-compose.conf

die() { echo "install-agent.sh: $*" >&2; exit 1; }
env_value() { sed -n "s/^$1=//p" .env | tail -n 1 | tr -d "\"'[:space:]"; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo scripts/install-agent.sh)"
[ -f .env ] || die ".env not found in $PWD: run sudo ./setup.sh first"

bind=$(env_value ZBX_SERVER_BIND)
port=$(env_value ZBX_SERVER_PORT)
[ "${bind:-0.0.0.0}" != 0.0.0.0 ] || bind=127.0.0.1
port=${port:-10051}
[[ $bind =~ ^[A-Za-z0-9.-]+$ && $port =~ ^[0-9]+$ ]] || die "cannot use ZBX_SERVER_BIND=$bind ZBX_SERVER_PORT=$port from .env (IPv6 addresses are not supported)"

mkdir -p "${CONF%/*}"
cat > "$CONF" <<EOF
Server=
ServerActive=$bind:$port
Hostname=Zabbix server
EOF

# shellcheck source=/dev/null
. /etc/os-release
if [[ $ID:${VERSION_ID:-} =~ ^(debian:1[23]|ubuntu:2[24]\.04)$ ]]; then
  command -v curl >/dev/null || die "curl not found: install it (apt install curl)"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/zabbix-release.deb" "$REPO/$ID/pool/main/z/zabbix-release/zabbix-release_latest_8.0+$ID${VERSION_ID}_all.deb"
  dpkg -i --force-confnew "$tmp/zabbix-release.deb"
  apt-get update
  apt-get install -y zabbix-agent2
elif [[ $ID:${VERSION_ID:-} =~ ^(rhel|rocky|almalinux|ol|centos):(9|10)(\.|$) ]]; then
  major=${BASH_REMATCH[2]}
  dnf install -y "$REPO/rhel/$major/noarch/zabbix-release-latest-8.0.el$major.noarch.rpm"
  dnf install -y zabbix-agent2
else
  die "unsupported OS ${PRETTY_NAME:-$ID}: install Zabbix agent 2 by hand as described in README.md"
fi
zabbix_agent2 -T -c /etc/zabbix/zabbix_agent2.conf

if [ -d /run/systemd/system ]; then
  systemctl enable --quiet zabbix-agent2
  systemctl restart zabbix-agent2
  echo "Zabbix agent 2 runs in active mode and reports to $bind:$port as host \"Zabbix server\"."
else
  echo "systemd is not running: start zabbix_agent2 yourself."
fi
