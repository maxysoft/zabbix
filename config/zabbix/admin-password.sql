\set ON_ERROR_STOP on
\set VERBOSITY terse
\set pw `cat /run/secrets/zabbix_admin_password`
CREATE EXTENSION IF NOT EXISTS pgcrypto;
UPDATE users SET passwd = crypt(rtrim($1, E'\r\n'), gen_salt('bf', 10)) WHERE username = 'Admin' \bind :pw \g
DROP EXTENSION pgcrypto;
