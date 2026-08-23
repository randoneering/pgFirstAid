#!/usr/bin/env python3
"""Regenerate the inline CVE / known-bug VALUES blocks in pgFirstAid's three SQL files.

Source of truth:
  data/cves.json         - curated CVE entries (per-major fix-version map)
  data/known_bugs.json   - curated non-CVE release-note bugs (fixed_in_minor)

Behaviour:
  python tools/generate_cve_sql.py            # write fresh rows into all SQL files
  python tools/generate_cve_sql.py --check    # dry run: exit 1 if any SQL file is stale

The generator inserts VALUES rows between sentinel comments in each SQL file:

  -- GENERATED cves BEGIN  (regenerate via tools/generate_cve_sql.py; do not edit)
      ('CVE-...', ...),
      ...
  -- GENERATED cves END

  -- GENERATED bugs BEGIN
      ('PG...-...-..', ...),
      ...
  -- GENERATED bugs END

If a sentinel pair is missing, the script fails with a clear error.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = REPO_ROOT / "data"

CVES_JSON = DATA_DIR / "cves.json"
BUGS_JSON = DATA_DIR / "known_bugs.json"

# Files in which the inline VALUES blocks live. Order is irrelevant; we process
# each independently.
SQL_FILES = [
    REPO_ROOT / "pgFirstAid.sql",
    REPO_ROOT / "view_pgFirstAid.sql",
    REPO_ROOT / "view_pgFirstAid_managed.sql",
]

# Sentinel comments. Keep these strings stable: they are how the generator
# locates where to write. Format: "-- GENERATED <kind> BEGIN" / "... END".
SENTINEL_BEGIN_TEMPLATE = "-- GENERATED {kind} BEGIN (do not edit; regenerate via tools/generate_cve_sql.py)"
SENTINEL_END_TEMPLATE = "-- GENERATED {kind} END"

# Indentation for the VALUES rows. Each row lines up with the surrounding
# CTE block (8 spaces inside `values (`...).
ROW_INDENT = "        "  # 8 spaces


def _version_num(major: str, minor: int) -> int:
    """Convert (major, minor) -> PostgreSQL server_version_num.

    server_version_num format = MJMmm: e.g. 15.4 -> 150004, 17.11 -> 170011.
    """
    return int(major) * 10000 + minor


def _render_cve_row(cve_id: str, cvss: float, summary: str, major: str, minor: int, doc_link: str) -> str:
    """Render one VALUES row for a CVE entry expanded to a single major version."""
    affected_min = _version_num(major, 0)
    fixed_in = _version_num(major, minor)
    return f"{ROW_INDENT}({cve_id!r}, {cvss:>4}, {summary!r:>3},{affected_min}, {fixed_in}, {doc_link!r}),"


def _render_bug_row(issue_id: str, summary: str, major: str, minor: int, doc_link: str) -> str:
    """Render one VALUES row for a known-bug entry expanded to a single major version."""
    affected_min = _version_num(major, 0)
    fixed_in = _version_num(major, minor)
    return f"{ROW_INDENT}({issue_id!r}, {summary!r},{affected_min}, {fixed_in}, {doc_link!r}),"


def render_cve_rows(cves_doc: dict) -> list[str]:
    """Expand all CVE entries to per-major VALUES rows.

    PostgreSQL VALUES rules:
      - Two or more rows: separated by commas, last row has NO trailing comma.
      - One row only: no comma at all.
    We render every row with a trailing comma, then strip the last one.
    """
    out = []
    for cve in cves_doc["cves"]:
        cve_id = cve["cve_id"]
        cvss = cve["cvss"]
        summary = cve["summary"]
        doc_link = cve["doc_link"]
        # Sort majors numerically so output is reproducible.
        for major in sorted(cve["fixed_in"], key=int):
            minor = cve["fixed_in"][major]
            out.append(_render_cve_row(cve_id, cvss, summary, major, minor, doc_link))
    if out:
        # Strip the trailing comma from the last row: PostgreSQL rejects
        # the form `(...),` on the final VALUES entry.
        out[-1] = out[-1].rstrip(",")
    return out


def render_bug_rows(bugs_doc: dict) -> list[str]:
    """Expand all known-bug entries to per-major VALUES rows.

    The bug rows keep the bug's major prefix encoded in the issue_id, so each
    bug only expands to its own single major (unlike CVEs which can affect many).
    """
    out = []
    for bug in bugs_doc["bugs"]:
        # Parse the leading major from the issue_id, e.g. "PG15-..." -> "15".
        prefix, _, _ = bug["issue_id"].partition("-")
        major = prefix[len("PG"):]  # strip "PG"
        out.append(_render_bug_row(bug["issue_id"], bug["summary"], major, bug["fixed_in_minor"], bug["doc_link"]))
    if out:
        out[-1] = out[-1].rstrip(",")
    return out


def replace_block(sql_text: str, kind: str, new_rows: list[str]) -> str:
    """Replace the contents between the BEGIN/END sentinels for `kind`."""
    begin = SENTINEL_BEGIN_TEMPLATE.format(kind=kind)
    end = SENTINEL_END_TEMPLATE.format(kind=kind)

    begin_idx = sql_text.find(begin)
    if begin_idx == -1:
        raise SystemExit(f"missing sentinel {begin!r} in SQL file")

    # Skip past the BEGIN line + the newline that follows.
    begin_idx = sql_text.find("\n", begin_idx) + 1

    end_idx = sql_text.find(end, begin_idx)
    if end_idx == -1:
        raise SystemExit(f"missing sentinel {end!r} after BEGIN in SQL file")

    # Strip the chunk between markers; preserve a single trailing newline so
    # the END sentinel lands on its own line.
    before = sql_text[:begin_idx]
    after = sql_text[end_idx:]

    body = "\n".join(new_rows) + ("\n" if new_rows else "")
    return before + body + after


def regenerate_one(sql_path: Path, cve_rows: list[str], bug_rows: list[str]) -> str:
    text = sql_path.read_text()
    text = replace_block(text, "cves", cve_rows)
    text = replace_block(text, "bugs", bug_rows)
    return text


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if any SQL file would change (CI mode)",
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="default; write fresh rows into all SQL files (in-place)",
    )
    args = parser.parse_args()

    cves_doc = json.loads(CVES_JSON.read_text())
    bugs_doc = json.loads(BUGS_JSON.read_text())

    cve_rows = render_cve_rows(cves_doc)
    bug_rows = render_bug_rows(bugs_doc)

    failed = False
    for sql_path in SQL_FILES:
        current = sql_path.read_text()
        rendered = regenerate_one(sql_path, cve_rows, bug_rows)
        if current == rendered:
            print(f"ok    {sql_path.relative_to(REPO_ROOT)}")
            continue
        diff_lines = sum(1 for a, b in zip(current.splitlines(), rendered.splitlines()) if a != b)
        print(f"stale {sql_path.relative_to(REPO_ROOT)} (diff {diff_lines} lines)")
        if args.check:
            failed = True
        else:
            sql_path.write_text(rendered)
            print(f"wrote {sql_path.relative_to(REPO_ROOT)}")

    if args.check and failed:
        print("\nFAIL: SQL files are out of sync with data/*.json.", file=sys.stderr)
        print("Run `python tools/generate_cve_sql.py` to regenerate.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
