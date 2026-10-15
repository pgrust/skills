-- pgrust-workload: read-only collection script for PostgreSQL 12 or newer (psql 12 or newer).
--
-- What it reads: Postgres's own catalogs and statistics views (pg_class, pg_attribute,
-- pg_index, pg_constraint, pg_stats [shape columns only], pg_stat_user_tables,
-- pg_stat_statements). It never selects rows from your tables.
--
-- What it never reads: table rows; pg_stats value columns (most_common_vals,
-- histogram_bounds, most_common_elems); pg_stat_activity (live queries carry real values);
-- function or trigger bodies; roles or passwords; server logs.
--
-- Email-shaped strings inside definitions (views, indexes, constraints, defaults) are
-- replaced with <email> here, before anything is written to disk.
--
-- Guards: everything runs in ONE transaction opened READ ONLY, with
-- statement_timeout 30s and lock_timeout 2s, and the script ends with ROLLBACK.
-- If the transaction does not report read-only, the script stops before any query.
-- Building DDL text briefly takes and immediately releases a shared lock on each table
-- (the same lock a SELECT takes); if a table is locked by a migration, that statement
-- gives up after 2s and the script carries on.
--
-- Run it from inside the output folder, so the files land there:
--   cd pgrust-workload/db && psql "$PGRUST_DB_URL" -X -q -f <path-to>/collect.sql
-- Output: 00_session.csv ... 13_pgss_info.csv, plus schema_from_db.sql.

\set ON_ERROR_STOP off
\set ON_ERROR_ROLLBACK on
\pset pager off
\pset format csv

BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '2s';
SET LOCAL idle_in_transaction_session_timeout = '120s';
SET LOCAL application_name = 'pgrust-workload-readonly';

-- Stop before reading anything if the guard did not take effect.
SELECT current_setting('transaction_read_only') = 'on' AS ro_ok,
       current_setting('server_version_num')::int >= 130000 AS pg13plus,
       current_setting('server_version_num')::int >= 140000 AS pg14plus \gset
\if :ro_ok
\else
  \echo 'STOP: the transaction is not read-only. Nothing was collected.'
  \quit
\endif

-- 00: proof the guard was on, and whether this server is a replica.
\o 00_session.csv
SELECT current_setting('transaction_read_only') AS transaction_read_only,
       current_setting('statement_timeout') AS statement_timeout,
       current_setting('lock_timeout') AS lock_timeout,
       pg_is_in_recovery() AS is_replica,
       current_setting('server_version') AS server_version,
       now() AS collected_at;

-- 01: version string.
\o 01_version.csv
SELECT version() AS version;

-- 02: planner and memory settings that change benchmark results.
\o 02_settings.csv
SELECT name, setting, unit, source
FROM pg_settings
WHERE name IN (
  'server_version', 'max_connections', 'shared_buffers', 'effective_cache_size',
  'work_mem', 'maintenance_work_mem', 'random_page_cost', 'seq_page_cost',
  'effective_io_concurrency', 'default_statistics_target', 'jit',
  'max_parallel_workers_per_gather', 'max_parallel_workers', 'max_worker_processes',
  'wal_level', 'synchronous_commit', 'shared_preload_libraries', 'track_io_timing',
  'pg_stat_statements.track', 'pg_stat_statements.max', 'autovacuum', 'huge_pages',
  'checkpoint_timeout', 'max_wal_size', 'default_toast_compression', 'block_size',
  'plan_cache_mode', 'server_encoding', 'TimeZone', 'enable_partitionwise_join',
  'enable_partitionwise_aggregate', 'from_collapse_limit', 'join_collapse_limit')
ORDER BY name;

-- 03: installed extensions.
\o 03_extensions.csv
SELECT e.extname, e.extversion, n.nspname AS schema
FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
ORDER BY e.extname;

