-- pgrust-workload: read-only collection script for ClickHouse 24.8 or newer (clickhouse client).
--
-- What it reads: ClickHouse's own system tables (system.tables, system.columns, system.parts,
-- system.query_log, system.part_log, system.settings and a few more). It never selects rows
-- from your tables.
--
-- What it never reads: table rows; raw query text (query_log text goes through normalizeQuery(),
-- which replaces every literal with ?, and only for the top queries); exception messages;
-- users, client addresses or hostnames; definitions of tables whose engine connects to another
-- system (Kafka, S3, PostgreSQL, MySQL, URL and so on), which can carry hosts and keys;
-- dictionary sources; function bodies; table and column comments.
--
-- Email-shaped strings inside definitions (DEFAULT expressions, view queries, settings) are
-- replaced with <email> here, before anything is written to disk.
--
-- Guards: the command line sets readonly=1 (the server refuses writes, DDL and SET) and
-- max_execution_time=30 for every query. Each result is written with INTO OUTFILE, which the
-- client does on your machine, and which never overwrites an existing file.
-- Logs that live on each replica (query_log, part_log, asynchronous_insert_log) and part sizes
-- are read across the cluster named 'default' first, which is what ClickHouse Cloud needs.
-- If there is no such cluster, the query fails without writing anything, and the next query
-- reads this server only and writes the same file. The `source` column says which one ran.
-- query_log, part_log and asynchronous_insert_log are read for the last 7 days only.
--
-- Run it from inside the output folder (the bundle folder outside the repo), so the files land there:
--   mkdir -p ~/pgrust-workload/<repo>-<YYYYMMDD>/clickhouse && cd ~/pgrust-workload/<repo>-<YYYYMMDD>/clickhouse && clickhouse client --readonly=1 --max_execution_time=30 --ignore-error --multiquery < <path-to>/collect_clickhouse.sql
-- Connection: CLICKHOUSE_HOST/CLICKHOUSE_USER/CLICKHOUSE_PASSWORD in the environment, or --connection NAME.
-- If the login is already read-only, see references/clickhouse.md for the two variants.
-- Output: 00_session.csv ... 17_kafka_consumers.csv, plus schema_from_db.sql.
-- A missing file means that query failed (for example, part_log is not enabled); the error is on screen.

-- 00: proof the guard was on, version, uptime, and whether a cluster named 'default' exists.
SELECT getSetting('readonly') AS readonly,
       getSetting('max_execution_time') AS max_execution_time,
       version() AS version,
       uptime() AS uptime_seconds,
       now() AS collected_at,
       (SELECT count() FROM system.clusters WHERE cluster = 'default') AS default_cluster_replicas,
       (SELECT uniqExact(shard_num) FROM system.clusters WHERE cluster = 'default') AS default_cluster_shards
INTO OUTFILE '00_session.csv' FORMAT CSVWithNames;

-- 01: settings that differ from the defaults, plus ones that change benchmark results.
--     readonly and max_execution_time show as changed because the command line sets them.
SELECT name,
       replaceRegexpAll(value, '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}', '<email>') AS value,
       changed, type
FROM system.settings
WHERE changed
   OR name LIKE 'async_insert%'
   OR name IN ('max_threads', 'max_memory_usage', 'max_bytes_before_external_group_by',
               'max_bytes_before_external_sort', 'join_algorithm', 'max_block_size',
               'max_insert_block_size', 'min_insert_block_size_rows', 'min_insert_block_size_bytes',
               'wait_for_async_insert', 'use_query_cache', 'use_uncompressed_cache',
               'enable_analyzer', 'allow_experimental_analyzer', 'optimize_read_in_order',
               'max_parallel_replicas', 'enable_parallel_replicas', 'prefer_localhost_replica',
               'distributed_product_mode', 'insert_quorum', 'mutations_sync', 'lightweight_deletes_sync')
ORDER BY name
INTO OUTFILE '01_settings.csv' FORMAT CSVWithNames;

