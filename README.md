# pgrust-workload: an agent skill

This skill helps your coding agent describe your database workload for pgrust. It writes one folder outside your repo, `~/pgrust-workload/<repo>-<date>/`, for you to review and send yourself.

The first section of [`pgrust-workload/SKILL.md`](pgrust-workload/SKILL.md) explains in one minute what it does, what it never does, and what leaves your machine. Please read it before you install the skill.

## Install

Copy the `pgrust-workload` folder to where your agent looks for skills. These user-level locations keep it out of your repo.

| Agent | Where |
|---|---|
| Claude Code | `~/.claude/skills/pgrust-workload/` |
| Codex CLI | `~/.agents/skills/pgrust-workload/` |
| Cursor | Either of the above. Cursor reads `~/.agents/skills`, `~/.cursor/skills` and `~/.claude/skills`. |

```sh
git clone --depth 1 <repo-url> /tmp/pgrust-workload-skill
mkdir -p ~/.claude/skills ~/.agents/skills
cp -R /tmp/pgrust-workload-skill/pgrust-workload ~/.claude/skills/
cp -R /tmp/pgrust-workload-skill/pgrust-workload ~/.agents/skills/
```

For any other agent, open your repo and tell it: "Read `<path>/pgrust-workload/SKILL.md` and follow it."

## Use

From your app's repo, ask your agent:

> use the pgrust-workload skill

The agent reads your code first and asks before doing anything more. When it finishes, review `SUMMARY.md` in that folder, then zip the folder and send it to your pgrust contact.

## Requirements

- `python3` for the local secret scan. Without it, the agent falls back to a grep.
- `psql` version 12 or newer, only if you choose the read-only SQL option.

Tested with Postgres 17 and 18.

## Remove

```sh
rm -r ~/.claude/skills/pgrust-workload ~/.agents/skills/pgrust-workload
```
