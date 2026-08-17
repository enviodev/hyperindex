-- Pins every text column of the fixture to byte-order collation.
--
-- Row order for `order_by: {id: asc}` is decided by Postgres, not by the
-- engine under test, so the recorded oracle inherits whatever locale the
-- cluster was initdb'd with: under C.UTF-8 `user "quoted" 🚀` sorts before
-- `user-1`, under en_US.utf8 it sorts after (punctuation is ignored at the
-- primary level). A snapshot recorded on one cluster then reports ~90
-- mismatches on the other, none of which is a parity bug.
--
-- A cluster's locale cannot be changed after initdb, so the fixture pins the
-- columns instead. Applied after schema.sql, which is a faithful dump of what
-- `envio local db-migrate setup` creates and stays that way.
DO $$
DECLARE
  col record;
BEGIN
  FOR col IN
    SELECT c.relname AS table_name, a.attname AS column_name,
           format_type(a.atttypid, a.atttypmod) AS column_type
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND a.atttypid IN ('text'::regtype, 'text[]'::regtype)
  LOOP
    EXECUTE format(
      'ALTER TABLE public.%I ALTER COLUMN %I TYPE %s COLLATE "C"',
      col.table_name, col.column_name, col.column_type
    );
  END LOOP;
END $$;