-- 02: server-wide sizing: a short list of server settings, and memory/CPU where the server reports them.
SELECT kind, name, value FROM (
SELECT 'server_setting' AS kind, name, value
FROM system.server_settings
WHERE name IN ('max_server_memory_usage', 'max_server_memory_usage_to_ram_ratio',
               'max_concurrent_queries', 'background_pool_size',
               'background_merges_mutations_concurrency_ratio', 'background_schedule_pool_size',
               'mark_cache_size', 'uncompressed_cache_size', 'max_thread_pool_size',
               'async_insert_threads')
UNION ALL
SELECT 'metric', metric, toString(value)
FROM system.asynchronous_metrics
WHERE metric IN ('OSMemoryTotal', 'CGroupMemoryTotal', 'CGroupMaxCPU', 'NumberOfCPUCores',
                 'NumberOfPhysicalCPUCores'))
ORDER BY kind, name
INTO OUTFILE '02_server.csv' FORMAT CSVWithNames;

-- 03: databases and their engines (engine name only; database engine arguments can hold hosts and passwords).
SELECT name AS database, engine
FROM system.databases
WHERE name NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY name
INTO OUTFILE '03_databases.csv' FORMAT CSVWithNames;

-- 04: tables: engine, keys, row and byte counts from metadata (no table is scanned), and which
--     materialized views read from each table. engine_full is kept only for engines that store
--     data in ClickHouse; for engines that connect elsewhere it is '<omitted>'.
SELECT database, name AS table_name, engine,
       if(match(engine, 'MergeTree$') OR engine IN ('View', 'MaterializedView', 'Distributed', 'Buffer', 'Merge', 'Memory',
                                                    'Null', 'Set', 'Join', 'Log', 'TinyLog', 'StripeLog', 'EmbeddedRocksDB', 'KeeperMap'),
          replaceRegexpAll(engine_full, '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}', '<email>'),
          '<omitted>') AS engine_full,
       partition_key, sorting_key, primary_key, sampling_key, storage_policy,
       total_rows, total_bytes, parts, active_parts, total_marks,
       arrayStringConcat(arrayMap((d, t) -> concat(d, '.', t), dependencies_database, dependencies_table), ' ') AS read_by_views
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
  AND NOT is_temporary
ORDER BY total_bytes DESC NULLS LAST, database, name
LIMIT 2000
INTO OUTFILE '04_tables.csv' FORMAT CSVWithNames;

-- 05: columns: types, codecs, DEFAULT/MATERIALIZED/ALIAS expressions, key membership and
--     compressed/uncompressed size per column. Column comments are not collected.
SELECT database, table AS table_name, name AS column_name, type, position, default_kind,
       replaceRegexpAll(default_expression, '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}', '<email>') AS default_expression,
       compression_codec, is_in_partition_key, is_in_sorting_key, is_in_primary_key, is_in_sampling_key,
       data_compressed_bytes, data_uncompressed_bytes, marks_bytes
FROM system.columns
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY database, table, position
LIMIT 100000
INTO OUTFILE '05_columns.csv' FORMAT CSVWithNames;

-- 06: data volume per table from active parts: rows, compressed and uncompressed bytes, part
--     and partition counts. cluster('default', ...) reads one replica per shard, so a sharded
--     cluster is summed once; the second query is the single-server fallback.
SELECT 'cluster default' AS source, database, table AS table_name,
       count() AS active_parts, uniqExact(partition_id) AS partitions, sum(rows) AS total_rows,
       sum(bytes_on_disk) AS total_bytes_on_disk, sum(data_compressed_bytes) AS compressed_bytes,
       sum(data_uncompressed_bytes) AS uncompressed_bytes,
       sum(primary_key_bytes_in_memory) AS total_primary_key_bytes_in_memory,
       round(avg(rows)) AS mean_rows_per_part, countIf(part_type = 'Compact') AS compact_parts,
       arrayStringConcat(groupUniqArray(disk_name), ' ') AS disks
FROM cluster('default', system.parts)
WHERE active AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table
ORDER BY total_bytes_on_disk DESC
LIMIT 2000
INTO OUTFILE '06_parts.csv' FORMAT CSVWithNames;

SELECT 'this server' AS source, database, table AS table_name,
       count() AS active_parts, uniqExact(partition_id) AS partitions, sum(rows) AS total_rows,
       sum(bytes_on_disk) AS total_bytes_on_disk, sum(data_compressed_bytes) AS compressed_bytes,
       sum(data_uncompressed_bytes) AS uncompressed_bytes,
       sum(primary_key_bytes_in_memory) AS total_primary_key_bytes_in_memory,
       round(avg(rows)) AS mean_rows_per_part, countIf(part_type = 'Compact') AS compact_parts,
       arrayStringConcat(groupUniqArray(disk_name), ' ') AS disks
