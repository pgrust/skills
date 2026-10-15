#!/usr/bin/env python3
"""Scan a pgrust-workload folder for secrets and personal data before a human sends it.

Usage:
  python3 scan_bundle.py pgrust-workload            # report only; exit 1 if anything must be fixed
  python3 scan_bundle.py pgrust-workload --redact   # replace must-fix matches in place, then report
  python3 scan_bundle.py pgrust-workload --term "Acme Corp" --term Northwind   # extra words to catch

Matches are printed masked (first 3 characters, then ***), so running this does not copy
the secret into the agent's context. Standard library only; reads and writes nothing
outside the folder you give it; makes no network calls.
"""
import argparse
import os
import re
import sys

# Must-fix: high-confidence secrets and personal data. --redact replaces these.
MUST_FIX = [
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("connection-string-password", re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s:/@'\"]+:[^\s@/'\"]+@")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]+){0,2}")),
    ("bearer-token", re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}")),
    ("stripe-key", re.compile(r"\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{8,}")),
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{12,}\b")),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}")),
    ("slack-token", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}")),
    ("openai-anthropic-key", re.compile(r"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}")),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_-]{30,}")),
    ("sql-password-literal", re.compile(r"(?i)\bpassword\s+'[^']*'")),
    ("assigned-secret", re.compile(
        r"(?i)\b(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?key|auth[_-]?token|client[_-]?secret)"
        r"\b[\"']?\s*[:=]\s*(?!\$\d|\?|NULL\b|null\b|true\b|false\b)[\"']?[^\s\"',;)]{4,}")),
    ("email", re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b")),
    ("phone", re.compile(r"(?<![\w.])\+?\d{1,3}[-\s.]\(?\d{2,4}\)?[-\s.]\d{3}[-\s.]\d{3,4}\b")),
    ("card-number", re.compile(r"\b(?:\d[ -]?){15,16}\b")),
]

# Review: may be fine, a human or the agent should look. Never auto-redacted.
REVIEW = [
    ("ip-address", re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")),
    ("cloud-hostname", re.compile(
        r"(?i)\b[a-z0-9.-]+\.(?:supabase\.co|supabase\.com|pooler\.supabase\.com|neon\.tech|psdb\.cloud|"
        r"rds\.amazonaws\.com|amazonaws\.com|database\.azure\.com|herokuapp\.com|cloudsql|"
        r"internal|corp|lan|intranet)\b")),
    ("uuid", re.compile(r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")),
    ("long-random-string", re.compile(r"\b(?=[A-Za-z0-9+/_-]*\d)(?=[A-Za-z0-9+/_-]*[A-Za-z])[A-Za-z0-9+/_-]{32,}={0,2}")),
    ("quoted-long-number", re.compile(r"'\d{6,}'")),
    ("compared-long-number", re.compile(r"(?:=|\bin\s*\()\s*\d{7,}\b", re.I)),
]

SKIP_DIRS = {".git", "node_modules", "__pycache__"}
MAX_BYTES = 20 * 1024 * 1024


def mask(s):
    s = s.strip()
    return (s[:3] + "***") if len(s) > 3 else "***"


def scan_text(text, extra):
    findings = []
    for lineno, line in enumerate(text.splitlines(), 1):
        for kind, rx in MUST_FIX + extra:
            for m in rx.finditer(line):
                findings.append(("must-fix", kind, lineno, m.group(0)))
        for kind, rx in REVIEW:
            for m in rx.finditer(line):
                findings.append(("review", kind, lineno, m.group(0)))
    return findings


def redact_text(text, extra):
    count = 0
    for kind, rx in MUST_FIX + extra:
        text, n = rx.subn("<redacted:%s>" % kind, text)
        count += n
    return text, count


def iter_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in sorted(filenames):
            yield os.path.join(dirpath, name)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder")
    ap.add_argument("--redact", action="store_true", help="replace must-fix matches in place")
    ap.add_argument("--term", action="append", default=[], help="extra word or name to treat as must-fix")
    args = ap.parse_args()

    if not os.path.isdir(args.folder):
        print("not a folder: %s" % args.folder, file=sys.stderr)
        return 2

    extra = [("term:" + t[:3] + "***", re.compile(re.escape(t), re.I)) for t in args.term if t.strip()]
    redacted_total = 0
    must_fix = []
    review = []
    for path in iter_files(args.folder):
        rel = os.path.relpath(path, args.folder)
        if os.path.getsize(path) > MAX_BYTES:
            review.append((rel, 0, "file-too-large-to-scan", ""))
            continue
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read()
        except UnicodeDecodeError:
            review.append((rel, 0, "binary-file", ""))
            continue
        if args.redact:
            new_text, n = redact_text(text, extra)
            if n:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(new_text)
                redacted_total += n
                text = new_text
        for level, kind, lineno, match in scan_text(text, extra):
            if "<redacted:" in match:
                continue
            (must_fix if level == "must-fix" else review).append((rel, lineno, kind, match))

    if args.redact:
        print("redacted %d must-fix match(es) in place" % redacted_total)
    print("must-fix remaining: %d" % len(must_fix))
    for rel, lineno, kind, match in must_fix:
        print("  MUST-FIX %s:%d [%s] %s" % (rel, lineno, kind, mask(match)))
    print("review: %d" % len(review))
    for rel, lineno, kind, match in review[:200]:
        print("  REVIEW   %s:%d [%s] %s" % (rel, lineno, kind, mask(match)))
    if len(review) > 200:
        print("  ... %d more review items" % (len(review) - 200))
    return 1 if must_fix else 0


if __name__ == "__main__":
    sys.exit(main())
