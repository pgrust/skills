# Level 1: extracting the schema and queries from code

Work from files only. Don't run any command that connects to a database: `prisma db pull`, `rails db:schema:dump`, `manage.py sqlmigrate`/`inspectdb`, `drizzle-kit introspect`/`push`, `alembic upgrade`, and the like. Commands that only read files are fine when the tool is already installed, for example `drizzle-kit export` or `prisma migrate diff --from-empty --to-schema ...`. Don't install anything.

## Where the schema lives

| Stack | Detect by | Schema source, best first | Notes |
|---|---|---|---|
| Prisma | `prisma/schema.prisma`, `@prisma/client` | `prisma/migrations/*/migration.sql`, then `schema.prisma` | Migrations are real DDL. `@@index`, `@unique` and `@relation` map to indexes and FKs. `@db.*` gives native types. |
| Drizzle | `drizzle-orm`, `drizzle.config.*` | the `out` folder of generated SQL migrations, then `schema.ts` | If `out` points at `supabase/migrations`, those files are the truth. |
| Supabase (any ORM) | `supabase/config.toml`, `supabase/migrations/` | `supabase/migrations/*.sql` in timestamp order | Tables made in the dashboard table editor are not in the repo. Say so if models reference tables no migration creates. |
| TypeORM | `typeorm`, `@Entity()` | `migrations/` SQL inside `up()`, then entities | `@Index`, `@ManyToOne` → FK, `@Column({ type })`. |
| Sequelize | `sequelize`, `models/`, `migrations/` | migrations (`queryInterface.createTable/addIndex`) | |
| Knex / Kysely | `knexfile`, `kysely` | migrations folder | |
| Rails | `Gemfile` with `rails`, `db/` | `db/structure.sql`, then `db/schema.rb`, then `db/migrate/` | `schema.rb` can't express triggers, functions or some index types. |
| Django | `manage.py`, `*/migrations/0*.py`, `models.py` | `models.py` plus migrations | Table name is `<app>_<model>` unless `db_table` is set. FK columns end `_id`. Default PK is `id bigint` (or `integer` before 3.2). `Meta.indexes`, `unique_together`. |
| SQLAlchemy / Alembic | `alembic/versions/`, `DeclarativeBase`, `Mapped[...]` | Alembic versions in order, then models | |
| Ecto (Elixir) | `priv/repo/migrations/` | migrations | |
| GORM / sqlc / goose / golang-migrate (Go) | `*.sql` in `migrations/` or `db/`, `sqlc.yaml` | SQL migrations; sqlc `schema:` files | sqlc `queries:` files are exact SQL. |
| Flyway / Liquibase (JVM) | `db/migration/V*__*.sql`, `changelog*.xml` | migration SQL | Hibernate entities otherwise. |
| Raw SQL | `schema.sql`, `*.sql` | those files | |

Write schema.sql in a form that applies in order to an empty database. When migrations alter tables, apply the alters mentally and write the final state, or concatenate the migrations in order. State which you did in SUMMARY.md.

**Drop from schema.sql:**

- `COMMENT ON` statements.
- Seed or `INSERT` statements.
- `GRANT`, `ALTER ROLE` and `CREATE ROLE`.
- Function and trigger bodies. Keep a one-line `--` note with the name, timing, event and table.
- RLS policy bodies that embed literal values. Keep `ENABLE ROW LEVEL SECURITY` and a note that policies exist, because RLS changes query plans.
- Literals in view definitions or partial-index predicates that look like real data. Replace them with `$1` and note it.

## Getting the SQL the app sends

**Exact SQL** comes from:

- raw query strings (`sql\`...\``, `db.execute`, `$queryRaw`, `connection.execute`, `cursor.execute`, `find_by_sql`, `.raw()`);
- sqlc query files;
- `.sql` files.

Replace interpolated values with `$1`, `$2` in order.

**ORM calls** need translating. Write what the ORM generates, not idealised SQL:

| ORM | What it generates |
|---|---|
| Drizzle | Double-quoted identifiers (`"invoices"."org_id" = $1`). Relational queries (`db.query.x.findMany({ with })`) become one statement with `left join lateral (... json_agg ...)` subqueries. `.limit(50).offset(p*50)` becomes `limit $n offset $m`. |
| Prisma | Quoted `"public"."Table"` names. `include`/`select` relations become separate follow-up queries (`WHERE "id" IN ($1, $2, ...)`), unless the schema enables `relationJoins` or a call passes `relationLoadStrategy: "join"`, which gives one query with `LATERAL` joins. Which default your Prisma version uses is unverified here, so say which you assumed. `findMany` with `take`/`skip` becomes `LIMIT/OFFSET`. Count queries wrap a subquery. |
| ActiveRecord | `includes` becomes a second `WHERE id IN (...)` query. `.joins` becomes `INNER JOIN`. `.count` becomes `SELECT COUNT(*)`. Watch for N+1 loops: say "runs once per row". |
| Django | `select_related` becomes a JOIN. `prefetch_related` becomes a second `IN` query. `.count()` and `.exists()` become `SELECT 1 ... LIMIT 1`. Admin list pages count the whole table. |
| SQLAlchemy | `selectinload` becomes a second `IN` query. `joinedload` becomes a LEFT OUTER JOIN. |

Mark every translated query `confidence: translated from <ORM> (approximate)`.

**What to pick, 10 to 25 queries, ranked by expected load:**

1. Queries behind list or index endpoints with filters, sorting and pagination, especially deep `OFFSET`.
2. Dashboards and reports: aggregates, `GROUP BY`, `date_trunc`, `count(distinct)`, window functions.
3. Search: `ILIKE '%...%'`, full-text, trigram, typeahead.
4. Background jobs and crons, using the schedule in `vercel.json`, `crontab`, `sidekiq.yml`, `celery beat`, GitHub Actions or `fly.toml` as frequency evidence.
5. Writes on hot tables: event or audit inserts on every request, counters, upserts.
6. Anything with a comment saying it's slow, a TODO about performance, or a cache wrapped around it.
7. Auth or tenant lookups run on every request, such as session, API-key or org membership checks.

For each query, give your evidence for frequency ("called from middleware on every request", "hourly cron", "on page load"). If you have none, say "unknown".

**Indexes:** note queries that look unindexed for their filter or sort, and FKs without an index. This is useful benchmark context. Don't propose fixes unless asked.

## MySQL (including PlanetScale MySQL/Vitess)

- Keep the MySQL dialect. Don't translate to Postgres; pgrust does that on its side.
- Use `?` placeholders as the app does, and say "MySQL" at the top of schema.sql and queries.sql.
- Vitess: note sharded keyspaces and vindexes if `vschema.json` exists.
- Level 3 (`collect.sql`) is Postgres-only, so for MySQL stop at Level 2 (PlanetScale Insights).

## Monorepos and several databases

- List each database the code talks to, and ask the user which one matters most. This is one of the few good questions.
- Make one bundle per database only if they ask: `<bundle>/<db-name>/`.
