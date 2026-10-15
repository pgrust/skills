#!/usr/bin/env python3
"""Replace literal values in SQL text with $1, $2, ... and strip comments.

Use it on query text that may still carry real values: pasted queries, slow-query logs,
Azure Query Store text, or a dashboard export that was not normalized.

Usage:
  python3 normalize_sql.py queries_raw.sql > queries.sql
  python3 normalize_sql.py --csv-column query export.csv > export.normalized.csv

Statements are separated by semicolons in .sql mode; each statement's numbering restarts
at $1. Existing $n placeholders and ? placeholders are kept. Identifiers in double quotes
are untouched. String, dollar-quoted, numeric, and E'' / B'' / X'' literals become $n.
Standard library only; no network.
"""
import argparse
import csv
import re
import sys

TOKEN = re.compile(
    r"""
    (?P<line_comment>--[^\n]*)
  | (?P<block_comment>/\*.*?\*/)
  | (?P<ident>"(?:[^"]|"")*")
  | (?P<dollar>\$(?P<tag>[A-Za-z_][A-Za-z_0-9]*|)\$.*?\$(?P=tag)\$)
  | (?P<param>\$\d+|\?)
  | (?P<string>(?:[EeBbXxNn])?'(?:[^'\\]|''|\\.)*')
  | (?P<number>(?<![\w$.])\d+(?:\.\d+)?(?:[eE][+-]?\d+)?(?![\w.]))
  | (?P<word>[A-Za-z_][A-Za-z_0-9]*)
  | (?P<other>.)
    """,
    re.S | re.X,
)


def normalize(sql):
    out = []
    n = 0
    used = [int(m) for m in re.findall(r"\$(\d+)", sql)]
    n = max(used) if used else 0
    for m in TOKEN.finditer(sql):
        kind = m.lastgroup
        text = m.group(0)
        if kind in ("line_comment", "block_comment"):
            out.append(" ")
        elif kind in ("string", "dollar", "number"):
            n += 1
            out.append("$%d" % n)
        elif kind == "tag":
            continue
        else:
            out.append(text)
    result = "".join(out)
    return re.sub(r"[ \t]+\n", "\n", re.sub(r"[ \t]{2,}", " ", result)).strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("--csv-column", help="normalize this column of a CSV file instead of a .sql file")
    args = ap.parse_args()

    if args.csv_column:
        with open(args.file, newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        if not rows:
            return 0
        if args.csv_column not in rows[0]:
            print("column %r not found; columns: %s" % (args.csv_column, ", ".join(rows[0].keys())), file=sys.stderr)
            return 2
        w = csv.DictWriter(sys.stdout, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for row in rows:
            row[args.csv_column] = normalize(row[args.csv_column] or "")
            w.writerow(row)
        return 0

    with open(args.file, encoding="utf-8") as f:
        text = f.read()
    # Split on semicolons that are outside literals and comments.
    statements, buf = [], []
    for m in TOKEN.finditer(text):
        if m.lastgroup == "other" and m.group(0) == ";":
            statements.append("".join(buf))
            buf = []
        elif m.lastgroup != "tag":
            buf.append(m.group(0))
    if "".join(buf).strip():
        statements.append("".join(buf))
    for stmt in statements:
        if stmt.strip():
            print(normalize(stmt) + ";\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
