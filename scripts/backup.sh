#!/bin/sh
set -eu

DIR=/backups
STATUS=$DIR/.status
PGPASSWORD=$(cat /run/secrets/zabbix_db_password)
export PGPASSWORD

EXCLUDE_SQL="
SELECT format('%s.%s_*', associated_schema_name, associated_table_prefix)
FROM _timescaledb_catalog.hypertable
WHERE table_name ~ '^(history|trends)'"

backup() {
  set --
  suffix=
  if [ "${BACKUP_EXCLUDE_HISTORY:-false}" = true ]; then
    suffix=-nohistory
    chunks=$(psql -XAtq -v ON_ERROR_STOP=1 -c "$EXCLUDE_SQL") || return 1
    set -- --exclude-table-data='public.history*' --exclude-table-data='public.trends*'
    for pattern in $chunks; do
      set -- "$@" --exclude-table-data="$pattern"
    done
  fi
  file="$DIR/zabbix-$(date +%Y%m%d-%H%M%S)$suffix.dump"
  if ! pg_dump -Fc -f "$file.partial" "$@"; then
    rm -f "$file.partial"
    return 1
  fi
  mv "$file.partial" "$file"
  echo "backup: wrote $file ($(du -h "$file" | cut -f1))"
}

prune() {
  find "$DIR" -maxdepth 1 -type f \( -name 'zabbix-*.dump' -o -name 'zabbix-*.partial' \) -mtime +"$BACKUP_KEEP_DAYS" -delete
}

case "${BACKUP_HOUR:-}" in
  [0-9] | 0[0-9] | 1[0-9] | 2[0-3]) ;;
  *) echo "backup: BACKUP_HOUR must be 0-23" >&2; exit 1 ;;
esac
case "${BACKUP_KEEP_DAYS:-}" in
  '' | *[!0-9]*) echo "backup: BACKUP_KEEP_DAYS must be a number" >&2; exit 1 ;;
esac

if [ "${1:-}" = --once ]; then
  backup
  prune
  exit 0
fi

echo "backup: daily at $BACKUP_HOUR:00 ($(date +%Z)), keeping $BACKUP_KEEP_DAYS days, exclude history: ${BACKUP_EXCLUDE_HISTORY:-false}"
hour=$((${BACKUP_HOUR#0} + 0))
last=
while :; do
  if [ "$((1$(date +%H) - 100))" -eq "$hour" ] && [ "$(date +%F)" != "$last" ]; then
    last=$(date +%F)
    if backup; then
      echo "ok $(date)" > "$STATUS"
      prune
    else
      echo "failed $(date)" > "$STATUS"
      echo "backup: FAILED" >&2
    fi
  fi
  sleep 60
done
