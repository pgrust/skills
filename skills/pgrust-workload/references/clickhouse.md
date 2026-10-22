# ClickHouse: Level 3 with collect_clickhouse.sql

This file is the ClickHouse version of [live-sql.md](live-sql.md). Level 1 notes for ClickHouse are in [codebase.md](codebase.md#clickhouse), and ClickHouse Cloud console steps are in [dashboards.md](dashboards.md#clickhouse-cloud).

Tested against ClickHouse 24.8 and 26.8 (self-hosted, single server, with and without a cluster named `default`). Not yet run against ClickHouse Cloud itself.

## What to show the user before asking for a yes

Paste these lines, adapted only for the server name.

> `collect_clickhouse.sql` reads ClickHouse's own system tables, never your table rows:
> 1. Version, uptime, settings that differ from the defaults, a few server sizing settings.
> 2. Databases, tables and columns: engines, ORDER BY, partition and primary keys, codecs, TTLs, skip indexes, projections, materialized views, and row and byte counts from metadata.
> 3. The top 100 queries from `system.query_log` over 7 days, by total time and by count, with read rows and bytes and memory. Query text goes through `normalizeQuery()`, which replaces every literal with `?`.
> 4. Ingestion: inserts per table and rows per insert (query_log), new parts and merges (part_log), async inserts, Kafka consumers.
> 5. `SHOW CREATE TABLE` text for tables and views, with comments removed. Tables that connect elsewhere (Kafka, S3, PostgreSQL, MySQL, URL, dictionaries) get a one-line note instead, because their settings name hosts, users and keys.
>
> Guards: `readonly=1` and `max_execution_time=30` on every query, set on the command line. Results are written by your client with `INTO OUTFILE`, which never overwrites a file. Typical run: a few seconds.

Show the exact command too, and offer to print the file.

Be precise about the guarantee. `readonly=1` makes the server refuse writes, DDL and `SET` for this session. It does not block every statement: ClickHouse's docs list `BACKUP` as allowed at any readonly level. The real guarantee is that `collect_clickhouse.sql` contains only SELECTs, and that you run nothing else. Say that, and don't claim the login "can't write".

## Which client binary

Run `command -v clickhouse-client clickhouse`. Packages install `clickhouse-client`; the single-binary install has `clickhouse client` (two words). Use whichever exists, in the command below. If neither exists, don't install one. Offer Level 2 (ClickHouse Cloud) or ask the user to run the command themselves.

## Connection: how the agent gets one without seeing the password

In order of preference:

1. **Environment variables set before the agent started:** `CLICKHOUSE_HOST`, `CLICKHOUSE_USER` and `CLICKHOUSE_PASSWORD`. The command then takes no connection arguments.
2. **A named connection in the client config file.** The user adds a `<connection>` under `<connections_credentials>` in `~/.config/clickhouse/config.xml` (name, hostname, port, secure, user, password). The command adds `--connection NAME`. You must not open that file.
3. **A connection URL in an environment variable** the user names, such as `CLICKHOUSE_URL='clickhouse://user:password@host:9440'`. The command passes `"$CLICKHOUSE_URL"` as the first argument after `client`. Never print it.

If none is set up, explain options 1 and 2 in two lines, and wait. Never ask for a password or URL in chat, and never read one from `.env` or a config file. Recent clients switch to TLS on their own for port 9440 and for hostnames ending in `.clickhouse.cloud`. With an older client, add `--secure` after `client`.

## The command

Run it from the bundle, so the files land in `<bundle>/clickhouse/`. This is a different folder from Postgres's `<bundle>/db/`, so an app with both can have both.

```sh
mkdir -p <bundle>/clickhouse && cd <bundle>/clickhouse && clickhouse client --readonly=1 --max_execution_time=30 --ignore-error --multiquery < <skill-dir>/scripts/collect_clickhouse.sql
```

- Use `clickhouse-client` instead of `clickhouse client` if that's the binary that exists.
- Named connection: add `--connection NAME` after `client`.
- URL: put `"$THEIR_ENV_VAR"` straight after `client`, before the other flags.
- Run it as written. Don't add pipes, `ls` or other commands to it; read the files afterwards with your file tool.
- `--ignore-error` is required: some system tables don't exist on every server, and the script relies on some queries failing (see below).
- The script is fed on stdin rather than with `--queries-file`, because older clients set `log_comment` for a queries file, and a read-only login refuses that.

### If the login is already read-only

Every query then fails with the same error, and no file is written. These are the only retries allowed. Show the new command and get a new yes first.

| Error on every query | Meaning | Rerun with |
|---|---|---|
| `Cannot modify 'max_execution_time' setting in readonly mode` | the login's profile has `readonly=1` | `--readonly=1` and no `--max_execution_time` |
| `Cannot modify 'readonly' setting in readonly mode` | the login's profile has `readonly=2` | `--max_execution_time=30` and no `--readonly` |

Both are already read-only logins, so the guard comes from their profile. Without `--max_execution_time`, their own timeout applies; say so.

## Which server, replicas and clusters

- **Logs are per server.** `system.query_log`, `system.part_log` and `system.asynchronous_insert_log` hold only the queries and inserts each server handled. On ClickHouse Cloud every replica has its own, and ClickHouse's docs read them with `clusterAllReplicas(default, ...)`.
- **The script tries all replicas first.** Each log query runs once with `clusterAllReplicas('default', ...)` and once against this server only. Both write the same file, so only one succeeds. The `source` column says which: `all replicas` or `this server`. Part sizes (`06_parts.csv`) use `cluster('default', ...)`, which reads one replica per shard.
- **Self-hosted clusters with another name** get `this server` only. Tell the user that query counts and sizes then cover one node, and that `00_session.csv` shows `default_cluster_replicas` = 0. Don't run anything else to fix it. The user can run the script on each node themselves.
- `00_session.csv` records `readonly`, the version, uptime and the size of the `default` cluster. Uptime matters: logs only go back as far as the server kept them.

## Expected messages (not errors)

| Message | Meaning |
|---|---|
| `Requested cluster 'default' not found` | Not a cluster, or not named `default`. The single-server query that follows writes the file. |
| `File NN_....csv exists, consider using APPEND or TRUNCATE` | The all-replicas query already wrote that file, so the single-server query was skipped before it ran. |
| `Unknown table expression identifier 'system.part_log'` (or `system.asynchronous_insert_log`, `system.kafka_consumers`; older servers say the table doesn't exist) | That log isn't enabled on this server, or the build has no Kafka. That file is missing. Never enable anything. |

## When things go wrong

| Symptom | Meaning | Do |
|---|---|---|
| `command not found` | no client installed | Don't install it. Offer Level 2, or let the user run the command where a client exists. |
| `Authentication failed`, `Connection refused`, `Timeout` | wrong or unreachable connection | Report it and stop. Don't try other hosts, ports or logins. |
| `00_session.csv` missing, or `readonly` is `0` | the guard didn't apply | Delete `<bundle>/clickhouse/` (or ask the user to) and report it. Don't retry. |
| `Not enough privileges` on some files | the login can't read that system table | Tell the user which files are missing. The rest is still useful. Don't ask for an admin login. |
| `Timeout exceeded` on a log file | a very large query_log | Report it. Offer one rerun at a quieter time. The other files are still useful. |
| `11`–`13` empty | no matching queries in 7 days, or `log_queries` is off | Fall back to the Level 1 queries, marked "expected hot (no measured stats)". |

## Merging into the bundle

- **queries.sql.** Join `11_top_queries_by_time.csv` and `12_top_queries_by_count.csv` to `13_query_texts.csv` on `query_hash`. Add each query with a header marked `source: ClickHouse query_log (measured)`, with calls, mean and p95 ms, read rows per call and max memory. Link it to the code that sends it where you can tell. Keep ClickHouse's `?` placeholders.
- **tables.csv.** Fill it from `04_tables.csv` (rows and bytes from metadata) or `06_parts.csv` (active parts, compressed and uncompressed bytes), and say which in the `source` column.
- **schema.sql.** Prefer `schema_from_db.sql` over code-derived DDL when they differ, and say so in SUMMARY.md.
- **SUMMARY.md.** Add an "Ingestion" line: inserts per hour and rows per insert for the busiest tables (`14_inserts.csv`, `15_part_log.csv`), whether inserts are async, and any Kafka or other streaming tables (`04_tables.csv`, `17_kafka_consumers.csv`).

The scanner lists the version in `00_session.csv` (for example `24.8.14.39`) as an IP-address review item. That one is fine.

## What collect_clickhouse.sql deliberately does not do

- No `SELECT` from your tables, and no `uniq()` or `count()` over them. Row and byte counts come from metadata.
- No raw query text. Only `normalizeQuery()` output, for the top queries only. For INSERTs, anything after `FORMAT` or `VALUES` is cut first.
- No `exception`, `stack_trace`, `user`, `address`, `client_hostname`, `http_user_agent` or `log_comment` columns from query_log.
- No `CREATE` text for tables with external engines, no dictionary `SOURCE`, no database engine arguments, no function bodies, no table or column comments. ClickHouse hides passwords in that text as `[HIDDEN]`, but hosts, users and access key IDs stay visible.
- No row policies, users, roles, grants or quotas.
- No `system.processes`. Running queries carry real values.

## If the user wants to run it themselves

They can run the same command in their own terminal from anywhere. Give them the absolute bundle path and their connection flags. Then continue from "Merging into the bundle" above, after checking `00_session.csv`.
