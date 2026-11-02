#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit lastpipe
cd "$(dirname "$0")/.."
REPO=$PWD

mkdir -p .audit/e2e
exec 9>.audit/docker.lock
flock -w 540 9 || { echo "e2e: .audit/docker.lock is busy" >&2; exit 1; }

RUN=run-$$
WD=$REPO/.audit/e2e/$RUN
WEB_PORT=18443
SERVER_PORT=20051
URL=https://localhost:$WEB_PORT
SERVER_IMAGE=$(sed -n 's/^ *image: *\(zabbix\/zabbix-server-pgsql:.*\)$/\1/p' compose.yaml | head -n 1)
WEB_IMAGE=$(sed -n 's/^ *image: *\(zabbix\/zabbix-web-nginx-pgsql:.*\)$/\1/p' compose.yaml | head -n 1)
AGENT_IMAGE=debian:13@sha256:913f6706df59a68922d1dd08f78c2476560a8d367897200a6005b00e5f67c2d5
AGENT=zbxe2e-agent-$$
AGENT2_IMAGE=zabbix/zabbix-agent2:alpine-trunk@sha256:af09cfa7ac5aa387dd32a811b8b2b0830ccc607f0671b624f876fe785f433193
CAL_AGENT=zbxe2e-agent2-$$
STATUS_CT=zbxe2e-status-$$
STATUS_PORT=18877
SSH_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINonpLIkSWxTnifdcUowSZe0rhqtTLhOnDI1ZsXLZL83 e2e@test'
export COMPOSE_PROJECT_NAME=zbxe2e
FAILS=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
check() {
  local what=$1
  shift
  if "$@"; then pass "$what"; else fail "$what"; fi
}
dc() { docker compose "$@"; }
as_root() { docker run --rm -u 0 -v "$WD:/w" -w /w --entrypoint sh "$SERVER_IMAGE" -c "$1"; }
psql_pg() { dc exec -T postgres-server psql -U postgres -d "${2:-zabbix}" -v ON_ERROR_STOP=1 -XAtq -c "$1"; }
in_api_container() { dc run --rm --no-deps -T --entrypoint bash zabbix-bootstrap -s 2>/dev/null; }
in_backup_container() { dc run --rm --no-deps -T --entrypoint sh zabbix-backup -s 2>/dev/null; }
count_results() {
  local out
  out=$(cat)
  echo "$out"
  FAILS=$((FAILS + $(grep -c '^FAIL' <<<"$out" || true)))
  grep -q '^PASS' <<<"$out" || fail "$1: produced no result"
}

teardown() {
  echo "--- teardown"
  docker rm -f "$AGENT" "$CAL_AGENT" "$STATUS_CT" >/dev/null 2>&1 || true
  if [ -d "$WD" ]; then
    (cd "$WD" && dc down -v --remove-orphans >/dev/null 2>&1) || true
    docker run --rm -u 0 -v "$REPO/.audit/e2e:/e" --entrypoint rm "$SERVER_IMAGE" -rf "/e/$RUN" || true
  fi
}
trap teardown EXIT
trap 'echo "e2e: aborted at line $LINENO" >&2' ERR

bootstrap_exit_code() {
  docker wait "$(dc ps -aq zabbix-bootstrap)"
}

template_ids() {
  in_api_container <<'EOF'
source /usr/local/bin/bootstrap.sh
admin_login_params | login
t=$(get_id template templateid '{"host": "calcolalinee by Zabbix agent active"}')
[ -n "$t" ]
jq -n --arg t "$t" '{templateids: [$t], output: ["itemid"]}' | api item.get | jq -c 'map(.itemid) | sort'
jq -n --arg t "$t" '{templateids: [$t], output: ["triggerid"]}' | api trigger.get | jq -c 'map(.triggerid) | sort'
EOF
}

cal_api() {
  {
    cat <<'EOF'
source /usr/local/bin/bootstrap.sh
set +e
admin_login_params | login
r() { if eval "$2" >/dev/null 2>&1; then echo "PASS: calcolalinee: $1"; else echo "FAIL: calcolalinee: $1"; fi; }
wait_for() { for _ in $(seq "$1"); do eval "$2" >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }
items() { echo '{"output": ["key_", "type", "state", "error", "lastclock", "lastvalue"], "host": "calcolalinee-e2e"}' | api item.get; }
v() { items | jq -r --arg k "calcolalinee.$1" '.[] | select(.key_ == $k) | .lastvalue'; }
problems() { echo '{"output": ["triggerid"], "host": "calcolalinee-e2e", "filter": {"value": 1}, "selectItems": ["key_"]}' | api trigger.get | jq -c '[.[].items[].key_ | ltrimstr("calcolalinee.")] | unique'; }
events() { echo '{"output": ["name"], "source": 0, "object": 0, "value": 1, "selectHosts": ["host"]}' | api event.get | jq -c '[.[] | select(.hosts[0].host == "calcolalinee-e2e") | .name]'; }
EOF
    cat
  } | in_api_container
}