FROM system.parts
WHERE active AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table
ORDER BY total_bytes_on_disk DESC
LIMIT 2000
INTO OUTFILE '06_parts.csv' FORMAT CSVWithNames;

-- 07: data-skipping indexes.
SELECT database, table AS table_name, name AS index_name, type,
       replaceRegexpAll(expr, '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}', '<email>') AS expr,
       granularity, data_compressed_bytes, data_uncompressed_bytes
FROM system.data_skipping_indices
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
ORDER BY database, table, name
INTO OUTFILE '07_skipping_indices.csv' FORMAT CSVWithNames;

-- 08: projections that have data, with their size. Their definitions are in schema_from_db.sql.
SELECT database, table AS table_name, name AS projection_name,
       count() AS parts, sum(rows) AS total_rows, sum(bytes_on_disk) AS total_bytes_on_disk
FROM system.projection_parts
WHERE active AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table, name
ORDER BY database, table, name
INTO OUTFILE '08_projections.csv' FORMAT CSVWithNames;

-- 09: dictionaries: layout, key and attribute names and types, size. The source (which can
--     name a host, user and table elsewhere) and error text are not collected.
SELECT database, name AS dictionary_name, status, type AS layout,
       arrayStringConcat(`key.names`, ' ') AS key_names, arrayStringConcat(`key.types`, ' ') AS key_types,
       arrayStringConcat(`attribute.names`, ' ') AS attribute_names,
       arrayStringConcat(`attribute.types`, ' ') AS attribute_types,
       element_count, bytes_allocated, query_count, lifetime_min, lifetime_max
FROM system.dictionaries
ORDER BY database, name
INTO OUTFILE '09_dictionaries.csv' FORMAT CSVWithNames;

-- 10: user-defined functions, by NAME only. Bodies are not collected.
SELECT name, origin
FROM system.functions
WHERE origin != 'System'
ORDER BY name
INTO OUTFILE '10_functions.csv' FORMAT CSVWithNames;

-- 11, 12: top queries from query_log over 7 days, grouped by normalized_query_hash, by total
--     time and by count. Only finished or failed SELECT/INSERT/DELETE/UPDATE initial queries
--     that touch a non-system table. No query text here: it is in 13, joined on query_hash.
SELECT 'all replicas' AS source, concat('h', lower(hex(normalized_query_hash))) AS query_hash, query_kind,
       countIf(type = 'QueryFinish') AS calls, countIf(type != 'QueryFinish') AS errors,
       sum(query_duration_ms) AS total_ms, round(avg(query_duration_ms), 1) AS mean_ms,
       round(quantile(0.5)(query_duration_ms), 1) AS p50_ms, round(quantile(0.95)(query_duration_ms), 1) AS p95_ms,
       max(query_duration_ms) AS max_ms,
       sum(read_rows) AS total_read_rows, sum(read_bytes) AS total_read_bytes,
       round(avg(read_rows)) AS mean_read_rows, round(avg(result_rows), 1) AS mean_result_rows,
       round(avg(memory_usage)) AS mean_memory_bytes, max(memory_usage) AS max_memory_bytes,
       arrayStringConcat(groupUniqArrayArray(10)(tables), ' ') AS tables,
       min(event_time) AS first_seen, max(event_time) AS last_seen
FROM clusterAllReplicas('default', system.query_log)
WHERE event_date >= today() - 7 AND event_time >= now() - INTERVAL 7 DAY
  AND type IN ('QueryFinish', 'ExceptionWhileProcessing') AND is_initial_query
  AND query_kind IN ('Select', 'Insert', 'Delete', 'Update')
  AND NOT arrayAll(d -> d IN ('system', 'information_schema', 'INFORMATION_SCHEMA', '_table_function', '_temporary_and_external_tables'), databases)
GROUP BY normalized_query_hash, query_kind
ORDER BY total_ms DESC
LIMIT 100
INTO OUTFILE '11_top_queries_by_time.csv' FORMAT CSVWithNames;

