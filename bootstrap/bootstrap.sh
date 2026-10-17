#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

API=http://zabbix-web:8080/api_jsonrpc.php
API_TIMEOUT=600 # seconds
ADMIN_PW_FILE=/run/secrets/zabbix_admin_password
TELEGRAM_TOKEN_FILE=/run/secrets/telegram_bot_token
SLACK_TOKEN_FILE=/run/secrets/slack_bot_token
SLACK_ACTION_PREFIX="Slack: env="
SLACK_ROLE="Slack notifications"
SLACK_GROUP="Slack notifications"
HDR=$(mktemp)

log() { echo "bootstrap: $*"; }
die() { echo "bootstrap: ERROR: $*" >&2; exit 1; }
has_text() { grep -q '[^[:space:]]' "$1" 2>/dev/null; }

api() {
  local resp
  resp=$(jq -c --arg m "$1" '{jsonrpc: "2.0", method: $m, params: ., id: 1}' |
    curl -sS -m 60 -H 'Content-Type: application/json-rpc' -H @"$HDR" -d @- "$API") || return 1
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$resp"; then
    echo "bootstrap: $1: unexpected non-JSON response from $API" >&2
    return 1
  fi
  if jq -e 'has("error")' >/dev/null <<<"$resp"; then
    echo "bootstrap: $1 failed: $(jq -r '.error.data // .error.message' <<<"$resp")" >&2
    return 1
  fi
  jq -c .result <<<"$resp"
}

login() {
  local token
  : > "$HDR"
  token=$(api user.login) || return 1
  printf 'Authorization: Bearer %s\n' "$(jq -r . <<<"$token")" > "$HDR"
}

admin_login_params() {
  jq -n --rawfile pw "$ADMIN_PW_FILE" '{username: "Admin", password: ($pw | sub("[\r\n]+$"; ""))}'
}

get_id() {
  jq -n --arg id "$2" --argjson f "$3" '{output: [$id], filter: $f}' | api "$1.get" | jq -r --arg id "$2" '.[0][$id] // empty'
}

logout() {
  [ -s "$HDR" ] && echo '[]' | api user.logout >/dev/null 2>&1
  rm -f "$HDR"
}

wait_for_api() {
  local deadline=$((SECONDS + API_TIMEOUT))
  until echo '[]' | api apiinfo.version >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || die "the Zabbix API at $API did not answer within $API_TIMEOUT s"
    sleep 5
  done
}

