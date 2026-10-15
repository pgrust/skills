# Level 3: running collect.sql

## What to show the user before asking for a yes

Paste these five lines, adapted only for the server name.

> `collect.sql` reads Postgres's own catalog and statistics, never your table rows:
> 1. Version, ~30 planner/memory settings, installed extensions, object counts.
> 2. Tables and indexes: definitions, estimated row counts, sizes, scan/insert/update counters.
> 3. Column statistics *shape* only (null fraction, distinct count, width), never the values.
> 4. Top 100 queries from `pg_stat_statements`, already `$1`-normalized, comments stripped, utility statements (like `ALTER ROLE ... PASSWORD`) dropped.
> 5. View definitions, and function/trigger *names* (no bodies).
>
> Guards: one `BEGIN READ ONLY` transaction, `statement_timeout` 30s, `lock_timeout` 2s, ends with `ROLLBACK`; it stops before reading anything if the transaction isn't read-only. Typical run: well under a second.

Show the exact command too. The file is short, so offer to print it if they want to read it first.

Be precise about the guarantee. A read-only transaction makes Postgres reject table writes and DDL. It does not block every side effect: VACUUM, ANALYZE and statistics resets are still allowed in read-only mode. The real guarantee is that `collect.sql` contains only SELECTs plus the transaction setup, and that you run nothing else. Say that, and don't claim the login "can't write".

## Connection: how the agent gets one without seeing the password

The command reads the connection from the environment. The agent never needs the value. In order of preference:

1. **An environment variable set before the agent started.** For example, `export PGRUST_DB_URL='postgres://...'` in the shell, then launch the agent (Claude Code, Codex) from that shell. In Cursor, set it in the shell Cursor's terminal uses, or use option 2.
2. **A libpq service file**, which works in every agent:
   - `~/.pg_service.conf`:

     ```ini
     [pgrust_ro]
     host=...
     port=5432
     dbname=...
     user=...
     ```

   - Put the password in `~/.pgpass` (mode 600).
   - The agent runs `psql "service=pgrust_ro"`. The agent must not open either file.
3. **`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER` and `PGPASSWORD`** exported before launch.

If none of these is set up, explain options 1 and 2 in two lines, and wait. Never ask for the URL in chat. Never read it from `.env`; the app's `.env` usually points at the primary with a read-write login.

## Which server

- **A read replica or a branch/clone is best** for the schema, sizes and settings, because there's zero load on the primary.
- **`pg_stat_statements` is per server.** A replica only counts queries that ran on that replica. If the app sends its heavy reads and all writes to the primary, the top-queries file from a replica will be thin or empty. Options:
  - take the primary's top queries from the dashboard (Level 2);
  - run the script once on the primary too. It's the same read-only, sub-second catalog read. The guards make this safe, but it's the user's call.
- **On a hot standby,** a statement can be cancelled with "conflict with recovery". That's harmless; rerun later.
- `00_session.csv` records `is_replica`. If the user said "replica" and it says `f`, tell them before you merge anything.

## Poolers

The script only uses `BEGIN READ ONLY` and `SET LOCAL` inside one transaction, so nothing leaks into a pooled connection. It works through transaction-mode poolers: PgBouncer, Supavisor, Neon `-pooler`, RDS Proxy. A direct or session connection is still preferable.

Don't add `PGOPTIONS` or `options=`. PgBouncer and RDS Proxy reject them, and the script doesn't need them.

## When things go wrong

