# Level 2: dashboard exports, by host

Give the user only the section for their host. Ask for a downloaded file path where an export exists. A screenshot works where it doesn't: save it under `pgrust-workload/dashboard/` and transcribe the query text and numbers into `queries.sql`.

Status labels:

- **VERIFIED** means checked against the vendor's official docs, or the open-source console code, on 2026-10-15.
- **UNVERIFIED** means not confirmed. Tell the user "it may be named slightly differently" for those parts.

Consoles move, so if a path doesn't match what they see, ask them to describe the screen rather than guessing.

## Supabase

**Top queries** (VERIFIED from Supabase Studio source, 2026-10-14):

1. Open the project in the dashboard, then **Observability** in the left sidebar, then **Query Performance**. On projects with the newer monitoring extension the same menu item is called **Query Insights**.
2. Sort by **Time consumed** (total time). The **Roles** filter defaults to all roles; keep it that way.
3. Scroll the table to the bottom once. The export includes only rows already loaded, and the page loads 20 at a time.
4. Click the **Download results** button (top right, next to "Reset report"), then **Download CSV**. The file is named like `Supabase Query Performance Statements (<project-ref>).csv`.
5. Give the agent the file path.

The columns are Query, Time consumed, Calls, Max/Mean/Min time, Rows processed, Cache hit rate, Role and Application. The query text is normalized (`$1`) because it comes from `pg_stat_statements`, which Supabase installs on every project. Dashboard-originated queries are tagged `-- source: dashboard`; drop those.

**Advisors** (VERIFIED from docs and Studio source):

1. In the left sidebar, open **Advisors**, then **Performance Advisor**.
2. On each of the Errors, Warnings and Info tabs, click **Download results**, then **Download CSV**.

The Performance Advisor lists issues such as unindexed foreign keys, unused indexes, duplicate indexes, RLS policies that re-evaluate `auth.*()` per row, and table bloat. The Security Advisor isn't needed.

**CLI alternative.** This is read-only and runs on the user's machine, logged in to their own account (VERIFIED, Supabase CLI reference):

```sh
supabase inspect report --linked --output-dir pgrust-workload/dashboard/supabase-inspect
supabase db advisors --linked --type performance
```

`inspect report` writes one CSV per check into a dated subfolder: outliers, calls, table stats, index stats, bloat and so on. The user runs these, or approves you running them. They use the user's own Supabase login, so the agent never sees a database password.

**Schema, if the migrations aren't complete.** `supabase db dump --linked -f pgrust-workload/dashboard/schema_dump.sql` is schema-only by default and excludes Supabase-managed schemas (VERIFIED). It holds table locks on the primary while it runs, so suggest it only for a quiet moment or a branch. Database webhooks put service keys into trigger definitions, so the scan in Step 5 must run on this file.

## PlanetScale Postgres

VERIFIED from PlanetScale docs:

1. Open the database, then the **Insights** tab.
2. Choose the branch (top left) and **primary**. Use **replica** too if reads go there.
3. Set the time range to the last 7 days, or the busiest period.
4. Sort the query table by **Total time**.

There is **no CSV export** (UNVERIFIED that none exists; none is documented). Ask for a screenshot of the top 20 rows, or have the user click each pattern and copy its SQL. The text is already normalized (`$1`).

Insights doesn't need `pg_stat_statements`; PlanetScale's own `pginsights` extension feeds it.

## PlanetScale MySQL (Vitess)

VERIFIED from PlanetScale docs:

1. Open the database, then the **Insights** tab.
2. Choose the branch and **primary**.
3. Under **View options**, turn on % of runtime, count, total time, p50/p99, rows read and rows returned.
4. Sort by **% of runtime** or **total time**.

Orange icons mark full table scans and cross-shard queries. Mention them in queries.sql.

There is no CSV export, so a screenshot plus copied query text is the format. The queries are MySQL dialect: keep them as-is, with `?` placeholders.

## Neon

**Console** (VERIFIED, Neon docs):

1. Open the project, then **Monitoring**, then the **Query performance** tab.
2. Pick the branch, compute and database.

