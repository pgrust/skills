# pgrust agent skills

Agent skills from [pgrust](https://pgrust.com). There is one so far: `pgrust-workload`.

## pgrust-workload

Your coding agent writes down the shape of your app's database workload: the schema, the queries that matter, table sizes, Postgres version and extensions. pgrust generates fake data at your scale, runs your queries on stock Postgres and on pgrust, and sends you the timings. It also covers ClickHouse: table engines, sort keys, top queries and how data arrives.

- It starts by reading your code. Going further is your choice: export your host's query dashboard yourself, or let the agent run one read-only SQL file, [`collect.sql`](skills/pgrust-workload/scripts/collect.sql) for Postgres or [`collect_clickhouse.sql`](skills/pgrust-workload/scripts/collect_clickhouse.sql) for ClickHouse, after you approve the exact command.
- It never reads table rows or `.env` files, never writes to your database, and never sends anything. As in any agent session, your model provider sees what the agent reads.
- It writes one folder outside your repo, `~/pgrust-workload/<repo>-<date>/`. You review the folder and send it yourself.

The top of [`SKILL.md`](skills/pgrust-workload/SKILL.md) takes a minute to read: what the skill does, what it never does, and what leaves your machine. Read it before you install.

## Install

Install it at user level, so nothing is added to your app's repo. It works with Claude Code, Codex, Cursor and other agents that support [Agent Skills](https://agentskills.io).

**Ask your agent.** In your coding agent, say:

> Install the agent skill at https://github.com/pgrust/skills globally, not in this repo

Your agent should ask before it downloads anything and before it writes to its skills folder.

**Or run one command** (needs Node.js):

```sh
npx skills add pgrust/skills -g
```

This uses Vercel's open-source [`skills`](https://github.com/vercel-labs/skills) installer. It puts the skill in `~/.agents/skills/pgrust-workload/` for Codex and Cursor, and links it from `~/.claude/skills/` for Claude Code. Update later with `npx skills update -g`.

**Or copy it by hand:**

```sh
git clone --depth 1 https://github.com/pgrust/skills /tmp/pgrust-skills
mkdir -p ~/.claude/skills ~/.agents/skills
cp -R /tmp/pgrust-skills/skills/pgrust-workload ~/.claude/skills/
cp -R /tmp/pgrust-skills/skills/pgrust-workload ~/.agents/skills/
```

Claude Code reads `~/.claude/skills/`, Codex reads `~/.agents/skills/`, and Cursor reads both. If your agent doesn't support skills, tell it: "Read `<path>/skills/pgrust-workload/SKILL.md` and follow it."

## Use

Open your app's repo in your agent and say:

> use the pgrust-workload skill

The agent reads your code first, then offers the dashboard and SQL options. Add "code only" to skip them. When it finishes, read `SUMMARY.md` in the folder it names, then zip the folder and send it to your pgrust contact, or email maintainers@pgrust.com.

## Requirements

- `python3` for the local secret scan. Without it, the agent falls back to `grep`.
- `psql` 12 or newer, only for the read-only SQL option. Tested against Postgres 17 and 18.
- For ClickHouse, `clickhouse client` (or `clickhouse-client`), only for the read-only SQL option. Tested against ClickHouse 24.8 and 26.8.

## Remove

```sh
npx skills remove pgrust-workload -g
```

If you copied it by hand, run `rm -r ~/.claude/skills/pgrust-workload ~/.agents/skills/pgrust-workload`. Bundles stay in `~/pgrust-workload/` until you delete them.

## License

[MIT](LICENSE)
