-- ──────────────────────────────────────────────────────────────────────────────
-- pgvitals health_score.sql
-- Single-file PostgreSQL health check — returns a 0-100 score with breakdown.
--
-- Usage:
--   psql -d mydb -f health_score.sql
--   psql "postgres://user:pass@host/db" -f health_score.sql
--
-- No extensions required. Works on PostgreSQL 14+. Read-only (no writes).
-- ──────────────────────────────────────────────────────────────────────────────

\pset title 'pgvitals Health Score'
\pset border 2
\pset linestyle unicode
\pset null '–'
\pset format aligned

-- ── 1 of 2: Overall Score ────────────────────────────────────────────────────

WITH

xid AS (                                        -- XID wraparound (20 pts)
  SELECT
    max(age(datfrozenxid))::bigint AS max_xid_age,
    CASE
      WHEN max(age(datfrozenxid)) > 1500000000 THEN 0
      WHEN max(age(datfrozenxid)) > 1000000000 THEN 5
      WHEN max(age(datfrozenxid)) >  500000000 THEN 15
      ELSE 20
    END AS pts,
    20 AS max_pts
  FROM pg_database WHERE datallowconn
),

dead AS (                                       -- Dead tuple bloat (15 pts)
  SELECT
    count(*) FILTER (WHERE
      n_dead_tup::float / NULLIF(n_live_tup + n_dead_tup, 0) > 0.1
      AND n_live_tup + n_dead_tup > 1000
    ) AS bloated,
    CASE
      WHEN count(*) FILTER (WHERE
        n_dead_tup::float / NULLIF(n_live_tup + n_dead_tup, 0) > 0.2
        AND n_live_tup + n_dead_tup > 1000) > 5 THEN 0
      WHEN count(*) FILTER (WHERE
        n_dead_tup::float / NULLIF(n_live_tup + n_dead_tup, 0) > 0.1
        AND n_live_tup + n_dead_tup > 1000) > 3 THEN 7
      WHEN count(*) FILTER (WHERE
        n_dead_tup::float / NULLIF(n_live_tup + n_dead_tup, 0) > 0.1
        AND n_live_tup + n_dead_tup > 1000) > 0 THEN 10
      ELSE 15
    END AS pts,
    15 AS max_pts
  FROM pg_stat_user_tables
),