SELECT 'this server' AS source, concat('h', lower(hex(normalized_query_hash))) AS query_hash, query_kind,
       countIf(type = 'QueryFinish') AS calls, countIf(type != 'QueryFinish') AS errors,
       sum(query_duration_ms) AS total_ms, round(avg(query_duration_ms), 1) AS mean_ms,
       round(quantile(0.5)(query_duration_ms), 1) AS p50_ms, round(quantile(0.95)(query_duration_ms), 1) AS p95_ms,
       max(query_duration_ms) AS max_ms,
       sum(read_rows) AS total_read_rows, sum(read_bytes) AS total_read_bytes,
       round(avg(read_rows)) AS mean_read_rows, round(avg(result_rows), 1) AS mean_result_rows,
       round(avg(memory_usage)) AS mean_memory_bytes, max(memory_usage) AS max_memory_bytes,
       arrayStringConcat(groupUniqArrayArray(10)(tables), ' ') AS tables,
       min(event_time) AS first_seen, max(event_time) AS last_seen
FROM system.query_log
WHERE event_date >= today() - 7 AND event_time >= now() - INTERVAL 7 DAY
  AND type IN ('QueryFinish', 'ExceptionWhileProcessing') AND is_initial_query
  AND query_kind IN ('Select', 'Insert', 'Delete', 'Update')
  AND NOT arrayAll(d -> d IN ('system', 'information_schema', 'INFORMATION_SCHEMA', '_table_function', '_temporary_and_external_tables'), databases)
GROUP BY normalized_query_hash, query_kind
ORDER BY total_ms DESC
LIMIT 100
INTO OUTFILE '11_top_queries_by_time.csv' FORMAT CSVWithNames;

SELECT 'all replicas' AS source, concat('h', lower(hex(normalized_query_hash))) AS query_hash, query_kind,
       countIf(type = 'QueryFinish') AS calls, countIf(type != 'QueryFinish') AS errors,
       sum(query_duration_ms) AS total_ms, round(avg(query_duration_ms), 1) AS mean_ms,
       round(quantile(0.5)(query_duration_ms), 1) AS p50_ms, round(quantile(0.95)(query_duration_ms), 1) AS p95_ms,
       max(query_duration_ms) AS max_ms,
       sum(read_rows) AS total_read_rows, sum(read_bytes) AS total_read_bytes,
       round(avg(read_rows)) AS mean_read_rows, round(avg(result_rows), 1) AS mean_result_rows,
       round(avg(memory_usage)) AS mean_memory_bytes, max(memory_usage) AS max_memory_bytes,
       arrayStringConcat(groupUniqArrayArray(10)(tables), ' ') AS tables,
       min(event_time) AS first_seen, max(event_time) AS last_seen
FROM clusterAllReplicas('default', system.query_log)
WHERE event_date >= today() - 7 AND event_time >= now() - INTERVAL 7 DAY
  AND type IN ('QueryFinish', 'ExceptionWhileProcessing') AND is_initial_query
  AND query_kind IN ('Select', 'Insert', 'Delete', 'Update')
  AND NOT arrayAll(d -> d IN ('system', 'information_schema', 'INFORMATION_SCHEMA', '_table_function', '_temporary_and_external_tables'), databases)
GROUP BY normalized_query_hash, query_kind
ORDER BY calls DESC
LIMIT 100
INTO OUTFILE '12_top_queries_by_count.csv' FORMAT CSVWithNames;

SELECT 'this server' AS source, concat('h', lower(hex(normalized_query_hash))) AS query_hash, query_kind,
       countIf(type = 'QueryFinish') AS calls, countIf(type != 'QueryFinish') AS errors,
       sum(query_duration_ms) AS total_ms, round(avg(query_duration_ms), 1) AS mean_ms,
       round(quantile(0.5)(query_duration_ms), 1) AS p50_ms, round(quantile(0.95)(query_duration_ms), 1) AS p95_ms,
       max(query_duration_ms) AS max_ms,
       sum(read_rows) AS total_read_rows, sum(read_bytes) AS total_read_bytes,
       round(avg(read_rows)) AS mean_read_rows, round(avg(result_rows), 1) AS mean_result_rows,
       round(avg(memory_usage)) AS mean_memory_bytes, max(memory_usage) AS max_memory_bytes,
       arrayStringConcat(groupUniqArrayArray(10)(tables), ' ') AS tables,
       min(event_time) AS first_seen, max(event_time) AS last_seen
FROM system.query_log
WHERE event_date >= today() - 7 AND event_time >= now() - INTERVAL 7 DAY
  AND type IN ('QueryFinish', 'ExceptionWhileProcessing') AND is_initial_query
  AND query_kind IN ('Select', 'Insert', 'Delete', 'Update')
  AND NOT arrayAll(d -> d IN ('system', 'information_schema', 'INFORMATION_SCHEMA', '_table_function', '_temporary_and_external_tables'), databases)
