#!/usr/bin/env python3
"""Scrape PostgreSQL release notes and propose notable bug fixes.

Source of truth for the live catalog:
    https://www.postgresql.org/docs/release/         (release index, lists all minors)
    https://www.postgresql.org/docs/release/X.Y/    (per-minor change list)

Workflow:
  Default --propose     Fetch latest releases, extract bug-fix listitems, classify
                        severity, dedupe against data/known_bugs.json, print the
                        top-N proposals as JSON. No files are modified.
  --check               CI mode: exit non-zero when proposals are non-empty.
  --write --yes         Patch data/known_bugs.json with the proposals.

Inclusion rule (project policy, matches the prior conversation):
  - Limit to the last `revisions-back` releases per major in {15,16,17,18}.
  - Each proposal needs a stable identifier. We use the upstream commit hash
    when available (`https://postgr.es/c/<HASH>`); otherwise a content hash.
  - Dedupe against data/known_bugs.json by the proposed issue_id.
  - Output is sorted by severity (highest first), then by major, then by id.

Caveats — the release-notes catalog is fundamentally noisier than the CVE
catalog: each minor has ~50-200 listitems. We rely on keyword severity
filtering plus a per-major top-N cap to keep the proposal list reviewable.

No external deps: urllib.request + stdlib re. Same SSL-CA resolution as
tools/scrape_pgdg.py.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.request
from pathlib import Path
from typing import Any

PGDG_RELEASE_INDEX = "https://www.postgresql.org/docs/release/"
PGDG_DOCS_BASE = "https://www.postgresql.org/docs"

REPO_ROOT = Path(__file__).resolve().parent.parent
BUGS_JSON = REPO_ROOT / "data" / "known_bugs.json"

DEFAULT_MAJORS = ["15", "16", "17", "18"]
DEFAULT_REVISIONS_BACK = 2  # how many recent minors per major to scan
DEFAULT_TOP_PER_MAJOR = 5   # output cap per major
DEFAULT_USER_AGENT = "pgFirstAid-scout/0.1 (+https://github.com/bringnow/pgFirstAid)"


# ---------- Severity keywords ----------

# Each listitem's first <p> summarizes the fix. These keyword lists classify.
# "high" = data integrity / crash / wrong results.
# "medium" = replication / vacuum / partition / pl/* / catalog / planner.
# "low" = everything else. (Default omits low unless --include-low.)

HIGH_KEYWORDS = (
    "data corruption",
    "data loss",
    "wrong results",
    "incorrect results",
    "crash",
    "panicked",
    "panic",
    "server crash",
    "stack overflow",
    "memory corruption",
    "memory-safety",
    "use-after-free",
    "buffer overrun",
    "buffer overflow",
    "integer overflow",
    "integer underflow",
    "diverg",
    "divergence",
    "silent",
    "leaks data",
    "data leak",
    "discloses",
    "leaks memory",
    "memory leak",
    "could result in",
)

MEDIUM_KEYWORDS = (
    "replication",
    "replica",
    "standby",
    "failover",
    "subtransact",
    "subtransaction",
    "partition",
    "vacuum",
    "analyze",
    "autovacuum",
    "trigger",
    "foreign key",
    "foreign keys",
    "alter table",
    "catalog",
    "pl/pgsql",
    "pl/perl",
    "pl/python",
    "pl/tcl",
    "extension",
    "index",
    "btree",
    "gin",
    "gist",
    "brin",
    "hash index",
    "sequence",
    "serial",
    "identity column",
    "subquery",
    "join order",
    "planner",
    "statistics",
    "pg_upgrade",
    "pg_dump",
    "pg_restore",
    "wal",
    "checkpoint",
    "logical replication",
    "subscription",
    "publication",
    "deadlock",
    "lock",
    "parallel",
    "cte",
    "recursive",
    "upsert",
    "merge",
    "json",
    "jsonb",
    "tsvector",
    "tsquery",
)


# ---------- SSL ---------- (mirrors scrape_pgdg.py)

def _resolve_cafile() -> str | None:
    """Best-effort CA bundle discovery. Returns None if nothing usable is found."""
    candidates = [
        os.environ.get("SSL_CERT_FILE"),
        os.environ.get("CURL_CA_BUNDLE"),
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/ssl/certs/ca-bundle.crt",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/ssl/cert.pem",
    ]
    for path in candidates:
        if path and os.path.exists(path):
            return path
    return None


def _fetch(url: str, timeout: float = 30.0, user_agent: str = DEFAULT_USER_AGENT) -> str | None:
    """Fetch a URL. Returns None on 404/410/5xx to allow caller to skip gracefully.

    PGDG occasionally has indexing gaps (a release is announced and indexed
    but the per-minor page hasn't been uploaded yet). We treat that as
    "skip this revision and continue" rather than a hard error.
    """
    import ssl
    ctx = ssl.create_default_context()
    cafile = _resolve_cafile()
    if cafile:
        ctx.load_verify_locations(cafile)
    req = urllib.request.Request(
        url, headers={"User-Agent": user_agent, "Accept": "text/html,*/*"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            return resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        if exc.code in (404, 410):
            return None
        raise


# ---------- Release index ----------

_VERSION_LINK_RE = re.compile(r'<a[^>]*href="(/docs/release/(\d+)\.(\d+)/?)"[^>]*>')


def list_recent_releases(
    html: str, *,
    majors: list[str],
    revisions_back: int,
) -> dict[str, list[str]]:
    """Return {major: [minor1, minor2, ...]} for the most recent `revisions_back`.

    Each major's list is sorted ascending so callers can slice off the top
    `revisions_back` newest entries (the rightmost end of the list).
    """
    found: dict[str, list[str]] = {m: [] for m in majors}
    majors_set = set(majors)
    for path, major, minor in _VERSION_LINK_RE.findall(html):
        if major not in majors_set:
            continue
        if minor not in found[major]:
            found[major].append(minor)
    for entries in found.values():
        entries.sort(key=lambda m: int(m))
    return found


# ---------- Per-release page parsing ----------

_LISTITEM_RE = re.compile(
    r'<li class="listitem">(.*?)</li>',
    re.DOTALL,
)
_FIRST_P_RE = re.compile(r"<p>(.*?)</p>", re.DOTALL)
_COMMIT_LINK_RE = re.compile(r'href="https://postgr\.es/c/([0-9a-f]{6,})"')
_TAG_STRIP_RE = re.compile(r"<[^>]+>")
_WHITESPACE_RE = re.compile(r"\s+")


def _strip_tags(html_text: str) -> str:
    text = _TAG_STRIP_RE.sub("", html_text)
    return _WHITESPACE_RE.sub(" ", text).strip()


def _classify(text: str) -> str:
    lower = text.lower()
    for kw in HIGH_KEYWORDS:
        if kw in lower:
            return "high"
    for kw in MEDIUM_KEYWORDS:
        if kw in lower:
            return "medium"
    return "low"


def parse_release_page(html: str, *, major: str, minor: str, doc_link: str) -> list[dict]:
    """Return listitems from a release-notes page as proposed-addition dicts."""
    entries: list[dict] = []
    for li_m in _LISTITEM_RE.finditer(html):
        body = li_m.group(1)
        # Use the FIRST <p> as the summary title; usually "Fix ... (Author Name)".
        first_p = _FIRST_P_RE.search(body)
        if not first_p:
            continue
        summary = _strip_tags(first_p.group(1))
        if not summary:
            continue
        # Trim "(Author Name)" off the end so the proposed summary reads cleanly.
        summary = re.sub(r"\s*\([A-Z][\w .'-]*(?:,\s*[A-Z][\w .'-]*)*\)\s*$", "", summary)
        if not summary:
            continue

        # Stable identifier: commit hash if any, else summary hash.
        commit_match = _COMMIT_LINK_RE.search(body)
        if commit_match:
            issue_id = f"PG{major}-{commit_match.group(1)[:9]}"
        else:
            digest = hashlib.sha1(summary.encode("utf-8")).hexdigest()[:8]
            issue_id = f"PG{major}-FIX-{digest}"

        severity = _classify(summary)

        entries.append({
            "issue_id": issue_id,
            "summary": summary,
            "doc_link": doc_link,
            "fixed_in_minor": int(minor),
            # Internal fields — stripped by to_json_format.
            "_severity": severity,
            "_commit": commit_match.group(1) if commit_match else None,
        })
    return entries


# ---------- Filtering ----------

def filter_proposed(
    entries: list[dict],
    existing: list[dict],
    *,
    majors: list[str],
    min_severity: str = "medium",
    top_per_major: int = DEFAULT_TOP_PER_MAJOR,
) -> list[dict]:
    """Reduce scraped listitems to a human-reviewable proposal set.

    - Skip existing entries (matched by issue_id).
    - Keep only entries whose severity is >= min_severity.
    - Limit to N entries per major, highest severity first.
    """
    sev_rank = {"low": 0, "medium": 1, "high": 2}
    threshold = sev_rank[min_severity]

    existing_ids = {row["issue_id"] for row in existing}

    # Filter + score.
    qualifying = []
    for entry in entries:
        major = doc_link_major(entry["doc_link"])
        if major not in majors:
            continue
        if entry["issue_id"] in existing_ids:
            continue
        sev = entry["_severity"]
        if sev_rank[sev] < threshold:
            continue
        qualifying.append(entry)

    # Group by major; sort each group by severity desc, then by minor desc, then by id.
    by_major: dict[str, list[dict]] = {m: [] for m in majors}
    for entry in qualifying:
        major = doc_link_major(entry["doc_link"])
        by_major.setdefault(major, []).append(entry)
    result: list[dict] = []
    for major in majors:
        items = by_major.get(major, [])
        items.sort(key=lambda e: (-sev_rank[e["_severity"]], -e["fixed_in_minor"], e["issue_id"]))
        result.extend(items[:top_per_major])
    return result


_DOC_LINK_MAJOR_RE = re.compile(r"/release/(\d+)\.(\d+)/?")


def doc_link_major(doc_link: str) -> str:
    m = _DOC_LINK_MAJOR_RE.search(doc_link)
    return m.group(1) if m else ""


def to_json_format(proposed: list[dict]) -> list[dict]:
    """Strip internal fields; return only the keys the JSON schema uses."""
    return [
        {
            "issue_id": p["issue_id"],
            "summary": p["summary"],
            "doc_link": p["doc_link"],
            "fixed_in_minor": p["fixed_in_minor"],
        }
        for p in proposed
    ]


# ---------- File IO ----------

def load_existing() -> list[dict]:
    if not BUGS_JSON.exists():
        return []
    return json.loads(BUGS_JSON.read_text()).get("bugs", [])


def merge_into_data(proposed: list[dict]) -> None:
    """Patch data/known_bugs.json in place with the proposed additions."""
    doc = json.loads(BUGS_JSON.read_text())
    doc.setdefault("bugs", [])
    by_id = {row["issue_id"]: row for row in doc["bugs"]}
    for row in to_json_format(proposed):
        if row["issue_id"] in by_id:
            continue
        doc["bugs"].append(row)
    from datetime import date
    doc["last_reviewed"] = date.today().isoformat()
    # Stable sort: by major, then minor desc, then id.
    doc["bugs"].sort(key=lambda r: (r["issue_id"].split("-")[0], -int(r["fixed_in_minor"]), r["issue_id"]))
    BUGS_JSON.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")


# ---------- CLI ----------

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--propose", action="store_true", default=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    p.add_argument("--yes", action="store_true")
    p.add_argument("--majors", default=",".join(DEFAULT_MAJORS))
    p.add_argument("--revisions-back", type=int, default=DEFAULT_REVISIONS_BACK)
    p.add_argument("--top-per-major", type=int, default=DEFAULT_TOP_PER_MAJOR)
    p.add_argument(
        "--min-severity", choices=["low", "medium", "high"], default="medium",
        help="drop entries below this severity band (default medium)",
    )
    p.add_argument(
        "--index-url", default=PGDG_RELEASE_INDEX,
        help="release-notes index URL (override for testing)",
    )
    p.add_argument("--user-agent", default=DEFAULT_USER_AGENT)
    args = p.parse_args(argv)

    majors = [m.strip() for m in args.majors.split(",") if m.strip()]

    # ---- Fetch release index ----
    try:
        index_html = _fetch(args.index_url, user_agent=args.user_agent)
    except Exception as exc:
        print(f"scout: index fetch failed: {exc}", file=sys.stderr)
        return 2

    recent = list_recent_releases(index_html, majors=majors, revisions_back=args.revisions_back)
    if not any(recent.values()):
        print("scout: index returned no recent releases for our majors", file=sys.stderr)
        return 2

    # ---- Fetch each candidate release page ----
    all_entries: list[dict] = []
    skipped: list[str] = []
    for major in majors:
        minors = recent.get(major, [])
        # Take the most recent N releases per major.
        for minor in minors[-args.revisions_back:]:
            url = f"{PGDG_DOCS_BASE}/release/{major}.{minor}/"
            try:
                html = _fetch(url, user_agent=args.user_agent)
            except Exception as exc:
                print(f"scout: page fetch failed {major}.{minor}: {exc}", file=sys.stderr)
                continue
            if html is None:
                # 404 / 410 — PGDG indexing gap. Skip and continue.
                skipped.append(f"{major}.{minor}")
                continue
            all_entries.extend(parse_release_page(
                html, major=major, minor=minor, doc_link=url,
            ))

    if skipped and args.check:
        for s in skipped:
            print(f"scout: skipped {s} (404/410 from PGDG)", file=sys.stderr)

    # ---- Filter + propose ----
    existing = load_existing()
    proposed = filter_proposed(
        all_entries, existing,
        majors=majors,
        min_severity=args.min_severity,
        top_per_major=args.top_per_major,
    )
    cleaned = to_json_format(proposed)

    # ---- Mode dispatch ----
    if args.check:
        if cleaned:
            print(f"FAIL: {len(cleaned)} new bug-fix proposal(s) pending review", file=sys.stderr)
            print(json.dumps(cleaned, indent=2, ensure_ascii=False))
            return 1
        print("ok: no new bug-fix proposals pending")
        return 0

    if args.write:
        if not cleaned:
            print("scout: --write invoked but no new proposals", file=sys.stderr)
            return 0
        if not args.yes:
            print("scout: --write requires --yes to confirm overwrite of data/known_bugs.json", file=sys.stderr)
            return 2
        merge_into_data(proposed)
        print(f"scout: wrote {len(cleaned)} entry/entries into {BUGS_JSON.relative_to(REPO_ROOT)}")
        return 0

    print(json.dumps(cleaned, indent=2, ensure_ascii=False))
    if cleaned:
        majors_repr = ",".join(majors)
        print(
            f"\n# ({len(cleaned)} proposal(s); min severity {args.min_severity}; majors {majors_repr}; "
            f"top {args.top_per_major}/major)",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