conns AS (                                      -- Connection saturation (15 pts)
  SELECT
    round(
      count(*)::numeric
      / (SELECT setting::int FROM pg_settings WHERE name = 'max_connections')
      * 100, 1
    ) AS used_pct,
    CASE
      WHEN count(*)::float
        / (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') > 0.90 THEN 0
      WHEN count(*)::float
        / (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') > 0.80 THEN 5
      WHEN count(*)::float
        / (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') > 0.70 THEN 10
      ELSE 15
    END AS pts,
    15 AS max_pts
  FROM pg_stat_activity WHERE pid <> pg_backend_pid()
),

locks AS (                                      -- Lock waits (10 pts)
  SELECT
    count(*) AS blocked,
    CASE
      WHEN count(*) > 5 THEN 0
      WHEN count(*) > 0 THEN 5
      ELSE 10
    END AS pts,
    10 AS max_pts
  FROM pg_stat_activity
  WHERE cardinality(pg_blocking_pids(pid)) > 0
),

cache AS (                                      -- Buffer cache hit ratio (10 pts)
  SELECT
    round(
      blks_hit::numeric / NULLIF(blks_read + blks_hit, 0) * 100, 2
    ) AS hit_pct,
    CASE
      WHEN blks_hit::float / NULLIF(blks_read + blks_hit, 0) < 0.90 THEN 0
      WHEN blks_hit::float / NULLIF(blks_read + blks_hit, 0) < 0.95 THEN 5
      ELSE 10
    END AS pts,
    10 AS max_pts
  FROM pg_stat_database
  WHERE datname = current_database()
),

idxs AS (                                       -- Invalid indexes (10 pts)
  SELECT
    count(*) AS invalid,
    CASE WHEN count(*) > 0 THEN 0 ELSE 10 END AS pts,
    10 AS max_pts
  FROM pg_index
  WHERE NOT indisvalid
),

idle_txn AS (                                   -- Idle-in-transaction (10 pts)
  SELECT
    count(*) AS stuck,
    CASE
      WHEN count(*) FILTER (WHERE
        extract(epoch FROM now() - state_change) > 300) > 0 THEN 0
      WHEN count(*) FILTER (WHERE
        extract(epoch FROM now() - state_change) > 30) > 0  THEN 5
      ELSE 10
    END AS pts,
    10 AS max_pts
  FROM pg_stat_activity
  WHERE state = 'idle in transaction' AND pid <> pg_backend_pid()
),

repl AS (                                       -- Replication lag (5 pts)
  SELECT
    count(*) AS standbys,
    CASE
      WHEN count(*) FILTER (WHERE replay_lag > interval '30 seconds') > 0 THEN 0
      WHEN count(*) FILTER (WHERE replay_lag > interval '5 seconds')  > 0 THEN 2
      ELSE 5
    END AS pts,
    5 AS max_pts
  FROM pg_stat_replication
),

seqs AS (                                       -- Sequence exhaustion (5 pts)
  SELECT
    count(*) FILTER (WHERE
      last_value IS NOT NULL
      AND (last_value - min_value)::float / NULLIF(max_value - min_value, 0) > 0.8
    ) AS at_risk,
    CASE WHEN count(*) FILTER (WHERE
      last_value IS NOT NULL
      AND (last_value - min_value)::float / NULLIF(max_value - min_value, 0) > 0.8
    ) > 0 THEN 0 ELSE 5 END AS pts,
    5 AS max_pts
  FROM pg_sequences
  WHERE NOT cycle
),

totals AS (
  SELECT
    xid.pts + dead.pts + conns.pts + locks.pts + cache.pts
      + idxs.pts + idle_txn.pts + repl.pts + seqs.pts     AS score,
    xid.max_xid_age, dead.bloated,  conns.used_pct,
    locks.blocked,   cache.hit_pct, idxs.invalid,
    idle_txn.stuck,  repl.standbys, seqs.at_risk,
    ( CASE WHEN xid.pts     = xid.max_pts     THEN 1 ELSE 0 END
    + CASE WHEN dead.pts    = dead.max_pts    THEN 1 ELSE 0 END
    + CASE WHEN conns.pts   = conns.max_pts   THEN 1 ELSE 0 END
    + CASE WHEN locks.pts   = locks.max_pts   THEN 1 ELSE 0 END
    + CASE WHEN cache.pts   = cache.max_pts   THEN 1 ELSE 0 END
    + CASE WHEN idxs.pts    = idxs.max_pts    THEN 1 ELSE 0 END
    + CASE WHEN idle_txn.pts= idle_txn.max_pts THEN 1 ELSE 0 END
    + CASE WHEN repl.pts    = repl.max_pts    THEN 1 ELSE 0 END
    + CASE WHEN seqs.pts    = seqs.max_pts    THEN 1 ELSE 0 END ) AS passed,
    ( CASE WHEN xid.pts     = 0 THEN 1 ELSE 0 END
    + CASE WHEN dead.pts    = 0 THEN 1 ELSE 0 END
    + CASE WHEN conns.pts   = 0 THEN 1 ELSE 0 END
    + CASE WHEN locks.pts   = 0 THEN 1 ELSE 0 END
    + CASE WHEN cache.pts   = 0 THEN 1 ELSE 0 END
    + CASE WHEN idxs.pts    = 0 THEN 1 ELSE 0 END
    + CASE WHEN idle_txn.pts= 0 THEN 1 ELSE 0 END
    + CASE WHEN repl.pts    = 0 THEN 1 ELSE 0 END
    + CASE WHEN seqs.pts    = 0 THEN 1 ELSE 0 END ) AS failed
  FROM xid, dead, conns, locks, cache, idxs, idle_txn, repl, seqs
)

SELECT
  score || ' / 100'   AS "Score",
  CASE
    WHEN score >= 90 THEN 'A'
    WHEN score >= 75 THEN 'B'
    WHEN score >= 60 THEN 'C'
    WHEN score >= 40 THEN 'D'
    ELSE                  'F'
  END                 AS "Grade",
  CASE
    WHEN score >= 90 THEN 'Excellent — all checks clear'
    WHEN score >= 75 THEN 'Good — minor issues to review'
    WHEN score >= 60 THEN 'Fair — several issues need attention'
    WHEN score >= 40 THEN 'Poor — significant issues, act soon'
    ELSE                  'Critical — immediate action required'
  END                 AS "Status",
  passed              AS "✓ Passed",
  9 - passed - failed AS "~ Warned",
  failed              AS "✗ Failed"
FROM totals;


-- ── 2 of 2: Per-Check Breakdown ──────────────────────────────────────────────

WITH

xid AS (
  SELECT
    max(age(datfrozenxid))::bigint AS max_xid_age,
    CASE
      WHEN max(age(datfrozenxid)) > 1500000000 THEN 0
      WHEN max(age(datfrozenxid)) > 1000000000 THEN 5
      WHEN max(age(datfrozenxid)) >  500000000 THEN 15
      ELSE 20
    END AS pts,
    20 AS max_pts
  FROM pg_database WHERE datallowconn
),

dead AS (
  SELECT
    count(*) FILTER (WHERE
      n_dead_tup::float / NULLIF(n_live_tup + n_dead_tup, 0) > 0.1
      AND n_live_tup + n_dead_tup > 1000
    ) AS bloated,
    CASE
      WHEN count(*) FILTER (WHERE
        n_dead_tup::float / NULLIF(n_live_tup + n_dead_tup, 0) > 0.2
        AND n_live_tup + n_dead_tup > 1000) > 5 THEN 0
      WHEN count(*) FILTER (WHERE
        n_dead_tup::float / NULLIF(n_live_tup + n_dead_tup, 0) > 0.1
        AND n_live_tup + n_dead_tup > 1000) > 3 THEN 7
      WHEN count(*) FILTER (WHERE
        n_dead_tup::float / NULLIF(n_live_tup + n_dead_tup, 0) > 0.1
        AND n_live_tup + n_dead_tup > 1000) > 0 THEN 10
      ELSE 15
    END AS pts,
    15 AS max_pts
  FROM pg_stat_user_tables
),

conns AS (
  SELECT
    round(
      count(*)::numeric
      / (SELECT setting::int FROM pg_settings WHERE name = 'max_connections')
      * 100, 1
    ) AS used_pct,
    CASE
      WHEN count(*)::float
        / (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') > 0.90 THEN 0
      WHEN count(*)::float
        / (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') > 0.80 THEN 5
      WHEN count(*)::float
        / (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') > 0.70 THEN 10
      ELSE 15
    END AS pts,
    15 AS max_pts
  FROM pg_stat_activity WHERE pid <> pg_backend_pid()
),

locks AS (
  SELECT
    count(*) AS blocked,
    CASE
      WHEN count(*) > 5 THEN 0
      WHEN count(*) > 0 THEN 5
      ELSE 10
    END AS pts,
    10 AS max_pts
  FROM pg_stat_activity
  WHERE cardinality(pg_blocking_pids(pid)) > 0
),

cache AS (
  SELECT
    round(
      blks_hit::numeric / NULLIF(blks_read + blks_hit, 0) * 100, 2
    ) AS hit_pct,
    CASE
      WHEN blks_hit::float / NULLIF(blks_read + blks_hit, 0) < 0.90 THEN 0
      WHEN blks_hit::float / NULLIF(blks_read + blks_hit, 0) < 0.95 THEN 5
      ELSE 10
    END AS pts,
    10 AS max_pts
  FROM pg_stat_database
  WHERE datname = current_database()
),

idxs AS (
  SELECT
    count(*) AS invalid,
    CASE WHEN count(*) > 0 THEN 0 ELSE 10 END AS pts,
    10 AS max_pts
  FROM pg_index
  WHERE NOT indisvalid
),

idle_txn AS (
  SELECT
    count(*) AS stuck,
    CASE
      WHEN count(*) FILTER (WHERE
        extract(epoch FROM now() - state_change) > 300) > 0 THEN 0
      WHEN count(*) FILTER (WHERE
        extract(epoch FROM now() - state_change) > 30) > 0  THEN 5
      ELSE 10
    END AS pts,
    10 AS max_pts
  FROM pg_stat_activity
  WHERE state = 'idle in transaction' AND pid <> pg_backend_pid()
),

repl AS (
  SELECT
    count(*) AS standbys,
    CASE
      WHEN count(*) FILTER (WHERE replay_lag > interval '30 seconds') > 0 THEN 0
      WHEN count(*) FILTER (WHERE replay_lag > interval '5 seconds')  > 0 THEN 2
      ELSE 5
    END AS pts,
    5 AS max_pts
  FROM pg_stat_replication
),

seqs AS (
  SELECT
    count(*) FILTER (WHERE
      last_value IS NOT NULL
      AND (last_value - min_value)::float / NULLIF(max_value - min_value, 0) > 0.8
    ) AS at_risk,
    CASE WHEN count(*) FILTER (WHERE
      last_value IS NOT NULL
      AND (last_value - min_value)::float / NULLIF(max_value - min_value, 0) > 0.8
    ) > 0 THEN 0 ELSE 5 END AS pts,
    5 AS max_pts
  FROM pg_sequences
  WHERE NOT cycle
)

SELECT
  ord                                       AS "#",
  check_name                                AS "Check",
  pts || ' / ' || max_pts                   AS "Score",
  CASE
    WHEN pts = max_pts THEN '✓ Clear'
    WHEN pts = 0       THEN '✗ Alert'
    ELSE                    '~ Warning'
  END                                       AS "Status",
  detail                                    AS "Detail"
FROM (
  SELECT 1 AS ord, 'XID Wraparound'          AS check_name, pts, max_pts,
    'max age: ' || to_char(max_xid_age, 'FM999,999,999') || ' txns (limit ~2 billion)'
    AS detail FROM xid
  UNION ALL
  SELECT 2, 'Dead Tuple Bloat',              pts, max_pts,
    bloated || ' table(s) with >10% dead tuples' FROM dead
  UNION ALL
  SELECT 3, 'Connection Saturation',         pts, max_pts,
    used_pct || '% of max_connections in use' FROM conns
  UNION ALL
  SELECT 4, 'Lock Waits',                    pts, max_pts,
    blocked || ' session(s) currently blocked' FROM locks
  UNION ALL
  SELECT 5, 'Buffer Cache Hit Ratio',        pts, max_pts,
    COALESCE(hit_pct::text, 'no data') || '% hit rate (target ≥ 95%)' FROM cache
  UNION ALL
  SELECT 6, 'Invalid Indexes',               pts, max_pts,
    invalid || ' invalid index(es) detected' FROM idxs
  UNION ALL
  SELECT 7, 'Idle-in-Transaction',           pts, max_pts,
    stuck || ' session(s) stuck in open transaction' FROM idle_txn
  UNION ALL
  SELECT 8, 'Replication Lag',               pts, max_pts,
    standbys || ' standby(s) configured' FROM repl
  UNION ALL
  SELECT 9, 'Sequence Exhaustion',           pts, max_pts,
    at_risk || ' sequence(s) above 80% capacity' FROM seqs
) checks
ORDER BY ord;
