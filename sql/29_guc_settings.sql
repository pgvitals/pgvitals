-- ============================================================
-- 29 · KEY GUC SETTINGS REVIEW
-- ============================================================
-- What    : Critical configuration parameters and their source
-- Look for: source = 'default' on memory/checkpoint settings
--           (defaults are often too conservative for production)
-- Action  : Tune in postgresql.conf; reload with pg_reload_conf()
-- ============================================================

SELECT
    name,
    setting,
    unit,
    source,
    short_desc
FROM pg_settings
WHERE name IN (
    -- Memory
    'shared_buffers', 'work_mem', 'maintenance_work_mem',
    'effective_cache_size', 'temp_buffers',
    -- Checkpoints & WAL
    'checkpoint_timeout', 'checkpoint_completion_target',
    'max_wal_size', 'min_wal_size', 'wal_level', 'wal_compression',
    -- Autovacuum
    'autovacuum', 'autovacuum_max_workers',
    'autovacuum_vacuum_cost_delay', 'autovacuum_vacuum_scale_factor',
    'autovacuum_analyze_scale_factor', 'autovacuum_freeze_max_age',
    -- Connections
    'max_connections', 'superuser_reserved_connections',
    'idle_in_transaction_session_timeout', 'statement_timeout',
    -- Parallelism
    'max_parallel_workers_per_gather', 'max_worker_processes',
    'max_parallel_workers',
    -- I/O
    'random_page_cost', 'seq_page_cost', 'effective_io_concurrency',
    -- JIT
    'enable_jit', 'jit_above_cost', 'jit_optimize_above_cost',
    -- Logging
    'log_min_duration_statement', 'log_lock_waits',
    'deadlock_timeout', 'log_temp_files',
    -- Locks
    'lock_timeout', 'deadlock_timeout'
)
ORDER BY
    CASE
        WHEN name LIKE '%buffer%' OR name LIKE '%mem%'          THEN 1
        WHEN name LIKE '%checkpoint%' OR name LIKE '%wal%'      THEN 2
        WHEN name LIKE '%autovacuum%'                           THEN 3
        WHEN name LIKE '%connection%' OR name LIKE '%timeout%'  THEN 4
        ELSE 5
    END,
    name;
