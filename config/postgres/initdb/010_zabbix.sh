#!/bin/sh
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<'SQL'
\set VERBOSITY terse
SET log_min_error_statement = panic;
\set pw `cat /run/secrets/zabbix_db_password`
CREATE ROLE zabbix LOGIN PASSWORD :'pw';
CREATE DATABASE zabbix OWNER zabbix;
SQL