It shows the top 100 normalized queries with frequency and average time. There is no export, so take a screenshot.

The history resets when the compute scales to zero or restarts. Do this after a busy period, not first thing in the morning on a quiet branch.

**CLI alternative** (VERIFIED, Neon CLI docs; read-only, uses the user's own Neon login):

```sh
neon inspect db outliers > pgrust-workload/dashboard/neon-outliers.txt
neon inspect db table-sizes > pgrust-workload/dashboard/neon-table-sizes.txt
neon inspect db calls > pgrust-workload/dashboard/neon-calls.txt
```

Each prints the top 25. Exact output-format flags are UNVERIFIED.

## AWS RDS and Aurora PostgreSQL

VERIFIED, AWS docs. Performance Insights reached end of life on 2026-07-31, and its console now redirects to CloudWatch Database Insights.

1. In the AWS console, open **CloudWatch**, then **Insights**, then **Database Insights**.
2. Choose the **Database Instance** view and pick the instance (the writer, for Aurora).
3. Open the **Top SQL** tab and set the time range to a busy 24 hours.

It ranks by DB load (average active sessions), not by total time. The text is normalized ("digest") and may be cut off at 4,096 characters.

There is no console CSV export. Take a screenshot, plus the full text of the top 10 statements; clicking a statement shows its text.

**CLI alternative**, for users comfortable with the AWS CLI on their own credentials:

```sh
aws pi describe-dimension-keys --service-type RDS --identifier db-XXXX \
  --metric db.load.avg --group-by '{"Group":"db.sql_tokenized"}' \
  --start-time <iso> --end-time <iso> --max-results 25
```

The agent must not run AWS commands itself unless the user asks, and must never read `~/.aws`.

The Standard and Advanced modes differ in retention and plan capture. Which one is the default is contradictory in AWS's own docs (UNVERIFIED), and either is fine for this.

## Google Cloud SQL for PostgreSQL and AlloyDB

**Cloud SQL** (VERIFIED, Google docs):

1. Open the instance, then **Query insights** in the instance menu.
2. Set the time range to a busy day.
3. Use the **Top queries** table, sorted by load or total time. Columns include Times called and Avg execution time.

There is no CSV export (UNVERIFIED), so take a screenshot and copy the text of the top queries. The text is normalized. If the page says Query insights is disabled, it is opt-in on Cloud SQL Enterprise. Don't ask the user to turn it on for us; offer Level 1 or Level 3 instead.

**AlloyDB:** open **Clusters**, then the cluster, then **Query insights**. It's on by default (VERIFIED).

## Heroku Postgres

VERIFIED, Heroku Dev Center.

**Dashboard:**

1. Open the database, then the **Diagnose** tab, which shows expensive queries for 7 days.
2. Take a screenshot.

The Diagnose tab isn't available on Essential or Shield plans.

**CLI:**

```sh
heroku pg:outliers -n 25 > pgrust-workload/dashboard/heroku-outliers.txt
```

This needs the pg-extras plugin. Never add `--reset`.

## Azure Database for PostgreSQL (Flexible Server)

VERIFIED, Microsoft Learn.

1. Open the server, then **Intelligent Performance**, then **Query Performance Insight**.
2. Use the **Top Queries by Calls** and **Long Running Queries** tabs.

It needs Query Store switched on (`pg_qs.query_capture_mode` = `top`), which is **off by default**. Don't ask them to switch it on for us. The portal shows query IDs, not text.

Azure's stored query text keeps the **literal values of the first execution**. If the user exports text from `query_store.query_texts_view`, run it through `normalize_sql.py` before it goes into the bundle, and say so in SUMMARY.md.

## Self-hosted, Crunchy Bridge, Tiger Cloud, Fly and others

There's no dashboard step to give. Use Level 1, plus Level 3 if they're comfortable.

- **Crunchy Bridge:** `cb scope` exists, but its outlier text is truncated.
- **Tiger Cloud (Timescale):** **Insights** is under the service's monitoring (UNVERIFIED path). `pg_stat_statements` is on by default there.
