-- ============================================================
-- 26 · TRANSACTION ID (XID) WRAPAROUND RISK
-- ============================================================
-- What    : Distance from XID exhaustion (hard limit: ~2 billion)
-- Look for: xid_age > 1.5B → emergency VACUUM FREEZE needed
--           pct_used > 70% → start planning maintenance window
-- Action  : VACUUM FREEZE on oldest tables;
--           Lower autovacuum_freeze_max_age
-- ============================================================

-- Database level
SELECT
    datname,
    age(datfrozenxid)                                                 AS xid_age,
    2147483647 - age(datfrozenxid)                                   AS xid_remaining,
    round(age(datfrozenxid)::numeric / 2147483647 * 100, 2)         AS pct_used
FROM pg_database
ORDER BY age(datfrozenxid) DESC;

-- Table level — top 20 oldest tables
SELECT
    n.nspname                                                         AS schemaname,
    c.relname                                                         AS tablename,
    age(c.relfrozenxid)                                               AS xid_age,
    round(age(c.relfrozenxid)::numeric / 2147483647 * 100, 2)       AS pct_used,
    pg_size_pretty(pg_relation_size(c.oid))                          AS table_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY age(c.relfrozenxid) DESC
LIMIT 20;