GROUP BY normalized_query_hash, query_kind
ORDER BY calls DESC
LIMIT 100
INTO OUTFILE '12_top_queries_by_count.csv' FORMAT CSVWithNames;

-- 13: one normalized text per top query, from its latest run. normalizeQuery() replaces every
--     literal with ? and drops comments. For INSERTs, anything after FORMAT or VALUES is cut
--     first. The text column is read only for those latest runs, not for the whole log.
SELECT 'all replicas' AS source, concat('h', lower(hex(normalized_query_hash))) AS query_hash,
       substring(normalizeQuery(replaceRegexpOne(any(query), '(?is)\\b(FORMAT|VALUES)\\b.*$', '\\1 ...')), 1, 20000) AS normalized_query
FROM clusterAllReplicas('default', system.query_log)
WHERE event_date >= today() - 7
  AND type IN ('QueryFinish', 'ExceptionWhileProcessing') AND is_initial_query
  AND (normalized_query_hash, event_time) GLOBAL IN (
    SELECT normalized_query_hash, max(event_time)
    FROM clusterAllReplicas('default', system.query_log)
    WHERE event_date >= today() - 7 AND event_time >= now() - INTERVAL 7 DAY
      AND type IN ('QueryFinish', 'ExceptionWhileProcessing') AND is_initial_query
      AND query_kind IN ('Select', 'Insert', 'Delete', 'Update')
      AND NOT arrayAll(d -> d IN ('system', 'information_schema', 'INFORMATION_SCHEMA', '_table_function', '_temporary_and_external_tables'), databases)
    GROUP BY normalized_query_hash
    ORDER BY sum(query_duration_ms) DESC
    LIMIT 100
    UNION ALL
    SELECT normalized_query_hash, max(event_time)
    FROM clusterAllReplicas('default', system.query_log)
    WHERE event_date >= today() - 7 AND event_time >= now() - INTERVAL 7 DAY
      AND type IN ('QueryFinish', 'ExceptionWhileProcessing') AND is_initial_query
      AND query_kind IN ('Select', 'Insert', 'Delete', 'Update')
      AND NOT arrayAll(d -> d IN ('system', 'information_schema', 'INFORMATION_SCHEMA', '_table_function', '_temporary_and_external_tables'), databases)
    GROUP BY normalized_query_hash
    ORDER BY count() DESC
    LIMIT 100)
GROUP BY normalized_query_hash
INTO OUTFILE '13_query_texts.csv' FORMAT CSVWithNames;

SELECT 'this server' AS source, concat('h', lower(hex(normalized_query_hash))) AS query_hash,
       substring(normalizeQuery(replaceRegexpOne(any(query), '(?is)\\b(FORMAT|VALUES)\\b.*$', '\\1 ...')), 1, 20000) AS normalized_query
FROM system.query_log
WHERE event_date >= today() - 7
  AND type IN ('QueryFinish', 'ExceptionWhileProcessing') AND is_initial_query
  AND (normalized_query_hash, event_time) IN (
    SELECT normalized_query_hash, max(event_time)
    FROM system.query_log
    WHERE event_date >= today() - 7 AND event_time >= now() - INTERVAL 7 DAY
      AND type IN ('QueryFinish', 'ExceptionWhileProcessing') AND is_initial_query
      AND query_kind IN ('Select', 'Insert', 'Delete', 'Update')
      AND NOT arrayAll(d -> d IN ('system', 'information_schema', 'INFORMATION_SCHEMA', '_table_function', '_temporary_and_external_tables'), databases)
    GROUP BY normalized_query_hash
    ORDER BY sum(query_duration_ms) DESC
    LIMIT 100
    UNION ALL
    SELECT normalized_query_hash, max(event_time)
    FROM system.query_log
    WHERE event_date >= today() - 7 AND event_time >= now() - INTERVAL 7 DAY
      AND type IN ('QueryFinish', 'ExceptionWhileProcessing') AND is_initial_query
      AND query_kind IN ('Select', 'Insert', 'Delete', 'Update')
      AND NOT arrayAll(d -> d IN ('system', 'information_schema', 'INFORMATION_SCHEMA', '_table_function', '_temporary_and_external_tables'), databases)
    GROUP BY normalized_query_hash
    ORDER BY count() DESC
    LIMIT 100)