-- 04: object counts and database size.
\o 04_database.csv
SELECT pg_database_size(current_database()) AS database_bytes,
       (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind IN ('r', 'p') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
           AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp%') AS tables,
       (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind IN ('i', 'I') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
           AND n.nspname NOT LIKE 'pg\_toast%') AS indexes,
       (SELECT count(*) FROM pg_namespace n
         WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
           AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp%') AS schemas;

-- 05: tables: estimated rows and sizes from the catalog (no table scans, no table locks),
--     plus activity counters that show which tables are hot. Largest 500.
\o 05_tables.csv
SELECT n.nspname AS schema, c.relname AS table_name, c.relkind, c.relispartition AS is_partition,
       greatest(c.reltuples, 0)::bigint AS est_rows,
       c.relpages::bigint * current_setting('block_size')::int AS approx_heap_bytes,
       coalesce(t.relpages, 0)::bigint * current_setting('block_size')::int AS approx_toast_bytes,
       (SELECT coalesce(sum(ic.relpages), 0)::bigint * current_setting('block_size')::int
          FROM pg_index ix JOIN pg_class ic ON ic.oid = ix.indexrelid
         WHERE ix.indrelid = c.oid) AS approx_index_bytes,
       s.seq_scan, s.seq_tup_read, s.idx_scan, s.idx_tup_fetch,
       s.n_tup_ins, s.n_tup_upd, s.n_tup_hot_upd, s.n_tup_del,
       s.n_live_tup, s.n_dead_tup, s.last_autovacuum, s.last_autoanalyze
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_class t ON t.oid = c.reltoastrelid
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relkind IN ('r', 'p', 'm')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp%'
ORDER BY c.relpages DESC, n.nspname, c.relname
LIMIT 500;

-- 06: indexes with definitions, approximate size and how often each is used.
\o 06_indexes.csv
SELECT n.nspname AS schema, t.relname AS table_name, i.relname AS index_name,
       regexp_replace(pg_get_indexdef(i.oid), '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}', '<email>', 'g') AS definition,
       ix.indisunique AS is_unique, ix.indisprimary AS is_primary, ix.indisvalid AS is_valid,
       i.relpages::bigint * current_setting('block_size')::int AS approx_bytes,
       s.idx_scan, s.idx_tup_read, s.idx_tup_fetch
FROM pg_index ix
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_class t ON t.oid = ix.indrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
LEFT JOIN pg_stat_user_indexes s ON s.indexrelid = ix.indexrelid
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp%'
ORDER BY n.nspname, t.relname, i.relname;

-- 07: constraints (primary keys, foreign keys, unique, check).
\o 07_constraints.csv
SELECT n.nspname AS schema, c.relname AS table_name, con.conname AS constraint_name,
       con.contype AS type, regexp_replace(pg_get_constraintdef(con.oid), '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}', '<email>', 'g') AS definition
FROM pg_constraint con
JOIN pg_class c ON c.oid = con.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg\_toast%'
ORDER BY n.nspname, c.relname, con.conname;

-- 08: column statistics SHAPE only: how many distinct values, how many nulls, average width,
--     physical ordering. These are numbers, not values. Value columns are never selected.
\o 08_column_stats.csv
SELECT schemaname AS schema, tablename AS table_name, attname AS column_name,
       null_frac, avg_width, n_distinct, correlation
FROM pg_stats
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  AND schemaname NOT LIKE 'pg\_toast%'
ORDER BY schemaname, tablename, attname;

-- 09: view definitions (needed to benchmark queries that read views).
\o 09_views.csv
SELECT n.nspname AS schema, c.relname AS view_name, c.relkind,
       regexp_replace(pg_get_viewdef(c.oid, true), '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}', '<email>', 'g') AS definition
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('v', 'm')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg\_toast%'
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass
                    AND d.objid = c.oid AND d.deptype = 'e')
ORDER BY n.nspname, c.relname;

-- 10: functions and triggers, by NAME only. Bodies are not collected (they can hold keys).
\o 10_functions_triggers.csv
SELECT 'function' AS kind, n.nspname AS schema, p.proname AS name, l.lanname AS detail
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_language l ON l.oid = p.prolang
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
UNION ALL
SELECT 'trigger', n.nspname, tg.tgname, c.relname
FROM pg_trigger tg
JOIN pg_class c ON c.oid = tg.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT tg.tgisinternal
ORDER BY 1, 2, 3;

-- 11: top queries from pg_stat_statements, if it is installed. Values already show as $1, $2.
--     Only SELECT/INSERT/UPDATE/DELETE/MERGE/WITH statements are kept; utility statements
--     (ALTER ROLE ... PASSWORD and the like) are dropped. SQL comments are stripped,
--     because some apps put user info in them.
SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') AS has_pgss \gset
\if :has_pgss
  SELECT n.nspname AS pgss_schema
  FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
  WHERE e.extname = 'pg_stat_statements' \gset
  \o 11_top_queries.csv
  \if :pg13plus
    SELECT queryid, calls,
           round(total_exec_time::numeric, 1) AS total_ms,
           round(mean_exec_time::numeric, 2) AS mean_ms,
           round(stddev_exec_time::numeric, 2) AS stddev_ms,
           round(max_exec_time::numeric, 1) AS max_ms,
           rows, shared_blks_hit, shared_blks_read, temp_blks_written,
           regexp_replace(query, '/\*.*?\*/', '', 'g') AS query
    FROM :"pgss_schema".pg_stat_statements
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
      AND query ~* '^\s*(/\*.*?\*/\s*)*(select|insert|update|delete|merge|with)\M'
      AND NOT query ~* '(pg_catalog|information_schema|pg_stat_statements|pg_stat_|set_config|pg_get_)'
    ORDER BY total_exec_time DESC
    LIMIT 100;
  \else
    SELECT queryid, calls,
           round(total_time::numeric, 1) AS total_ms,
           round(mean_time::numeric, 2) AS mean_ms,
           round(stddev_time::numeric, 2) AS stddev_ms,
           round(max_time::numeric, 1) AS max_ms,
           rows, shared_blks_hit, shared_blks_read, temp_blks_written,
           regexp_replace(query, '/\*.*?\*/', '', 'g') AS query
    FROM :"pgss_schema".pg_stat_statements
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
      AND query ~* '^\s*(/\*.*?\*/\s*)*(select|insert|update|delete|with)\M'
      AND NOT query ~* '(pg_catalog|information_schema|pg_stat_statements|pg_stat_|set_config|pg_get_)'
    ORDER BY total_time DESC
    LIMIT 100;
  \endif
  \o 12_pgss_visibility.csv
  SELECT count(*) AS statements_total,
         count(*) FILTER (WHERE query = '<insufficient privilege>') AS hidden_from_this_login
  FROM :"pgss_schema".pg_stat_statements;
  \if :pg14plus
    \o 13_pgss_info.csv
    SELECT dealloc, stats_reset FROM :"pgss_schema".pg_stat_statements_info;
  \endif
\else
  \o 11_top_queries.csv
  SELECT 'pg_stat_statements is not installed in this database' AS note;
\endif

-- schema_from_db.sql: CREATE TABLE statements rebuilt from the catalog (columns, types,
-- NOT NULL, defaults, partitioning). Constraints and indexes are in 06 and 07.
\pset format unaligned
\pset tuples_only on
\o schema_from_db.sql
SELECT '-- Rebuilt from the catalog by pgrust-workload collect.sql. Constraints: 07_constraints.csv. Indexes: 06_indexes.csv.';
SELECT CASE
         WHEN c.relispartition THEN
           format('CREATE TABLE %I.%I PARTITION OF %s %s;', n.nspname, c.relname,
                  (SELECT inhparent::regclass::text FROM pg_inherits WHERE inhrelid = c.oid LIMIT 1),
                  pg_get_expr(c.relpartbound, c.oid))
         ELSE
           format(E'CREATE TABLE %I.%I (\n%s\n)%s;', n.nspname, c.relname,
                  (SELECT string_agg(
                            format('  %I %s%s%s', a.attname, format_type(a.atttypid, a.atttypmod),
                                   CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END,
                                   CASE WHEN d.adbin IS NOT NULL AND a.attgenerated = ''
                                        THEN ' DEFAULT ' || regexp_replace(pg_get_expr(d.adbin, d.adrelid), '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}', '<email>', 'g') ELSE '' END),
                            E',\n' ORDER BY a.attnum)
                     FROM pg_attribute a
                     LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                    WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped),
                  CASE WHEN c.relkind = 'p' THEN ' PARTITION BY ' || pg_get_partkeydef(c.oid) ELSE '' END)
       END
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp%'
ORDER BY c.relispartition, n.nspname, c.relname;

\o
ROLLBACK;
\echo 'pgrust-workload collect.sql finished. Read-only transaction rolled back.'
