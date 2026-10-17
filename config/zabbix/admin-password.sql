DO $$
BEGIN
  IF to_regclass('public.zbx_admin_seed') IS NOT NULL THEN
    UPDATE users SET passwd = (SELECT passwd FROM zbx_admin_seed) WHERE username = 'Admin';
    DROP TABLE zbx_admin_seed;
  END IF;
END
$$;