GROUP BY normalized_query_hash
INTO OUTFILE '13_query_texts.csv' FORMAT CSVWithNames;

-- 14: ingestion from query_log: inserts per target table over 7 days, rows per insert, and
--     whether async_insert was set on the query. AsyncInsertFlush rows are the server's flushes.
SELECT 'all replicas' AS source, arrayStringConcat(tables, ' ') AS tables, query_kind,
       Settings['async_insert'] AS async_insert_setting,
       count() AS inserts,
       round(count() / greatest(1, dateDiff('hour', min(event_time), max(event_time))), 1) AS inserts_per_hour,
       sum(written_rows) AS total_written_rows, round(avg(written_rows)) AS mean_rows_per_insert,
       round(quantile(0.5)(written_rows)) AS p50_rows_per_insert, max(written_rows) AS max_rows_per_insert,
       sum(written_bytes) AS total_written_bytes, round(avg(query_duration_ms), 1) AS mean_ms,
       arrayStringConcat(groupUniqArray(toString(interface)), ' ') AS interfaces,
       arrayStringConcat(groupUniqArrayIf(5)(client_name, client_name != ''), ' | ') AS client_names
FROM clusterAllReplicas('default', system.query_log)
WHERE event_date >= today() - 7 AND event_time >= now() - INTERVAL 7 DAY
  AND type = 'QueryFinish' AND is_initial_query
  AND query_kind IN ('Insert', 'AsyncInsertFlush')
GROUP BY tables, query_kind, async_insert_setting
ORDER BY total_written_rows DESC
LIMIT 500
INTO OUTFILE '14_inserts.csv' FORMAT CSVWithNames;

SELECT 'this server' AS source, arrayStringConcat(tables, ' ') AS tables, query_kind,
       Settings['async_insert'] AS async_insert_setting,
       count() AS inserts,
       round(count() / greatest(1, dateDiff('hour', min(event_time), max(event_time))), 1) AS inserts_per_hour,
       sum(written_rows) AS total_written_rows, round(avg(written_rows)) AS mean_rows_per_insert,
       round(quantile(0.5)(written_rows)) AS p50_rows_per_insert, max(written_rows) AS max_rows_per_insert,
       sum(written_bytes) AS total_written_bytes, round(avg(query_duration_ms), 1) AS mean_ms,
       arrayStringConcat(groupUniqArray(toString(interface)), ' ') AS interfaces,
       arrayStringConcat(groupUniqArrayIf(5)(client_name, client_name != ''), ' | ') AS client_names
FROM system.query_log
WHERE event_date >= today() - 7 AND event_time >= now() - INTERVAL 7 DAY
  AND type = 'QueryFinish' AND is_initial_query
  AND query_kind IN ('Insert', 'AsyncInsertFlush')
GROUP BY tables, query_kind, async_insert_setting
ORDER BY total_written_rows DESC
LIMIT 500
INTO OUTFILE '14_inserts.csv' FORMAT CSVWithNames;

-- 15: ingestion from part_log (only if the server enables it): new parts per table (one per
--     insert block, so rows per part is the real batch size), merges and mutations, over 7 days.
SELECT 'all replicas' AS source, database, table AS table_name, toString(event_type) AS event_type,
       count() AS events,
       round(count() / greatest(1, dateDiff('hour', min(event_time), max(event_time))), 1) AS events_per_hour,
       sum(rows) AS total_rows, round(avg(rows)) AS mean_rows, round(quantile(0.5)(rows)) AS p50_rows,
       sum(size_in_bytes) AS total_bytes, round(avg(duration_ms), 1) AS mean_duration_ms,
       countIf(error != 0) AS errors
FROM clusterAllReplicas('default', system.part_log)
WHERE event_date >= today() - 7 AND event_time >= now() - INTERVAL 7 DAY
  AND event_type IN ('NewPart', 'MergeParts', 'MutatePart')
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table, event_type
ORDER BY total_rows DESC
LIMIT 1000
INTO OUTFILE '15_part_log.csv' FORMAT CSVWithNames;

SELECT 'this server' AS source, database, table AS table_name, toString(event_type) AS event_type,
       count() AS events,
       round(count() / greatest(1, dateDiff('hour', min(event_time), max(event_time))), 1) AS events_per_hour,
       sum(rows) AS total_rows, round(avg(rows)) AS mean_rows, round(quantile(0.5)(rows)) AS p50_rows,
       sum(size_in_bytes) AS total_bytes, round(avg(duration_ms), 1) AS mean_duration_ms,
       countIf(error != 0) AS errors
