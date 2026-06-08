-- ============================================================
-- 00 · PREREQUISITES CHECK
-- ============================================================
-- What    : Confirm your database environment is ready for pgvitals
-- Look for: has_pg_monitor = true and pg_stat_statements installed
-- Action  : Install pg_stat_statements; grant pg_monitor role to your user
-- Requires: pg_stat_statements in shared_preload_libraries
-- ============================================================

-- Check shared_preload_libraries includes pg_stat_statements
SELECT name, setting FROM pg_settings WHERE name = 'shared_preload_libraries';

-- Confirm extension is installed in this database
SELECT extname, extversion FROM pg_extension WHERE extname = 'pg_stat_statements';

-- Confirm current user has monitoring privileges
SELECT current_user,
       pg_has_role(current_user, 'pg_monitor', 'MEMBER') AS has_pg_monitor;

-- Quick stats summary (sanity check data is being collected)
SELECT count(*) AS tracked_queries FROM pg_stat_statements;
