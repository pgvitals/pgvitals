// pgvitals — Runbook data
// 8 guided triage paths for common PostgreSQL symptoms.

const RUNBOOKS = [
  {
    id: 'slow-queries',
    icon: '🐌',
    symptom: 'Queries suddenly slow',
    trigger: 'Response times jumped; users reporting slowness; p99 latency spiked with no recent deployment.',
    steps: [
      {
        sectionId: '01', sectionTitle: 'Slow / Expensive Queries',
        slug: 'slow-expensive-queries',
        rationale: 'Baseline: find which queries regressed. Compare mean_exec_ms and pct_total_time against your normal.',
        lookFor: 'mean_exec_ms > 100ms or pct_total_time > 10% for a single query',
        ifHot: 'Run EXPLAIN (ANALYZE, BUFFERS) on the top query. Look for sequential scans or bad row estimates.',
        ifClear: 'Stats may have been reset recently. Check section 18 for blocking transactions.'
      },
      {
        sectionId: '02', sectionTitle: 'Temp File & work_mem Pressure',
        slug: 'temp-file-work-mem-pressure',
        rationale: 'A surge in temp file writes causes disk I/O that looks like CPU load.',
        lookFor: 'Any temp_written_mb > 0 in a query you didn\'t expect',
        ifHot: 'SET work_mem = \'256MB\' for that session and re-run. Faster? Increase work_mem in postgresql.conf.',
        ifClear: 'Not a sort/hash spill. Continue to scan check.'
      },
      {
        sectionId: '03', sectionTitle: 'Sequential Scan Hotspots',
        slug: 'sequential-scan-hotspots',
        rationale: 'A new query pattern, dropped index, or changed statistics can trigger a full table scan silently.',
        lookFor: 'seq_scan_pct > 50% on tables with n_live_tup > 10k that weren\'t showing this before',
        ifHot: 'Run sections 06 (unused indexes) and 08 (invalid indexes) to find the root cause.',
        ifClear: 'No scan regression. Check for lock contention next.'
      },
      {
        sectionId: '21', sectionTitle: 'Lock Wait Tree',
        slug: 'lock-wait-tree',
        rationale: 'A single blocking transaction cascades and makes every downstream query appear slow.',
        lookFor: 'Any query in waiting=true with a blocker_pid chain deeper than 2',
        ifHot: 'Identify the root blocker: pg_terminate_backend(pid) if safe. Then check section 18.',
        ifClear: 'No lock contention. Check planner statistics freshness next.'
      },
      {
        sectionId: '17', sectionTitle: 'Stale Statistics',
        slug: 'stale-statistics',
        rationale: 'Stale statistics cause the planner to choose bad plans — often the silent root cause of regressions.',
        lookFor: 'last_analyze > 24h on tables touched by the slow query; n_mod_since_analyze > 10% of n_live_tup',
        ifHot: 'ANALYZE the table immediately. Re-run EXPLAIN to confirm the plan improved.',
        ifClear: 'Stats are fresh. Check partitioned table health next.'
      },
      {
        sectionId: '34', sectionTitle: 'Partitioned Table Health',
        slug: 'partitioned-table-health',
        rationale: 'Too many partitions can slow down query planning times dramatically for queries targeting partitioned tables.',
        lookFor: 'partition_count > 100',
        ifHot: 'Merge old partitions; use monthly or yearly ranges instead of daily; drop unused indexes on child partitions.',
        ifClear: 'Partition counts are healthy. Review GUC memory settings in section 29.'
      }
    ]
  },
  {
    id: 'db-hanging',
    icon: '🔒',
    symptom: 'Database hanging / unresponsive',
    trigger: 'Queries queue up and never return; new connections stall; application timeouts escalating rapidly.',
    steps: [
      {
        sectionId: '20', sectionTitle: 'Idle-in-Transaction',
        slug: 'idle-in-transaction',
        rationale: 'An idle-in-transaction session holds locks and blocks vacuum. This is the #1 cause of "the DB is frozen".',
        lookFor: 'idle_duration > 30s — anything over 60s is an emergency',
        ifHot: 'pg_terminate_backend(pid) for idle-in-txn sessions > 30s. Then run section 21 to see what was blocked.',
        ifClear: 'No idle-in-txn. Check active lock waits next.'
      },
      {
        sectionId: '21', sectionTitle: 'Lock Wait Tree',
        slug: 'lock-wait-tree',
        rationale: 'A deep lock chain stalls every new query that touches those rows or tables.',
        lookFor: 'Blocker chain depth > 2; or a single pid appearing as blocker for > 5 waiters',
        ifHot: 'Terminate the root blocker. If it\'s a long DDL (ALTER TABLE), consider cancelling it with pg_cancel_backend.',
        ifClear: 'No lock tree. Check open prepared transactions next.'
      },
      {
        sectionId: '35', sectionTitle: 'Open Prepared Transactions',
        slug: 'open-prepared-transactions',
        rationale: 'Orphaned prepared transactions (2PC) hold locks and prevent vacuum progress indefinitely.',
        lookFor: 'Any prepared transaction older than 5 minutes',
        ifHot: 'Identify the GID and run ROLLBACK PREPARED \'<gid>\'; or COMMIT PREPARED \'<gid>\';.',
        ifClear: 'No prepared transactions. Check connection saturation in section 19 next.'
      },
      {
        sectionId: '19', sectionTitle: 'Connection Saturation',
        slug: 'connection-saturation',
        rationale: 'When max_connections is reached, no new work can proceed — looks identical to a hang.',
        lookFor: 'used_pct > 80% or total connections near max_connections',
        ifHot: 'Terminate idle/idle-in-txn connections immediately. Long-term: deploy PgBouncer.',
        ifClear: 'Connections are fine. Check wait events for the root cause.'
      },
      {
        sectionId: '22', sectionTitle: 'Wait Events Breakdown',
        slug: 'wait-events-breakdown',
        rationale: 'Shows exactly what every backend is blocked on — I/O, locks, IPC, or CPU.',
        lookFor: 'Lock > 20% of events | IO:DataFileRead dominating | Client:ClientRead (application stall)',
        ifHot: 'Lock → section 21. IO:DataFileRead → section 31 (checkpoints). Client:ClientRead → application side.',
        ifClear: 'No dominant wait event. Run the full sweep with master.sql to find the anomaly.'
      }
    ]
  },
  {
    id: 'disk-filling',
    icon: '💾',
    symptom: 'Disk filling up fast',
    trigger: 'Disk usage growing faster than data volume explains; pg_wal directory bloated; alerts firing.',
    steps: [
      {
        sectionId: '25', sectionTitle: 'Replication Slot WAL Retention',
        slug: 'replication-slot-wal-retention',
        rationale: 'An inactive or lagging slot forces Postgres to keep ALL WAL since its restart_lsn. This is the most common "silent disk killer" — check it first.',
        lookFor: 'Any slot with wal_retained > 1 GB; or active = false with wal_retained > 0',
        ifHot: 'If consumer is gone: pg_drop_replication_slot(\'name\'). If lagging: investigate consumer I/O capacity.',
        ifClear: 'No slot WAL accumulation. Check WAL generation rate next.'
      },
      {
        sectionId: '33', sectionTitle: 'WAL Generation Rate',
        slug: 'wal-generation-rate',
        rationale: 'High WAL generation rate can saturate disk writes and fill up the pg_wal directory rapidly.',
        lookFor: 'wal_mb_per_hour > 1000 MB/hr | fpi_pct > 20%',
        ifHot: 'Verify if wal_compression is enabled; check section 31 for checkpoint write and sync times.',
        ifClear: 'WAL generation is normal. Check table bloat in section 11 next.'
      },
      {
        sectionId: '11', sectionTitle: 'Table Bloat',
        slug: 'table-bloat',
        rationale: 'Dead tuples accumulate invisibly when autovacuum can\'t keep up — pg_relation_size doesn\'t show this.',
        lookFor: 'bloat_pct_estimate > 20% on tables > 100 MB',
        ifHot: 'VACUUM (VERBOSE, ANALYZE) the bloated table. If it keeps recurring: check section 15 (autovacuum).',
        ifClear: 'Not table bloat. Check index bloat next.'
      },
      {
        sectionId: '10', sectionTitle: 'Index Bloat',
        slug: 'index-bloat',
        rationale: 'B-tree index bloat is not reclaimed by VACUUM and requires REINDEX — it silently consumes disk.',
        lookFor: 'bloat_pct_estimate > 30% on indexes > 50 MB',
        ifHot: 'REINDEX CONCURRENTLY idx_name during low traffic.',
        ifClear: 'Not index bloat. Check largest tables to find the data growth source.'
      },
      {
        sectionId: '13', sectionTitle: 'Table & Index Size Ranking',
        slug: 'table-index-size-ranking',
        rationale: 'Identify which tables are growing fastest — find the source before running out of space.',
        lookFor: 'Tables with total_size disproportionate to their row count (large TOAST or bloat)',
        ifHot: 'Check if the table needs archiving, partitioning, or a cleanup job.',
        ifClear: 'Run section 12 (TOAST bloat) — large text/JSON/JSONB columns can hide gigabytes of bloat.'
      }
    ]
  },
  {
    id: 'high-cpu',
    icon: '🔥',
    symptom: 'High CPU usage',
    trigger: 'Database server CPU pegged; load average spiking; queries slower than normal without obvious locks.',
    steps: [
      {
        sectionId: '01', sectionTitle: 'Slow / Expensive Queries',
        slug: 'slow-expensive-queries',
        rationale: 'Find which queries are consuming the most CPU cycles (total_exec_time = direct CPU proxy).',
        lookFor: 'pct_total_time > 20% for a single query shape; or sudden increase in total_exec_time',
        ifHot: 'EXPLAIN (ANALYZE, BUFFERS): look for nested loops over large sets or bad cardinality estimates.',
        ifClear: 'Load is spread thin. Check temp file spill — sort/hash ops consume heavy CPU.'
      },
      {
        sectionId: '02', sectionTitle: 'Temp File & work_mem Pressure',
        slug: 'temp-file-work-mem-pressure',
        rationale: 'Sort and hash operations that spill to disk consume both I/O and CPU for the sort merge.',
        lookFor: 'temp_written_mb > 0 aggregated across many queries',
        ifHot: 'Increase work_mem. Identify the specific query driving all the temp I/O.',
        ifClear: 'Not sort/hash spill. Check JIT overhead (PG14+) next.'
      },
      {
        sectionId: '05', sectionTitle: 'JIT Compilation Overhead',
        slug: 'jit-compilation-overhead',
        rationale: 'On PG14+, JIT can spend more time compiling than executing for high-frequency queries.',
        lookFor: 'total_jit_ms ≥ mean_exec_ms; or jit_functions > 100 calls',
        ifHot: 'SET jit = off for those queries. Or raise jit_above_cost in postgresql.conf.',
        ifClear: 'Not JIT. Check if autovacuum workers are consuming a CPU core with section 15.'
      },
      {
        sectionId: '15', sectionTitle: 'Autovacuum Worker Activity',
        slug: 'autovacuum-worker-activity',
        rationale: 'Runaway autovacuum on a heavily bloated table can saturate a CPU core.',
        lookFor: 'Multiple autovacuum workers active simultaneously; or vacuum running > 30 min on the same table',
        ifHot: 'Check section 16 (dead tuples) and section 18 (blocking long transactions). Consider throttling with autovacuum_vacuum_cost_delay.',
        ifClear: 'Not autovacuum. Check I/O stats next.'
      },
      {
        sectionId: '36', sectionTitle: 'I/O Stats by Backend (pg_stat_io)',
        slug: 'i-o-stats-by-backend-pg-stat-io',
        rationale: 'High CPU can be caused by disk page evictions and excessive page read/write overhead by backends.',
        lookFor: 'High evictions or temp relation reads/writes',
        ifHot: 'Increase shared_buffers to reduce evictions; tune work_mem to reduce temp relation I/O.',
        ifClear: 'No abnormal IO patterns. Check connection limits next.'
      }
    ]
  },
  {
    id: 'connections',
    icon: '🔌',
    symptom: 'Connection errors / exhaustion',
    trigger: '"too many connections" errors in app logs; connection pool exhausted; new app instances failing to start.',
    steps: [
      {
        sectionId: '19', sectionTitle: 'Connection Saturation',
        slug: 'connection-saturation',
        rationale: 'Get an exact breakdown of connections by state and see how close you are to max_connections.',
        lookFor: 'used_pct > 80% of max_connections; or idle_in_txn > 5',
        ifHot: 'Terminate idle/idle-in-txn connections immediately. Deploy PgBouncer in transaction mode for pooling.',
        ifClear: 'Connections look fine now — may have been a transient spike. Check idle-in-txn sessions next.'
      },
      {
        sectionId: '20', sectionTitle: 'Idle-in-Transaction',
        slug: 'idle-in-transaction',
        rationale: 'Idle-in-txn sessions hold connection slots and locks without doing any work.',
        lookFor: 'idle_duration > 30s',
        ifHot: 'Set idle_in_transaction_session_timeout = \'30s\' in postgresql.conf to auto-terminate them.',
        ifClear: 'No idle-in-txn. Check configuration for max_connections sizing.'
      },
      {
        sectionId: '29', sectionTitle: 'Key GUC Settings Review',
        slug: 'key-guc-settings-review',
        rationale: 'Verify max_connections and connection-related GUCs are sized for your actual workload.',
        lookFor: 'max_connections < pool_size + reserved_connections; missing PgBouncer in the stack',
        ifHot: 'Deploy PgBouncer. Do not simply raise max_connections — each connection costs ~5–10 MB RAM.',
        ifClear: 'Config looks reasonable. The spike was likely a deployment artifact.'
      }
    ]
  },
  {
    id: 'replication-lag',
    icon: '📡',
    symptom: 'Replication falling behind',
    trigger: 'Standby lag increasing; replica reads are stale; failover RTO/RPO targets at risk.',
    steps: [
      {
        sectionId: '23', sectionTitle: 'Streaming Replication Lag',
        slug: 'streaming-replication-lag',
        rationale: 'Get exact per-standby write/flush/replay lag and see how much WAL is unsent.',
        lookFor: 'replay_lag > 30s | flush_lag > 10s | unsent_wal > 100 MB',
        ifHot: 'Check standby server I/O performance and network throughput. Look at pg_wal_receiver_status on the standby.',
        ifClear: 'Streaming lag is fine. Check logical slots next.'
      },
      {
        sectionId: '24', sectionTitle: 'Logical Replication Slot Lag',
        slug: 'logical-replication-slot-lag',
        rationale: 'Logical consumers (CDC tools, logical replicas) can fall behind and force the primary to hold gigabytes of WAL.',
        lookFor: 'consumer_lag_size > 500 MB; or active = false with any lag > 0',
        ifHot: 'Restart the logical consumer. If it\'s gone permanently: pg_drop_replication_slot().',
        ifClear: 'No logical lag. Check overall WAL retention next.'
      },
      {
        sectionId: '25', sectionTitle: 'Replication Slot WAL Retention',
        slug: 'replication-slot-wal-retention',
        rationale: 'Total WAL held hostage by all slots — even small per-slot lags add up to disk risk.',
        lookFor: 'Any inactive slot with wal_retained > 0; total_wal_held_by_slots > 5 GB',
        ifHot: 'Drop inactive slots. For active lagging slots, investigate consumer I/O capacity and network.',
        ifClear: 'Slots are healthy. The replication lag is likely transient I/O saturation on the standby.'
      }
    ]
  },
  {
    id: 'vacuum-issues',
    icon: '🧹',
    symptom: 'Vacuum not keeping up',
    trigger: 'Dead tuple counts growing; autovacuum running constantly or skipping tables; bloat increasing on write-heavy tables.',
    steps: [
      {
        sectionId: '16', sectionTitle: 'Dead Tuple Urgency',
        slug: 'dead-tuple-urgency',
        rationale: 'Find which tables have the most dead tuples and are most at risk of bloat.',
        lookFor: 'dead_pct > 10% or n_dead_tup > 100k on frequently updated tables',
        ifHot: 'VACUUM (VERBOSE, ANALYZE) on the table. If dead tuples return immediately, there\'s a blocking transaction.',
        ifClear: 'Dead tuple counts are fine. Check for long-running transactions blocking vacuum.'
      },
      {
        sectionId: '18', sectionTitle: 'Long-Running Transactions',
        slug: 'long-running-transactions',
        rationale: 'A long-running transaction (even read-only) prevents vacuum from reclaiming any dead tuples it predates.',
        lookFor: 'Any transaction older than 5 minutes; xmin_horizon significantly behind current XID',
        ifHot: 'Terminate the long-running transaction. Vacuum will unblock immediately after.',
        ifClear: 'No blocking transactions. Check open prepared transactions next.'
      },
      {
        sectionId: '35', sectionTitle: 'Open Prepared Transactions',
        slug: 'open-prepared-transactions',
        rationale: 'Orphaned prepared transactions prevent autovacuum from freezing tables and advancing database age.',
        lookFor: 'Any prepared transaction older than 5 minutes',
        ifHot: 'Rollback or commit the prepared transaction using its GID.',
        ifClear: 'No prepared transactions blocking vacuum. Check autovacuum activity in section 15 next.'
      },
      {
        sectionId: '15', sectionTitle: 'Autovacuum Worker Activity',
        slug: 'autovacuum-worker-activity',
        rationale: 'Verify autovacuum is actually running on problem tables and isn\'t being overly throttled.',
        lookFor: 'Problem table not appearing in autovacuum_count; or last_autovacuum > 1h on a hot table',
        ifHot: 'ALTER TABLE t SET (autovacuum_vacuum_scale_factor = 0.01) to trigger more frequent vacuums.',
        ifClear: 'Autovacuum is running. It may be losing the race — check XID wraparound risk next.'
      },
      {
        sectionId: '26', sectionTitle: 'XID Wraparound Risk',
        slug: 'xid-wraparound-risk',
        rationale: 'If vacuum can\'t keep up long-term, XID age grows. Wraparound shutdown is a database emergency.',
        lookFor: 'pct_used > 70% | max_age > 1.5 billion XIDs; or autovacuum_freeze_max_age approaching for any table',
        ifHot: 'VACUUM FREEZE on the table immediately. This is P0 if max_age > 2 billion — the DB will shut itself down.',
        ifClear: 'Wraparound not at risk. Monitor the trend weekly.'
      }
    ]
  },
  {
    id: 'pre-deployment',
    icon: '🛡️',
    symptom: 'Pre-deployment health check',
    trigger: 'Before a major release, migration, or traffic ramp — verify the database is in a clean state.',
    steps: [
      {
        sectionId: '26', sectionTitle: 'XID Wraparound Risk',
        slug: 'xid-wraparound-risk',
        rationale: 'A large migration accelerates XID consumption. Verify you have ample headroom before adding load.',
        lookFor: 'pct_used < 70% (max_age < 1 billion XIDs for all tables)',
        ifHot: 'VACUUM FREEZE before the deployment. Do not proceed if any table shows emergency autovacuum mode.',
        ifClear: 'XID headroom is sufficient. Continue.'
      },
      {
        sectionId: '25', sectionTitle: 'Replication Slot WAL Retention',
        slug: 'replication-slot-wal-retention',
        rationale: 'A deployment spike accelerates WAL generation. Stale slots will cause disk exhaustion during the migration.',
        lookFor: 'No inactive slots; active slots with lag < 100 MB',
        ifHot: 'Drop inactive slots before proceeding. Do not run a WAL-heavy migration with lagging slots.',
        ifClear: 'Slots are healthy. Continue.'
      },
      {
        sectionId: '19', sectionTitle: 'Connection Saturation',
        slug: 'connection-saturation',
        rationale: 'Verify you have connection headroom before deployment adds migration workers and new app instances.',
        lookFor: 'used_pct < 60% — leave room for migration workers',
        ifHot: 'Terminate idle connections before deploying. Scale down non-critical consumers first.',
        ifClear: 'Connections have headroom. Continue.'
      },
      {
        sectionId: '08', sectionTitle: 'Invalid Indexes',
        slug: 'invalid-indexes',
        rationale: 'A previous failed migration may have left invalid indexes. New deployments often add migrations that conflict.',
        lookFor: 'Any index with indisvalid = false',
        ifHot: 'DROP and REINDEX CONCURRENTLY those indexes before the new migration runs.',
        ifClear: 'No invalid indexes. Continue.'
      },
      {
        sectionId: '32', sectionTitle: 'Database-Level Summary',
        slug: 'database-level-summary',
        rationale: 'Capture your baseline: cache hit ratio, transaction rate, connection count. Diff against post-deployment to spot regressions instantly.',
        lookFor: 'cache_hit_ratio > 97%; no anomalies vs your normal baseline numbers',
        ifHot: 'Investigate before deploying — something is already degraded.',
        ifClear: 'Baseline looks good. Record these numbers. Run again post-deployment and compare.'
      }
    ]
  }
];