FROM system.part_log
WHERE event_date >= today() - 7 AND event_time >= now() - INTERVAL 7 DAY
  AND event_type IN ('NewPart', 'MergeParts', 'MutatePart')
  AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table, event_type
ORDER BY total_rows DESC
LIMIT 1000
INTO OUTFILE '15_part_log.csv' FORMAT CSVWithNames;

-- 16: async inserts from asynchronous_insert_log (only if the server enables it), over 7 days.
SELECT 'all replicas' AS source, database, table AS table_name, format, toString(status) AS status,
       count() AS inserts, uniqExact(flush_query_id) AS flushes,
       sum(rows) AS total_rows, round(avg(rows)) AS mean_rows, sum(bytes) AS total_bytes, round(avg(bytes)) AS mean_bytes
FROM clusterAllReplicas('default', system.asynchronous_insert_log)
WHERE event_date >= today() - 7 AND event_time >= now() - INTERVAL 7 DAY
GROUP BY database, table, format, status
ORDER BY total_rows DESC
LIMIT 500
INTO OUTFILE '16_async_inserts.csv' FORMAT CSVWithNames;

SELECT 'this server' AS source, database, table AS table_name, format, toString(status) AS status,
       count() AS inserts, uniqExact(flush_query_id) AS flushes,
       sum(rows) AS total_rows, round(avg(rows)) AS mean_rows, sum(bytes) AS total_bytes, round(avg(bytes)) AS mean_bytes
FROM system.asynchronous_insert_log
WHERE event_date >= today() - 7 AND event_time >= now() - INTERVAL 7 DAY
GROUP BY database, table, format, status
ORDER BY total_rows DESC
LIMIT 500
INTO OUTFILE '16_async_inserts.csv' FORMAT CSVWithNames;

-- 17: Kafka engine consumers (only on servers built with Kafka): message and commit counts per
--     table. Topics, offsets and error text are not collected. 04_tables.csv lists all
--     streaming engine tables (Kafka, RabbitMQ, NATS, S3Queue) and the views that read them.
SELECT database, table AS table_name, count() AS consumers,
       sum(num_messages_read) AS messages_read, sum(num_commits) AS commits,
       max(last_poll_time) AS last_poll_time
FROM system.kafka_consumers
GROUP BY database, table
ORDER BY database, table
INTO OUTFILE '17_kafka_consumers.csv' FORMAT CSVWithNames;

-- schema_from_db.sql: SHOW CREATE TABLE text for every table and view, with COMMENT clauses
-- removed. Tables whose engine connects to another system (Kafka, S3, PostgreSQL, MySQL, URL,
-- dictionaries and so on) get a one-line note instead, because their settings name hosts, users
-- and keys. Their columns are in 05_columns.csv.
SELECT line FROM (
  SELECT 0 AS o, '' AS k, '-- Rebuilt from system.tables by pgrust-workload collect_clickhouse.sql. Comments removed; external-engine definitions omitted.' AS line
  UNION ALL
  SELECT if(engine IN ('View', 'MaterializedView', 'LiveView', 'WindowView'), 2, 1) AS o,
         concat(database, '.', name) AS k,
         if(match(engine, 'MergeTree$') OR engine IN ('View', 'MaterializedView', 'Distributed', 'Buffer', 'Merge', 'Memory',
                                                      'Null', 'Set', 'Join', 'Log', 'TinyLog', 'StripeLog', 'EmbeddedRocksDB', 'KeeperMap'),
            concat(replaceRegexpAll(replaceRegexpAll(create_table_query,
                                                     ' COMMENT ''(?:[^''\\\\]|\\\\.)*''', ''),
                                    '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}', '<email>'), ';'),
            concat('-- ', database, '.', name, ': ', engine, ' table, definition omitted (its settings can name hosts, users and keys). Columns: 05_columns.csv.')) AS line
  FROM system.tables
  WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
    AND NOT is_temporary
)
ORDER BY o, k
INTO OUTFILE 'schema_from_db.sql' FORMAT TSVRaw;

SELECT 'pgrust-workload collect_clickhouse.sql finished. Nothing was written to the server.' AS done;