wait_healthy() {
  local deadline=$((SECONDS + 600)) svc status all
  while :; do
    all=1
    for svc in postgres-server zabbix-server zabbix-web zabbix-backup; do
      status=$(docker inspect -f '{{.State.Health.Status}}' "$(dc ps -q "$svc")" 2>/dev/null || echo missing)
      [ "$status" = healthy ] || all=0
    done
    [ "$all" = 1 ] && return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 5
  done
}

echo "--- prepare $WD"
mkdir -p "$WD/secrets"
cp -r compose.yaml .env.example setup.sh config bootstrap scripts templates theme backup "$WD/"
cd "$WD"
sed -e "s/^ZBX_WEB_PORT=.*/ZBX_WEB_PORT=$WEB_PORT/" \
  -e "s/^ZBX_SERVER_PORT=.*/ZBX_SERVER_PORT=$SERVER_PORT/" \
  -e "s#^ZBX_PUBLIC_URL=.*#ZBX_PUBLIC_URL=$URL#" \
  -e "s/^TELEGRAM_CHAT_ID=.*/TELEGRAM_CHAT_ID=123456789/" \
  -e "s/^SLACK_CHANNELS=.*/SLACK_CHANNELS=prod:#p,test:#t/" \
  .env.example > .env
printf '123456:dummy-telegram-token' > secrets/telegram_bot_token
printf 'xoxb-dummy-slack-token' > secrets/slack_bot_token

echo "--- setup.sh (as root in a throwaway container)"
docker run --rm -u 0 -v "$WD:/w" -w /w --entrypoint bash "$SERVER_IMAGE" ./setup.sh | sed 's/^/  /'
sums1=$(as_root 'find secrets -type f -exec sha256sum {} +')
docker run --rm -u 0 -v "$WD:/w" -w /w --entrypoint bash "$SERVER_IMAGE" ./setup.sh >/dev/null
check "setup.sh is idempotent (secrets unchanged on second run)" [ "$sums1" = "$(as_root 'find secrets -type f -exec sha256sum {} +')" ]
check "secret files are root-only on the host" [ "$(as_root 'stat -c %a:%U secrets')" = "700:root" ]

echo "--- docker compose up"
dc up -d --build 2>&1 | tail -n 3
check "stack healthy (postgres, server, web, backup)" wait_healthy
check "Admin password set at schema creation by pgcrypto, so Admin/zabbix never worked" [ "$(psql_pg "SELECT left(passwd, 7) FROM users WHERE username = 'Admin'")" = "\$2a\$10\$" ]
check "zabbix-bootstrap exited 0 on first up" [ "$(bootstrap_exit_code)" = 0 ]
dc logs --no-log-prefix zabbix-bootstrap | sed 's/^/  /'
tids=$(template_ids || true)
check "bootstrap imported the template calcolalinee by Zabbix agent active" [ -n "$tids" ]

started=$(docker inspect -f '{{.State.StartedAt}}' "$(dc ps -aq zabbix-bootstrap)")
dc up -d 2>&1 | tail -n 1
check "zabbix-bootstrap exited 0 on second up" [ "$(bootstrap_exit_code)" = 0 ]
check "second up re-ran zabbix-bootstrap" [ "$started" != "$(docker inspect -f '{{.State.StartedAt}}' "$(dc ps -aq zabbix-bootstrap)")" ]
check "second bootstrap run kept the template's items and triggers (same ids)" [ "$tids" = "$(template_ids || true)" ]

