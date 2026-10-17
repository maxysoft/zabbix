#!/bin/sh
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<'SQL'
\set VERBOSITY terse
SET log_min_error_statement = panic;
\set pw `cat /run/secrets/zabbix_db_password`
CREATE ROLE zabbix LOGIN PASSWORD :'pw';
CREATE DATABASE zabbix OWNER zabbix;
\c zabbix
SET log_min_error_statement = panic;
\set apw `cat /run/secrets/zabbix_admin_password`
CREATE EXTENSION pgcrypto;
CREATE TABLE zbx_admin_seed AS SELECT crypt(rtrim(:'apw', E'\r\n'), gen_salt('bf', 10)) AS passwd;
ALTER TABLE zbx_admin_seed OWNER TO zabbix;
DROP EXTENSION pgcrypto;
SQL