login_admin() {
  local err uid
  err=$(admin_login_params | login 2>&1) && return 0
  if [[ $err == *"Incorrect user name or password"* ]] &&
    echo '{"username": "Admin", "password": "zabbix"}' | login 2>/dev/null; then
    log "Admin still had the default password (interrupted first start): setting it from secrets/zabbix_admin_password"
    uid=$(get_id user userid '{"username": "Admin"}')
    jq -n --arg u "$uid" --rawfile pw "$ADMIN_PW_FILE" \
      '{userid: $u, current_passwd: "zabbix", passwd: ($pw | sub("[\r\n]+$"; ""))}' | api user.update >/dev/null
    admin_login_params | login || die "the Admin password was set from secrets/zabbix_admin_password but logging in with it failed"
    return 0
  fi
  err=${err#bootstrap: }
  die "cannot log in as Admin: ${err%.}. secrets/zabbix_admin_password must contain the current Admin password of the web UI; if you changed the password in the UI, write the new one into the file."
}

configure_frontend_url() {
  jq -n --arg url "${ZBX_PUBLIC_URL%/}" '{url: $url}' | api settings.update >/dev/null
  log "frontend URL set to ${ZBX_PUBLIC_URL%/}"
}

use_active_agent_template() {
  local host passive active keys ids
  host=$(echo '{"output": ["hostid"], "filter": {"host": "Zabbix server"}, "selectParentTemplates": ["templateid", "host"]}' | api host.get | jq -c '.[0] // {}')
  passive=$(jq -r '.parentTemplates[]? | select(.host == "Linux by Zabbix agent") | .templateid' <<<"$host")
  [ -n "$passive" ] || return 0
  active=$(get_id template templateid '{"host": "Linux by Zabbix agent active"}')
  if [ -z "$active" ]; then
    log "template \"Linux by Zabbix agent active\" not found, host \"Zabbix server\" keeps \"Linux by Zabbix agent\""
    return 0
  fi
  keys=$(jq -n --arg t "$passive" '{output: ["key_"], templateids: [$t]}' | api item.get | jq -c 'map(.key_)')
  # Unlink without templates_clear, then link: Zabbix merges the now unlinked items into the active template's items with the same key, so their history stays.
  jq -c --arg p "$passive" '{hostid, templates: [.parentTemplates[] | select(.templateid != $p) | {templateid}]}' <<<"$host" | api host.update >/dev/null
  jq -c --arg p "$passive" --arg a "$active" '{hostid, templates: ([.parentTemplates[] | select(.templateid != $p and .templateid != $a) | {templateid}] + [{templateid: $a}])}' <<<"$host" | api host.update >/dev/null
  ids=$(jq -c '{output: ["key_", "templateid"], hostids: [.hostid]}' <<<"$host" | api item.get |
    jq -c --argjson k "$keys" '[.[] | select(.templateid == "0" and (.key_ | IN($k[]))) | .itemid]')
  [ "$ids" = '[]' ] || api item.delete <<<"$ids" >/dev/null
  log "host \"Zabbix server\": template \"Linux by Zabbix agent\" replaced by \"Linux by Zabbix agent active\", $(jq length <<<"$ids") leftover item(s) of the old template deleted"
}

ensure_guest_disabled() {
  local guest disabled
  guest=$(echo '{"output": ["userid"], "filter": {"username": "guest"}, "selectUsrgrps": ["usrgrpid", "users_status"]}' | api user.get | jq -c '.[0] // empty')
  [ -n "$guest" ] || return 0
  jq -e 'any(.usrgrps[]; .users_status == "1")' >/dev/null <<<"$guest" && return 0
  disabled=$(get_id usergroup usrgrpid '{"name": "Disabled"}')
  [ -n "$disabled" ] || die "user group \"Disabled\" not found, cannot disable guest access"
  jq -c --arg g "$disabled" '{userid, usrgrps: ([.usrgrps[] | {usrgrpid}] + [{usrgrpid: $g}])}' <<<"$guest" | api user.update >/dev/null
  log "guest access disabled"
}

set_mediatype() {
  local name=$1 token_file=$2 token_param=$3 url=${4:-}
  echo "{\"output\": [\"mediatypeid\", \"parameters\"], \"filter\": {\"name\": \"$name\"}}" | api mediatype.get |
    jq -c --arg name "$name" --arg p "$token_param" --arg url "$url" --rawfile tok "$token_file" '
      (.[0] // error("media type \($name) not found"))
      | {mediatypeid, status: 0, parameters: [.parameters[]
          | if .name == $p then .value = ($tok | gsub("\\s"; ""))
            elif .name == "zabbix_url" and $url != "" then .value = $url
            else . end]}' |
    api mediatype.update >/dev/null
  get_id mediatype mediatypeid "{\"name\": \"$name\"}"
}

ensure_user_media() {
  local userid=$1 mediatypeid=$2 sendto=$3 params
  params=$(jq -n --arg u "$userid" '{userids: [$u], output: ["userid"], selectMedias: ["mediaid", "mediatypeid", "sendto", "active", "severity", "period"]}' |
    api user.get | jq -c --arg mt "$mediatypeid" --arg to "$sendto" '
      .[0] as $u
      | if any($u.medias[]; .mediatypeid == $mt and .sendto == $to and .active == "0")
          and ([$u.medias[] | select(.mediatypeid == $mt)] | length) == 1
        then empty
        else {userid: $u.userid, medias: ([$u.medias[] | select(.mediatypeid != $mt)]
          + [{mediatypeid: $mt, sendto: $to, active: 0, severity: 63, period: "1-7,00:00-24:00"}])}
        end')
  [ -z "$params" ] || api user.update <<<"$params" >/dev/null
}

configure_telegram() {
  if ! has_text "$TELEGRAM_TOKEN_FILE" || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    log "Telegram: token or TELEGRAM_CHAT_ID not set, left untouched"
    return 0
  fi
  [[ $TELEGRAM_CHAT_ID =~ ^(-?[0-9]+|@[A-Za-z0-9_]{5,32})$ ]] || die "TELEGRAM_CHAT_ID must be a numeric chat id or @channelname"
  local mt admin action
  mt=$(set_mediatype Telegram "$TELEGRAM_TOKEN_FILE" api_token)
  admin=$(get_id user userid '{"username": "Admin"}')
  ensure_user_media "$admin" "$mt" "$TELEGRAM_CHAT_ID"
  action=$(echo '{"output": ["actionid", "status"], "filter": {"name": "Report problems to Zabbix administrators"}}' | api action.get | jq -c '.[0] // empty')
  if [ -n "$action" ] && jq -e '.status == "1"' >/dev/null <<<"$action"; then
    jq -c '{actionid, status: 0}' <<<"$action" | api action.update >/dev/null
  fi
  log "Telegram: media type enabled, Admin notified in chat $TELEGRAM_CHAT_ID"
}

ensure_slack_role() {
  local rid
  rid=$(get_id role roleid "$(jq -cn --arg n "$SLACK_ROLE" '{name: $n}')")
  [ -n "$rid" ] || rid=$(jq -n --arg n "$SLACK_ROLE" '{name: $n, type: 3}' | api role.create | jq -r '.roleids[0]')
  jq -n --arg r "$rid" '{roleids: [$r], output: ["roleid"], selectRules: ["ui", "actions"]}' | api role.get |
    jq -c '.[0] | {roleid, type: 3, rules: {
      "api.access": 0, "ui.default_access": 0, "modules.default_access": 0, "actions.default_access": 0,
      ui: [.rules.ui[] | {name, status: (if .name == "monitoring.problems" then 1 else 0 end)}],
      actions: [.rules.actions[] | {name, status: 0}]}}' |
    api role.update >/dev/null
  echo "$rid"
}

ensure_slack_group() {
  local gid
  gid=$(get_id usergroup usrgrpid "$(jq -cn --arg n "$SLACK_GROUP" '{name: $n}')")
  [ -n "$gid" ] || gid=$(jq -n --arg n "$SLACK_GROUP" '{name: $n, gui_access: 3}' | api usergroup.create | jq -r '.usrgrpids[0]')
  jq -n --arg g "$gid" '{usrgrpid: $g, gui_access: 3, users_status: 0}' | api usergroup.update >/dev/null
  echo "$gid"
}

ensure_slack_user() {
  local env=$1 rid=$2 gid=$3 uid user
  user=$(jq -n --arg n "slack-$env" '{output: ["userid", "roleid"], filter: {username: $n}, selectUsrgrps: ["usrgrpid"]}' | api user.get | jq -c '.[0] // empty')
  if [ -z "$user" ]; then
    uid=$(head -c 4096 /dev/urandom | tr -dc 'A-Za-z0-9' | cut -c1-40 |
      jq -R --arg n "slack-$env" --arg r "$rid" --arg g "$gid" \
        '{username: $n, name: $n, passwd: ., roleid: $r, usrgrps: [{usrgrpid: $g}]}' |
      api user.create | jq -r '.userids[0]')
  else
    uid=$(jq -r .userid <<<"$user")
    if ! jq -e --arg r "$rid" --arg g "$gid" '.roleid == $r and ([.usrgrps[].usrgrpid] == [$g])' >/dev/null <<<"$user"; then
      jq -n --arg u "$uid" --arg r "$rid" --arg g "$gid" '{userid: $u, roleid: $r, usrgrps: [{usrgrpid: $g}]}' | api user.update >/dev/null
    fi
  fi
  echo "$uid"
}

ensure_slack_action() {
  local env=$1 uid=$2 mt=$3 aid body
  body=$(jq -n --arg name "$SLACK_ACTION_PREFIX$env" --arg env "$env" --arg u "$uid" --arg mt "$mt" '{
    name: $name, status: 0, esc_period: "1h",
    filter: {evaltype: 0, conditions: [{conditiontype: 26, operator: 0, value: $env, value2: "env"}]},
    operations: [{operationtype: 0, esc_step_from: 1, esc_step_to: 1,
      opmessage: {default_msg: 1, mediatypeid: $mt}, opmessage_usr: [{userid: $u}]}],
    recovery_operations: [{operationtype: 11, opmessage: {default_msg: 1}}],
    update_operations: [{operationtype: 12, opmessage: {default_msg: 1}}]}')
  aid=$(get_id action actionid "$(jq -cn --arg n "$SLACK_ACTION_PREFIX$env" '{name: $n}')")
  if [ -n "$aid" ]; then
    jq -c --arg a "$aid" '. + {actionid: $a}' <<<"$body" | api action.update >/dev/null
  else
    jq -c '. + {eventsource: 0}' <<<"$body" | api action.create >/dev/null
  fi
}

configure_slack() {
  local -A channel=()
  local pair env pairs mt rid gid uid keep
  IFS=',' read -ra pairs <<<"${SLACK_CHANNELS:-}"
  for pair in "${pairs[@]}"; do
    pair=${pair//[[:space:]]/}
    [ -n "$pair" ] || continue
    env=${pair%%:*}
    [[ $pair == *:* && $env =~ ^[A-Za-z0-9_-]{1,32}$ && ${pair#*:} =~ ^#?[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] ||
      die "SLACK_CHANNELS: invalid entry '$pair', expected env:#channel (env: letters, digits, _ or -)"
    [ -z "${channel[$env]:-}" ] || die "SLACK_CHANNELS: env '$env' is listed twice"
    channel[$env]=${pair#*:}
  done

  if [ "${#channel[@]}" -eq 0 ]; then
    log "Slack: SLACK_CHANNELS not set"
  elif ! has_text "$SLACK_TOKEN_FILE"; then
    log "Slack: secrets/slack_bot_token is empty, channels not set up"
  else
    mt=$(set_mediatype Slack "$SLACK_TOKEN_FILE" bot_token "${ZBX_PUBLIC_URL%/}")
    rid=$(ensure_slack_role)
    gid=$(ensure_slack_group)
    for env in "${!channel[@]}"; do
      uid=$(ensure_slack_user "$env" "$rid" "$gid")
      ensure_user_media "$uid" "$mt" "${channel[$env]}"
      ensure_slack_action "$env" "$uid" "$mt"
      log "Slack: problems tagged env=$env go to ${channel[$env]}"
    done
  fi

  keep=$(printf '%s\n' "${!channel[@]}" | jq -Rsc --arg p "$SLACK_ACTION_PREFIX" 'split("\n") | map(select(. != "") | $p + .)')
  jq -n --arg p "$SLACK_ACTION_PREFIX" '{output: ["actionid", "name", "status"], search: {name: $p}, startSearch: true}' | api action.get |
    jq -c --argjson keep "$keep" '.[] | select(.status == "0" and (.name as $n | $keep | index($n) | not))' |
    while read -r action; do
      jq -c '{actionid, status: 1}' <<<"$action" | api action.update >/dev/null
      log "Slack: disabled action \"$(jq -r .name <<<"$action")\" (env no longer in SLACK_CHANNELS)"
    done
}

main() {
  trap logout EXIT
  local url_re='^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$'
  [[ ${ZBX_PUBLIC_URL:-} =~ $url_re ]] || die "ZBX_PUBLIC_URL must be an http(s) URL such as https://zabbix.example.com"
  has_text "$ADMIN_PW_FILE" || die "secrets/zabbix_admin_password is empty; run setup.sh"
  wait_for_api
  login_admin
  configure_frontend_url
  use_active_agent_template
  ensure_guest_disabled
  configure_telegram
  configure_slack
  log "done"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