echo "--- API checks"
in_api_container <<EOF | count_results "API checks"
source /usr/local/bin/bootstrap.sh
set +e
r() { if eval "\$2" >/dev/null 2>&1; then echo "PASS: \$1"; else echo "FAIL: \$1"; fi; }
r "Admin/zabbix is rejected" '! echo "{\"username\": \"Admin\", \"password\": \"zabbix\"}" | api user.login'
r "API login with the generated Admin password" 'admin_login_params | login'
r "frontend URL is $URL" '[ "\$(echo "{\"output\": [\"url\"]}" | api settings.get | jq -r .url)" = "$URL" ]'
r "guest access disabled" 'echo "{\"filter\": {\"username\": \"guest\"}, \"selectUsrgrps\": [\"users_status\"]}" | api user.get | jq -e "any(.[0].usrgrps[]; .users_status == \"1\")"'
mt() { echo "{\"output\": \"extend\", \"filter\": {\"name\": \"\$1\"}}" | api mediatype.get | jq -c '.[0]'; }
r "Telegram media type enabled with token" 'mt Telegram | jq -e ".status == \"0\" and any(.parameters[]; .name == \"api_token\" and .value == \"123456:dummy-telegram-token\")"'
r "Admin has Telegram media to 123456789" 'echo "{\"filter\": {\"username\": \"Admin\"}, \"selectMedias\": [\"mediatypeid\", \"sendto\", \"active\"]}" | api user.get | jq -e --arg mt "\$(mt Telegram | jq -r .mediatypeid)" "any(.[0].medias[]; .mediatypeid == \\\$mt and .sendto == \"123456789\" and .active == \"0\")"'
r "default action Report problems to Zabbix administrators enabled" 'echo "{\"filter\": {\"name\": \"Report problems to Zabbix administrators\"}}" | api action.get | jq -e ".[0].status == \"0\""'
r "Slack media type enabled with token and zabbix_url" 'mt Slack | jq -e ".status == \"0\" and any(.parameters[]; .name == \"bot_token\" and .value == \"xoxb-dummy-slack-token\") and any(.parameters[]; .name == \"zabbix_url\" and .value == \"$URL\")"'
r "role Slack notifications: Super admin type, API off" 'echo "{\"filter\": {\"name\": \"Slack notifications\"}, \"selectRules\": [\"api.access\"]}" | api role.get | jq -e ".[0].type == \"3\" and .[0].rules[\"api.access\"] == \"0\""'
r "group Slack notifications has no frontend access" 'echo "{\"filter\": {\"name\": \"Slack notifications\"}, \"output\": [\"gui_access\"]}" | api usergroup.get | jq -e ".[0].gui_access == \"3\""'
for e in prod:#p test:#t; do
  env=\${e%%:*} ch=\${e#*:}
  r "user slack-\$env with Slack media \$ch" 'echo "{\"filter\": {\"username\": \"slack-\$env\"}, \"selectMedias\": [\"sendto\"]}" | api user.get | jq -e --arg ch "\$ch" ".[0].medias | length == 1 and .[0].sendto == \\\$ch"'
  r "action Slack: env=\$env enabled with tag condition env=\$env" 'echo "{\"filter\": {\"name\": \"Slack: env=\$env\"}, \"selectFilter\": \"extend\"}" | api action.get | jq -e --arg env "\$env" ".[0].status == \"0\" and .[0].filter.conditions[0].conditiontype == \"26\" and .[0].filter.conditions[0].value == \\\$env and .[0].filter.conditions[0].value2 == \"env\""'
done
r "Admin theme can be set to nord-theme" 'echo "{\"userid\": \"1\", \"theme\": \"nord-theme\"}" | api user.update'
EOF

echo "--- calcolalinee template (fake status page, agent 2 container in active mode with PSK)"
mkdir fake
cat > fake/nginx.conf <<EOF
pid /tmp/nginx.pid;
error_log stderr;
events {}
http {
  access_log off;
  gzip on;
  gzip_types application/json;
  gzip_min_length 0;
  client_body_temp_path /tmp/body;
  proxy_temp_path /tmp/proxy;
  fastcgi_temp_path /tmp/fastcgi;
  uwsgi_temp_path /tmp/uwsgi;
  scgi_temp_path /tmp/scgi;
  server {
    listen 127.0.0.1:$STATUS_PORT;
    root /w;
    default_type application/json;
    error_page 503 /status.json;
    location = /api/status {
      if (-f /w/down) { return 503; }
      alias /w/status.json;
    }
  }
}
EOF
cat > fake/healthy.json <<'EOF'
{"version": "2026.10.1", "uptime_s": 86400, "valhalla": {"ok": true, "version": "3.5.1"},
 "files": {"stops": {"path": "/data/stops.csv", "present": true, "required": true, "bytes": 2048},
           "requests": {"path": "/data/requests.csv", "present": true, "required": true, "bytes": 4096},
           "zoning": {"path": "/data/zoning.geojson", "present": false, "required": false, "bytes": 0}},
 "settings": {"backend": "mysql", "loaded": true, "error": null, "problems": []},
 "database": {"configured": true, "ok": true, "connection": "ok", "tables": {"jobs": "ok", "settings": "ok"}},
 "auth": {"problem": null},
 "stats": {"held_days": [], "since": null, "last_error": null, "error_at": null, "lost_days": []},
 "jobs": {"configured": true, "ok": true, "error": null, "queued": 1, "running": 1, "oldest_active_s": 300,
          "awaiting_import": 2, "oldest_awaiting_import_s": 60, "failed_24h": 1}}
EOF
cat > fake/broken.json <<'EOF'
{"version": "2026.10.2", "uptime_s": 20, "valhalla": {"ok": false, "error": "Read timed out. (read timeout=2)"},
 "files": {"stops": {"path": "/data/stops.csv", "present": false, "required": true, "bytes": 0},
           "requests": {"path": "/data/requests.csv", "present": true, "required": true, "bytes": 4096},
           "zoning": {"path": "/data/zoning.geojson", "present": false, "required": false, "bytes": 0}},
 "settings": {"backend": "mysql", "loaded": true, "error": null, "problems": []},
 "database": {"configured": true, "ok": false, "connection": "unreachable", "tables": {}},
 "auth": {"problem": "no_users"},
 "stats": {"held_days": ["2026-10-16", "2026-10-17"], "since": "2026-10-16T03:00:00", "last_error": "OSError 28",
           "error_at": "2026-10-17T03:00:00", "lost_days": ["2026-10-01"]},
 "jobs": {"configured": true, "ok": true, "error": null, "queued": 3, "running": 1, "oldest_active_s": 8000,
          "awaiting_import": 5, "oldest_awaiting_import_s": 4000, "failed_24h": 3}}
EOF
cp fake/healthy.json fake/status.json
sed 's/"uptime_s": 86400/"uptime_s": 30/' fake/healthy.json > fake/restarted.json
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > fake/psk
cat > fake/agent.conf <<EOF
Server=
ServerActive=127.0.0.1:$SERVER_PORT
Hostname=calcolalinee-e2e
RefreshActiveChecks=5
LogType=console
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=calcolalinee-e2e
TLSPSKFile=/w/psk
AllowKey=web.page.get[http://127.0.0.1:$STATUS_PORT/api/status]
DenyKey=web.page.get[*]
EOF
chmod -R a+rX fake
docker run -d --name "$STATUS_CT" --network host -v "$WD/fake:/w:ro" \
  --health-cmd "curl -fsS -o /dev/null http://127.0.0.1:$STATUS_PORT/api/status" --health-interval 10s --health-retries 3 \
  --entrypoint nginx "$WEB_IMAGE" -e stderr -c /w/nginx.conf -g 'daemon off;' >/dev/null
in_api_container <<EOF | count_results "calcolalinee host"
source /usr/local/bin/bootstrap.sh
admin_login_params | login
jq -n --arg t "\$(get_id template templateid '{"host": "calcolalinee by Zabbix agent active"}')" \
  --arg g "\$(get_id hostgroup groupid '{"name": "Linux servers"}')" '{
    host: "calcolalinee-e2e", groups: [{groupid: \$g}], templates: [{templateid: \$t}], tags: [{tag: "env", value: "e2e"}],
    tls_connect: 2, tls_accept: 2, tls_psk_identity: "calcolalinee-e2e", tls_psk: "$(cat fake/psk)",
    macros: [{macro: "{\$CALCOLALINEE.STATUS.URL}", value: "http://127.0.0.1:$STATUS_PORT/api/status"},
      {macro: "{\$CALCOLALINEE.INTERVAL}", value: "10s"},
      {macro: "{\$CALCOLALINEE.VALHALLA.MAXDOWN}", value: "25s"}]}' | api host.create >/dev/null &&
  echo "PASS: host calcolalinee-e2e created with the template, tag env=e2e and PSK" ||
  echo "FAIL: host calcolalinee-e2e created with the template, tag env=e2e and PSK"
EOF
docker run -d --name "$CAL_AGENT" --network host -v "$WD/fake:/w:ro" \
  --entrypoint /usr/sbin/zabbix_agent2 "$AGENT2_IMAGE" -c /w/agent.conf >/dev/null
fails_before=$FAILS
cal_api <<'EOF' | count_results "calcolalinee healthy status"
filled() { items | jq -e '[.[] | select(.type == "18")] | length > 0 and all(.[]; .state == "0" and .lastclock != "0")'; }
wait_for 36 filled
r "every dependent item has a value" filled
r "HTTP status code 200" '[ "$(v http.code)" = 200 ]'
r "jobs block read (2 results awaiting import)" '[ "$(v jobs.awaiting)" = 2 ]'
r "no problem while the status is healthy" '[ "$(problems)" = "[]" ]'
items | jq -r '.[] | select(.state != "0") | "  unsupported: \(.key_): \(.error)"' || true
EOF
check "calcolalinee: fake status page is gzip-compressed" bash -c \
  "docker exec '$STATUS_CT' curl -sD - -o /dev/null -H 'Accept-Encoding: gzip' http://127.0.0.1:$STATUS_PORT/api/status | grep -qi '^content-encoding: gzip'"
cp fake/restarted.json fake/status.json
cal_api <<'EOF' | count_results "calcolalinee restart"
wait_for 12 'events | jq -e "index(\"calcolalinee: service restarted\")"'
r "service restarted raised when the uptime drops and the version stays the same" 'events | jq -e "index(\"calcolalinee: service restarted\")"'
EOF
cp fake/broken.json fake/status.json
touch fake/down
cal_api <<'EOF' | count_results "calcolalinee broken status"
expected='["auth.problem","db.ok","files.missing","jobs.active.age","jobs.failed","stats.held","stats.lost","valhalla.ok"]'
wait_for 36 'problems | jq -e --argjson e "$expected" "(\$e - .) == []"'
for k in $(jq -r '.[]' <<<"$expected"); do
  r "problem raised by the trigger on $k" "problems | jq -e 'index(\"$k\")'"
done
r "HTTP 503 with body reaches the agent (code 503 while database.ok is false)" '[ "$(v http.code)" = 503 ]'
r "version changed raised for 2026.10.2 and resolved on the next poll" 'events | jq -e "index(\"calcolalinee: version changed to 2026.10.2\")" && ! problems | jq -e "index(\"version\")"'
r "no service restarted on a deploy (lower uptime with a new version)" 'events | jq -e "map(select(. == \"calcolalinee: service restarted\")) | length == 1"'
r "no other problem (HTTP 503 is covered by the database problem, the unimported result needs 5 minutes)" '[ "$(problems)" = "$expected" ]'
echo "  problems: $(problems)"
EOF
[ "$FAILS" = "$fails_before" ] || docker logs --tail 20 "$CAL_AGENT" 2>&1 | sed 's/^/  agent: /'

echo "--- host agent (scripts/install-agent.sh in Debian 13 on the host network)"
docker run -d --name "$AGENT" --network host -v "$WD:/w:ro" "$AGENT_IMAGE" sleep infinity >/dev/null
check "install-agent.sh installs and configures agent 2" docker exec "$AGENT" bash -c \
  'apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null && /w/scripts/install-agent.sh >/tmp/install.log 2>&1 || { tail -n 20 /tmp/install.log; exit 1; }'
docker exec "$AGENT" bash -c 'mkdir -p /run/zabbix && chown zabbix: /run/zabbix'
docker exec -d -u zabbix "$AGENT" zabbix_agent2 -c /etc/zabbix/zabbix_agent2.conf
in_api_container <<'EOF' | count_results "host agent API checks"
source /usr/local/bin/bootstrap.sh
set +e
admin_login_params | login
r() { if eval "$2" >/dev/null 2>&1; then echo "PASS: $1"; else echo "FAIL: $1"; fi; }
templates() { echo '{"filter": {"host": "Zabbix server"}, "selectParentTemplates": ["host"]}' | api host.get | jq -c '[.[0].parentTemplates[].host]'; }
items() { echo '{"output": ["key_", "type"], "filter": {"host": "Zabbix server"}}' | api item.get; }
active() { echo '{"output": ["active_available"], "filter": {"host": "Zabbix server"}}' | api host.get | jq -e '.[0].active_available == "1"'; }
r "Zabbix server uses Linux by Zabbix agent active, not Linux by Zabbix agent" 'templates | jq -e "index(\"Linux by Zabbix agent active\") and (index(\"Linux by Zabbix agent\") | not)"'
r "Zabbix server items: no duplicate keys, active agent items, no passive agent items" 'items | jq -e "(map(.key_) | length) == (map(.key_) | unique | length) and any(.[]; .type == \"7\") and all(.[]; .type != \"0\")"'
r "Zabbix server: no leftover item zabbix[host,agent,available]" 'items | jq -e "all(.[]; .key_ != \"zabbix[host,agent,available]\")"'
r "Zabbix server: no leftover trigger Zabbix agent is not available" 'echo "{\"output\": [\"templateid\"], \"host\": \"Zabbix server\", \"search\": {\"description\": \"Zabbix agent is not available\"}}" | api trigger.get | jq -e "length > 0 and all(.[]; .templateid != \"0\")"'
for _ in $(seq 36); do active >/dev/null 2>&1 && break; sleep 5; done
r "active agent available for Zabbix server" active
EOF
agent_listens_nowhere() {
  docker exec -i -u zabbix "$AGENT" bash -s <<'EOF'
pid=$(cat /run/zabbix/zabbix_agent2.pid) && [ -d "/proc/$pid" ] || exit 1
socks=$(find "/proc/$pid/fd" -lname 'socket:*' -printf '%l\n' | tr -dc '0-9\n')
! awk '$4 == "0A" {print $10}' /proc/net/tcp /proc/net/tcp6 | grep -qxF -f <(printf '%s\n' $socks)
EOF
}
check "agent process runs and listens on no TCP port (passive checks off)" agent_listens_nowhere

echo "--- DB, network and TLS checks"
check "DB role zabbix is not a superuser" [ "$(psql_pg "SELECT rolsuper FROM pg_roles WHERE rolname = 'zabbix'")" = f ]
check "Nord graph theme row exists" [ "$(psql_pg "SELECT count(*) FROM graph_theme WHERE theme = 'nord-theme'")" = 1 ]
secrets_not_logged() {
  local f
  for f in zabbix_admin_password zabbix_db_password; do
    ! dc logs zabbix-server postgres-server 2>&1 | grep -qF "$(as_root "cat secrets/$f")" || return 1
  done
}
check "admin and DB passwords not in zabbix-server or postgres-server logs" secrets_not_logged
check "TimescaleDB hypertables exist for all 7 history tables" [ "$(psql_pg "SELECT count(*) FROM timescaledb_information.hypertables WHERE hypertable_name ~ '^history'")" = 7 ]
check "fping postgres-server works inside zabbix-server" dc exec -T zabbix-server fping postgres-server
check "HTTPS port $WEB_PORT serves the login page" bash -c "docker run --rm --network host --entrypoint curl '$WEB_IMAGE' -sk https://127.0.0.1:$WEB_PORT/ | grep -q 'Sign in'"
check "HTTP 8080 is not published on the host" [ "$(docker inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{$p}} {{end}}' "$(dc ps -q zabbix-web)")" = "8443/tcp " ]
check "zabbix-server trapper port published only on 127.0.0.1" [ "$(docker inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{$p}}={{(index $b 0).HostIp}} {{end}}' "$(dc ps -q zabbix-server)")" = "10051/tcp=127.0.0.1 " ]
in_api_container <<'EOF' | count_results "feature flags"
source /usr/local/bin/bootstrap.sh
admin_login_params | login
echo '{"output": "extend"}' | api authentication.get | jq -e 'has("authentication_type") and (has("http_login_form") | not)' >/dev/null &&
  echo "PASS: ZBX_HTTP_AUTH_ENABLED=false reaches the frontend" || echo "FAIL: ZBX_HTTP_AUTH_ENABLED=false reaches the frontend"
EOF

echo "--- hardening"
non_root() { [ -n "$1" ] && [ "${1%%:*}" != root ] && [ "${1%%:*}" != 0 ]; }
for svc in postgres-server zabbix-server zabbix-web zabbix-bootstrap zabbix-backup; do
  id=$(dc ps -aq "$svc")
  user=$(docker inspect -f '{{.Config.User}}' "$id")
  check "$svc: runs as non-root user ($user)" non_root "$user"
  check "$svc: cap_drop ALL" [ "$(docker inspect -f '{{json .HostConfig.CapDrop}}' "$id")" = '["ALL"]' ]
  check "$svc: no-new-privileges" [ "$(docker inspect -f '{{json .HostConfig.SecurityOpt}}' "$id")" = '["no-new-privileges:true"]' ]
  if [ "$svc" = zabbix-web ]; then
    check "$svc: read-only root disabled (documented exception)" [ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$id")" = false ]
  else
    check "$svc: read-only root filesystem" [ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$id")" = true ]
  fi
done
capadd=$(docker inspect -f '{{json .HostConfig.CapAdd}}' "$(dc ps -q zabbix-server)")
check "zabbix-server: only NET_RAW added" [ "${capadd/CAP_/}" = '["NET_RAW"]' ]

echo "--- Slack env removed from SLACK_CHANNELS"
sed -i 's/^SLACK_CHANNELS=.*/SLACK_CHANNELS=prod:#p/' .env
dc up -d 2>&1 | tail -n 1
check "zabbix-bootstrap exited 0 after SLACK_CHANNELS change" [ "$(bootstrap_exit_code)" = 0 ]
in_api_container <<'EOF' | count_results "Slack env removal"
source /usr/local/bin/bootstrap.sh
admin_login_params | login
st() { jq -n --arg n "Slack: env=$1" '{filter: {name: $n}}' | api action.get | jq -r '.[0].status'; }
[ "$(st test)" = 1 ] && echo "PASS: action Slack: env=test disabled" || echo "FAIL: action Slack: env=test disabled"
[ "$(st prod)" = 0 ] && echo "PASS: action Slack: env=prod still enabled" || echo "FAIL: action Slack: env=prod still enabled"
EOF

echo "--- SLACK_CHANNELS emptied"
sed -i 's/^SLACK_CHANNELS=.*/SLACK_CHANNELS=/' .env
dc up -d 2>&1 | tail -n 1
check "zabbix-bootstrap exited 0 with empty SLACK_CHANNELS" [ "$(bootstrap_exit_code)" = 0 ]
all_slack_disabled() {
  in_api_container <<'EOF'
source /usr/local/bin/bootstrap.sh
admin_login_params | login
jq -n '{output: ["status"], search: {name: "Slack: env="}, startSearch: true}' | api action.get |
  jq -e 'length == 2 and all(.[]; .status == "1")' >/dev/null
EOF
}
check "all Slack env actions disabled" all_slack_disabled

echo "--- interrupted first start left the default Admin password"
psql_pg "UPDATE users SET passwd = '\$2y\$10\$92nDno4n0Zm7Ej7Jfsz8WukBfgSS/U0QkIuu8WkJPihXBb2A1UrEK' WHERE username = 'Admin'" >/dev/null
dc up -d 2>&1 | tail -n 1
check "zabbix-bootstrap exited 0 after finding the default Admin password" [ "$(bootstrap_exit_code)" = 0 ]
check "bootstrap replaced the default Admin password" [ "$(psql_pg "SELECT passwd = '\$2y\$10\$92nDno4n0Zm7Ej7Jfsz8WukBfgSS/U0QkIuu8WkJPihXBb2A1UrEK' FROM users WHERE username = 'Admin'")" = f ]

echo "--- backups"
check "a history chunk can be compressed by the non-superuser owner" bash -c \
  "docker compose exec -T postgres-server psql -U zabbix -d zabbix -v ON_ERROR_STOP=1 -XAtq -c \"SELECT compress_chunk(c, true) FROM show_chunks('history_uint') c\" >/dev/null"
check "on-demand full backup" dc run --rm -T zabbix-backup --once
check "on-demand backup with BACKUP_EXCLUDE_HISTORY=true" dc run --rm -T -e BACKUP_EXCLUDE_HISTORY=true zabbix-backup --once
in_backup_container <<'EOF' | count_results "backup contents"
PGPASSWORD=$(cat /run/secrets/zabbix_db_password); export PGPASSWORD
r() { if eval "$2" >/dev/null 2>&1; then echo "PASS: $1"; else echo "FAIL: $1"; fi; }
full=$(ls /backups/zabbix-*[0-9].dump | tail -n 1)
noh=$(ls /backups/zabbix-*-nohistory.dump | tail -n 1)
prefixes=$(psql -XAtc "SELECT string_agg(associated_table_prefix, '|') FROM _timescaledb_catalog.hypertable WHERE table_name ~ '^(history|trends)'")
r "plain dumps have mode 600" '[ "$(stat -c %a "$full" "$noh" | sort -u)" = 600 ]'
r "full backup non-empty and listed by pg_restore -l" '[ -s "$full" ] && pg_restore -l "$full" | grep -q "TABLE DATA public items "'
r "full backup holds history/trends chunk data" 'pg_restore -l "$full" | grep -qE "TABLE DATA _timescaledb_internal ($prefixes)_[0-9]+_chunk "'
r "full backup holds compressed history chunk data" 'pg_restore -l "$full" | grep -qE "TABLE DATA _timescaledb_internal ($prefixes)_[0-9]+_chunk_compressed "'
r "no-history backup keeps the schema" 'pg_restore -l "$noh" | grep -q "TABLE public history " && pg_restore -l "$noh" | grep -q "TABLE DATA public items "'
r "no-history backup has no history/trends data (incl. compressed chunks)" '! pg_restore -l "$noh" | grep -qE "TABLE DATA (public (history|trends)|_timescaledb_internal ($prefixes)_)"'
r "no-history backup keeps other hypertable data (auditlog)" 'pg_restore -l "$noh" | grep -q "TABLE DATA _timescaledb_internal _hyper_"'
EOF

echo "--- restore test (README procedure, into scratch DB zabbix_restore)"
full=$(in_backup_container <<<'ls /backups/zabbix-*[0-9].dump | tail -n 1')
restore() {
  psql_pg "CREATE DATABASE zabbix_restore OWNER zabbix" postgres &&
    psql_pg "SELECT timescaledb_pre_restore()" zabbix_restore >/dev/null &&
    "$@" | dc exec -T postgres-server pg_restore -U postgres -d zabbix_restore --exit-on-error &&
    psql_pg "SELECT timescaledb_post_restore()" zabbix_restore >/dev/null
}
same_items_and_hosts() {
  local q="SELECT itemid || ' ' || flags || ' ' || key_ FROM items UNION ALL SELECT 'host ' || host FROM hosts ORDER BY 1"
  diff <(psql_pg "$q" zabbix_restore) <(psql_pg "$q") | head -n 5
}
check "restore of $(basename "$full") succeeds" restore as_root "cat /w/backups/$(basename "$full")"
check "restored DB has the same items and hosts" same_items_and_hosts
check "restored DB has history data and hypertables" [ "$(psql_pg "SELECT (SELECT count(*) FROM history_uint) > 0 AND (SELECT count(*) FROM timescaledb_information.hypertables) = 10" zabbix_restore)" = t ]
psql_pg "DROP DATABASE zabbix_restore" postgres

echo "--- encrypted backups"
dc run --rm -T --no-deps --entrypoint age-keygen zabbix-backup > age-key.txt 2>/dev/null
pub=$(sed -n 's/^# public key: //p' age-key.txt)
in_backup_container <<<'touch -d "2000-01-01 00:00:00" /backups/zabbix-20000101-000000.dump.age'
check "on-demand encrypted no-history backup (age key + SSH key, padded and empty entries)" \
  dc run --rm -T -e BACKUP_EXCLUDE_HISTORY=true -e BACKUP_AGE_RECIPIENTS=" $pub ,, $SSH_KEY , " zabbix-backup --once
in_backup_container <<'EOF' | count_results "encrypted backup files"
r() { if eval "$2" >/dev/null 2>&1; then echo "PASS: $1"; else echo "FAIL: $1"; fi; }
enc=$(ls /backups/zabbix-*-nohistory.dump.age | tail -n 1)
r "encrypted dump starts with the age header" '[ "$(head -c 21 "$enc")" = age-encryption.org/v1 ]'
r "encrypted dump does not start with PGDMP" '[ "$(head -c 5 "$enc")" != PGDMP ]'
r "encrypted dump has mode 600" '[ "$(stat -c %a "$enc")" = 600 ]'
r "no .partial file left" '! ls /backups/*.partial'
r "prune deleted the old .dump.age" '[ ! -e /backups/zabbix-20000101-000000.dump.age ]'
EOF
enc=$(in_backup_container <<<'ls /backups/zabbix-*-nohistory.dump.age | tail -n 1')
decrypt() { dc run --rm -T --no-deps --entrypoint age zabbix-backup -d -i - "$1" < age-key.txt; }
check "restore of encrypted $(basename "$enc") succeeds (README procedure: age in the backup image, key on stdin)" restore decrypt "$enc"
check "DB restored from the encrypted dump has the same items and hosts" same_items_and_hosts
psql_pg "DROP DATABASE zabbix_restore" postgres
invalid_recipient_rejected() {
  local out
  ! out=$(dc run --rm -T --no-deps -e BACKUP_AGE_RECIPIENTS="$pub,age1bogus" zabbix-backup --once 2>&1) &&
    grep -q 'BACKUP_AGE_RECIPIENTS must be' <<<"$out"
}
check "invalid BACKUP_AGE_RECIPIENTS stops the container with a clear message" invalid_recipient_rejected
failed_dump_leaves_nothing() {
  local before
  before=$(in_backup_container <<<'ls -a /backups')
  ! dc run --rm -T --no-deps -e PGHOST=nonexistent.invalid -e BACKUP_AGE_RECIPIENTS="$pub" zabbix-backup --once >/dev/null 2>&1 &&
    [ "$before" = "$(in_backup_container <<<'ls -a /backups')" ]
}
check "failing pg_dump with encryption fails the backup and leaves no file" failed_dump_leaves_nothing
check "backups/ still belongs to uid 70 with mode 0700" [ "$(as_root 'stat -c %u:%a backups')" = 70:700 ]

echo "--- calcolalinee: unimported result, at least 5 minutes after the broken status"
cal_api <<'EOF' | count_results "calcolalinee unimported result"
wait_for 72 'problems | jq -e "index(\"jobs.awaiting.age\")"'
r "problem raised by the trigger on jobs.awaiting.age once the age stays above the limit for 5 minutes" 'problems | jq -e "index(\"jobs.awaiting.age\")"'
EOF

echo "--- result"
if [ "$FAILS" -eq 0 ]; then
  echo "E2E PASSED"
else
  echo "E2E FAILED: $FAILS check(s) failed"
  dc ps -a --format '{{.Service}} {{.Status}}'
  exit 1
fi