| Symptom | Meaning | Do |
|---|---|---|
| `psql: command not found` | psql isn't installed | Don't install it. Offer Level 2, or let the user run the command where psql exists, such as a bastion or a container. |
| `connection refused`, `timeout`, `password authentication failed` | wrong or unreachable connection | Report it and stop. Don't try other hosts, ports or logins. |
| `STOP: the transaction is not read-only` | something overrode the read-only setting | Delete `pgrust-workload/db/` and report it. Don't retry. |
| `ERROR: canceling statement due to lock timeout` | a migration or maintenance job held a table lock | Those files are empty. Nothing waited more than 2 s. Offer one rerun later. |
| `ERROR: canceling statement due to statement timeout` | a huge catalog (thousands of tables or schemas) | Report it. The other files are still useful. |
| `11_top_queries.csv` says not installed | `pg_stat_statements` isn't in this database | Never install or enable it. Fall back as below. |
| `pg_stat_statements must be loaded via shared_preload_libraries` | extension created but not preloaded | Same as not installed. |
| `12_pgss_visibility.csv`: most rows hidden | the login lacks `pg_read_all_stats` | Tell the user. The dashboard (Level 2) usually has full visibility. Don't ask for a superuser login. |
| `syntax error at or near "\if"` or `\pset: unknown option: csv` | psql older than 12 | Ask the user to use a newer psql client. Server versions 12 and up are fine. |

**Fallback when there are no top queries:**

- `05_tables.csv` still shows which tables are hot (`seq_scan`, `idx_scan`, `n_tup_*`), and `06_indexes.csv` shows which indexes are used.
- Combine those with the Level 1 queries from code, and mark the code queries "expected hot (no measured stats)".
- The dashboard (Level 2) is the other source.

**Neon:** stats reset when the compute scales to zero, so run after a busy period.

**Version notes:**

- PG 12 has `total_time` rather than `total_exec_time`. The script handles both.
- PG 17 and older keep leading SQL comments in query text. The script strips all `/* */` comments.

## What collect.sql deliberately does not do

- No `pg_stats` value columns (`most_common_vals`, `histogram_bounds`). These contain real data.
- No `pg_stat_activity`. Live query text has real values in it.
- No function or trigger bodies, `pg_user_mappings`, roles or subscriptions. These can hold secrets.
- No `EXPLAIN`.
- No `pg_relation_size()` calls. Sizes come from catalog page counts (estimates), so no table is opened just to measure it. Building DDL text (`pg_get_indexdef`, `pg_get_viewdef`, `pg_get_expr`) briefly takes the same shared lock a SELECT takes, then releases it immediately (PostgreSQL source, `ruleutils.c`). A table locked by a migration makes that one statement give up after 2 s.

## If the user wants to run it themselves

They can run the same command in their own terminal from the repo root:

```sh
mkdir -p pgrust-workload/db && cd pgrust-workload/db && psql "$THEIR_URL" -X -q -f <skill-dir>/scripts/collect.sql
```

Then you continue from Level 3 step 5 (Verify).

## Optional: pg_dump of the schema (only if the user asks, and only on a replica or branch)

`pg_dump --schema-only --no-owner --no-privileges --no-subscriptions --no-comments --no-security-labels --lock-wait-timeout=5s`

Caveats:

- It holds a shared lock on every table until it finishes. On a primary, a migration that starts meanwhile waits, and app queries queue behind that migration.
- It disables its own timeouts.
- Its output can contain foreign-data-wrapper passwords and webhook tokens inside trigger definitions, so the Step 5 scan is mandatory.
- Never add `--statistics` or `--statistics-only`. These contain real values.

## No Python

If `python3` isn't available, scan with grep. The command prints only file:line, never the match, so a secret doesn't land in your context. Open each listed line and fix it:

```sh
grep -rnE '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}|eyJ[A-Za-z0-9_-]{8,}|[Bb]earer [A-Za-z0-9._~+/=-]{8,}|(sk|rk|pk)_(live|test)_[A-Za-z0-9]{8,}|AKIA[A-Z0-9]{12,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abposr]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY|://[^ :/@]+:[^ @/]+@|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd] *[:=]' pgrust-workload | cut -d: -f1-2
```

Fix each hit by editing the file to replace the value with `<redacted>`. Then rerun until the command prints nothing.

For literal values in queries without `normalize_sql.py`, replace each `'...'` string and each bare number in WHERE, VALUES and SET clauses by hand with `$1`, `$2`.
