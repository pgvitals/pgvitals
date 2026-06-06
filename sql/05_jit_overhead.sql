-- ============================================================
-- 05 · JIT COMPILATION OVERHEAD
-- ============================================================
-- What    : Queries where JIT compilation cost exceeds its benefit
-- Look for: total_jit_ms close to or greater than mean_exec_ms
-- Action  : SET jit = off for the session; raise jit_above_cost
--           in postgresql.conf; or restructure the query
-- Requires: pg_stat_statements, PostgreSQL 11+
-- ============================================================

SELECT
    calls,
    round(mean_exec_time::numeric, 2)                                   AS mean_exec_ms,
    jit_functions,
    round(jit_generation_time::numeric, 2)                              AS jit_gen_ms,
    round(jit_inlining_time::numeric, 2)                                AS jit_inline_ms,
    round(jit_optimization_time::numeric, 2)                            AS jit_opt_ms,
    round(jit_emission_time::numeric, 2)                                AS jit_emit_ms,
    round((jit_generation_time + jit_inlining_time
           + jit_optimization_time + jit_emission_time)::numeric, 2)   AS total_jit_ms,
    left(query, 200)                                                     AS query_snippet
FROM pg_stat_statements
WHERE jit_functions > 0
ORDER BY jit_generation_time + jit_inlining_time
         + jit_optimization_time + jit_emission_time DESC
LIMIT 15;
