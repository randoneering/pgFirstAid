#!/usr/bin/env python3
"""Scrape the PostgreSQL security index and propose new CVE entries for data/cves.json.

Source of truth for the live CVE catalog:
    https://www.postgresql.org/support/security/?cve=title

Workflow:
  Default --propose    Fetch the index, parse out CVEs, print the proposed
                       additions vs. data/cves.json as a JSON snippet. No
                       files are modified.
  --check              CI mode: exit non-zero when any additions are
                       pending (the GitHub Action uses this to decide
                       whether to open a PR).
  --write --yes        Patch data/cves.json with the proposed additions.
                       Use --yes to skip the confirmation prompt.

Inclusion rule (matches project policy from prior conversation):
  - CVE must affect at least one of PG 15, 16, 17, 18 (--majors 15,16,17,18).
  - CVSS v3 base score must be >= 7.0 (--min-cvss 7.0).
  - Skip CVEs already in data/cves.json.

No external deps: uses urllib.request + stdlib re. The HTML is small and
table-uniform, so we regex over the rendered page rather than depend on
BeautifulSoup. The HTML structure can shift if PGDG redesigns: when that
happens, the unit-test fixtures will catch it and we'll tighten the regex.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

PGDG_URL = "https://www.postgresql.org/support/security/?cve=title"
PGDG_BASE = "https://www.postgresql.org"

REPO_ROOT = Path(__file__).resolve().parent.parent
CVES_JSON = REPO_ROOT / "data" / "cves.json"

DEFAULT_MIN_CVSS = 7.0
DEFAULT_MAJORS = ["15", "16", "17", "18"]
DEFAULT_USER_AGENT = "pgFirstAid-scraper/0.1 (+https://github.com/bringnow/pgFirstAid)"


# ---------- HTML helper ----------

def _strip_html(s: str) -> str:
    """Drop tags, decode common entities, collapse whitespace."""
    s = re.sub(r"<[^>]+>", "", s)
    s = (s.replace("&amp;", "&")
           .replace("&lt;", "<")
           .replace("&gt;", ">")
           .replace("&quot;", '"')
           .replace("&#39;", "'")
           .replace("&nbsp;", " "))
    return re.sub(r"\s+", " ", s).strip()


# ---------- Parsing ----------

# PGDG index page renders the CVE catalog as the first <table class="table
# table-striped"> with a <thead>/<tbody> pair. We capture the table body and
# pull each <tr>; each row has exactly 5 <td> cells.
_TABLE_BODY_RE = re.compile(
    r'<table class="table table-striped">\s*<thead>.*?</thead>\s*<tbody>(.*?)</tbody>\s*</table>',
    re.DOTALL,
)
_ROW_RE = re.compile(r"<tr>(.*?)</tr>", re.DOTALL)
_TD_RE = re.compile(r"<td[^>]*>(.*?)</td>", re.DOTALL)

_CVE_LINK_RE = re.compile(r'href="(/support/security/(CVE-\d{4}-\d+)/)"')
_CVSS_RE = re.compile(
    r'href="https://nvd\.nist\.gov/vuln-metrics[^"]*"[^>]*>([0-9.]+)</a>'
)
_VERSION_RE = re.compile(r"^(\d+)\.(\d+)$")


def parse_pgdg_table(html_text: str) -> list[dict]:
    """Parse the PGDG security index and return one dict per CVE entry.

    Returned dict shape:
      {
        "cve_id":     "CVE-YYYY-NNNN",
        "cvss":       float,
        "summary":    str,                # one-line description from the index
        "doc_link":   "https://www.postgresql.org/support/security/CVE-YYYY-NNNN/",
        "fixed_in":   {"15": 19, "16": 15, "17": 11, "18": 5},  # subset for our majors
        "affected":   ["15","16","17","18"],  # raw major list (debug)
        "fixed_raw":  ["15.19","16.15",...], # raw version list (debug)
      }
    """
    m = _TABLE_BODY_RE.search(html_text)
    if not m:
        raise RuntimeError("PGDG index table not found; markup may have changed")
    body = m.group(1)

    entries: list[dict] = []
    for row_match in _ROW_RE.finditer(body):
        cells = _TD_RE.findall(row_match.group(1))
        if len(cells) != 5:
            continue  # skip thead/sub-header rows / malformed rows

        # ----- Cell 0: Reference -----
        cve_m = _CVE_LINK_RE.search(cells[0])
        if not cve_m:
            continue
        cve_id = cve_m.group(2)
        doc_link = PGDG_BASE + cve_m.group(1)

        # ----- Cell 1: Affected majors -----
        affected_str = _strip_html(cells[1])
        affected_majors = [m.strip() for m in affected_str.split(",") if m.strip()]
        if not affected_majors:
            continue

        # ----- Cell 2: Fixed versions (positional to Affected) -----
        fixed_str = _strip_html(cells[2])
        fixed_versions = [m.strip() for m in fixed_str.split(",") if m.strip()]
        if len(fixed_versions) != len(affected_majors):
            # Out-of-sync table; bail on this row rather than mis-map.
            continue

        fixed_in: dict[str, int] = {}
        for major, version in zip(affected_majors, fixed_versions):
            if major not in DEFAULT_MAJORS:
                continue  # skip majors outside our supported range
            vm = _VERSION_RE.match(version)
            if not vm or int(vm.group(1)) != int(major):
                continue  # malformed "X.Y" or major/version mismatch in upstream table
            fixed_in[major] = int(vm.group(2))

        if not fixed_in:
            continue  # no impact on PG 15-18

        # ----- Cell 3: Component + CVSS score -----
        cvss_m = _CVSS_RE.search(cells[3])
        if not cvss_m:
            continue
        try:
            cvss = float(cvss_m.group(1))
        except ValueError:
            continue

        # ----- Cell 4: Description -----
        summary = _strip_html(cells[4])
        summary = re.sub(r"\s*more details\s*$", "", summary, flags=re.IGNORECASE)
        if not summary:
            continue

        entries.append({
            "cve_id": cve_id,
            "cvss": cvss,
            "summary": summary,
            "doc_link": doc_link,
            "fixed_in": fixed_in,
            # Internal fields for downstream tooling (the writer strips these).
            "_affected": affected_majors,
            "_fixed_raw": fixed_versions,
        })
    return entries


# ---------- Filtering ----------

def filter_proposed(
    entries: list[dict],
    existing: list[dict],
    *,
    min_cvss: float,
    majors: list[str],
) -> list[dict]:
    """Return entries that should be ADDED to data/cves.json.

    Rule: must affect at least one of `majors`, must be at least `min_cvss`,
    must not already be present by cve_id.
    """
    majors_set = set(majors)
    existing_ids = {row["cve_id"] for row in existing}
    additions: list[dict] = []
    for entry in entries:
        if entry["cve_id"] in existing_ids:
            continue  # already curated
        if entry["cvss"] < min_cvss:
            continue  # below severity threshold
        if not (set(entry["fixed_in"]) & majors_set):
            continue  # doesn't affect any of our majors
        additions.append(entry)
    # Highest CVSS first; deterministic tiebreaker on id.
    additions.sort(key=lambda e: (-e["cvss"], e["cve_id"]))
    return additions


def to_json_format(proposed: list[dict]) -> list[dict]:
    """Strip internal fields; return only the keys the JSON schema uses."""
    return [
        {
            "cve_id": p["cve_id"],
            "cvss": p["cvss"],
            "summary": p["summary"],
            "doc_link": p["doc_link"],
            "fixed_in": p["fixed_in"],
        }
        for p in proposed
    ]


# ---------- File IO ----------

def load_existing() -> list[dict]:
    if not CVES_JSON.exists():
        return []
    return json.loads(CVES_JSON.read_text()).get("cves", [])


def merge_into_data(proposed: list[dict]) -> None:
    """Patch data/cves.json in place with the proposed additions."""
    doc = json.loads(CVES_JSON.read_text())
    doc.setdefault("cves", [])
    by_id = {row["cve_id"]: row for row in doc["cves"]}
    for row in to_json_format(proposed):
        if row["cve_id"] in by_id:
            continue
        doc["cves"].append(row)
    # Bump last_reviewed.
    from datetime import date
    doc["last_reviewed"] = date.today().isoformat()
    # Re-sort: by CVSS desc, then cve_id, for stable diffs.
    doc["cves"].sort(key=lambda r: (-float(r["cvss"]), r["cve_id"]))
    CVES_JSON.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")


# ---------- HTTP ----------

def _resolve_cafile() -> str | None:
    """Find a usable CA bundle, or None to fall back to system default.

    Some Python builds (notably Python 3.14 on Nix) ship with ssl.get_default_verify_paths()
    pointing at /etc/ssl/cert.pem that doesn't exist, which makes urllib
    fail with CERTIFICATE_VERIFY_FAILED. We try a few well-known paths.
    """
    import ssl
    import os
    candidates = [
        os.environ.get("SSL_CERT_FILE"),
        os.environ.get("CURL_CA_BUNDLE"),
        "/etc/ssl/certs/ca-certificates.crt",      # Debian/Ubuntu/GitHub Actions
        "/etc/ssl/certs/ca-bundle.crt",             # RHEL/CentOS
        "/etc/pki/tls/certs/ca-bundle.crt",         # older RHEL
        "/etc/ssl/cert.pem",                         # macOS / some Python distros
    ]
    for path in candidates:
        if path and os.path.exists(path):
            return path
    # Fall back to whatever Python's ssl layer thinks is correct.
    default = ssl.get_default_verify_paths()
    return default.cafile or (default.capath if os.path.isdir(default.capath or "") else None)


def fetch_pgdg_index(user_agent: str = DEFAULT_USER_AGENT, timeout: float = 30.0) -> str:
    import ssl
    ctx = ssl.create_default_context()
    cafile = _resolve_cafile()
    if cafile and os.path.isfile(cafile):
        ctx.load_verify_locations(cafile)
    elif cafile and os.path.isdir(cafile):
        ctx.load_verify_locations(capath=cafile)
    req = urllib.request.Request(
        PGDG_URL,
        headers={"User-Agent": user_agent, "Accept": "text/html,application/xhtml+xml"},
    )
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        return resp.read().decode("utf-8", "replace")


# ---------- CLI ----------

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--propose", action="store_true", default=True,
                      help="print proposed additions as JSON (default)")
    mode.add_argument("--check", action="store_true",
                      help="CI mode: exit non-zero when additions are pending")
    mode.add_argument("--write", action="store_true",
                      help="patch data/cves.json with proposed additions (use with --yes)")
    p.add_argument("--yes", action="store_true",
                   help="skip confirmation prompt for --write")
    p.add_argument("--min-cvss", type=float, default=DEFAULT_MIN_CVSS,
                   help=f"include CVEs at or above this CVSS v3 score (default {DEFAULT_MIN_CVSS})")
    p.add_argument("--majors", default=",".join(DEFAULT_MAJORS),
                   help=f"comma-separated PG major versions to consider (default {','.join(DEFAULT_MAJORS)})")
    p.add_argument("--url", default=PGDG_URL, help="PGDG URL (override for testing)")
    p.add_argument("--user-agent", default=DEFAULT_USER_AGENT,
                   help="User-Agent header for the HTTP request")
    args = p.parse_args(argv)

    majors = [m.strip() for m in args.majors.split(",") if m.strip()]

    # ---- Fetch + parse ----
    try:
        html = fetch_pgdg_index(user_agent=args.user_agent)
    except Exception as exc:
        print(f"scraper: HTTP fetch failed: {exc}", file=sys.stderr)
        return 2

    try:
        entries = parse_pgdg_table(html)
    except RuntimeError as exc:
        print(f"scraper: parse failed: {exc}", file=sys.stderr)
        return 2

    # ---- Filter + propose ----
    existing = load_existing()
    proposed = filter_proposed(entries, existing, min_cvss=args.min_cvss, majors=majors)
    cleaned = to_json_format(proposed)

    # ---- Mode dispatch ----
    if args.check:
        if cleaned:
            print(f"FAIL: {len(cleaned)} new CVE(s) pending for review "
                  f"(see data/cves.json and propose output)", file=sys.stderr)
            print(json.dumps(cleaned, indent=2, ensure_ascii=False))
            return 1
        print("ok: no new CVEs pending")
        return 0

    if args.write:
        if not cleaned:
            print("scraper: --write invoked but no new CVEs to add", file=sys.stderr)
            return 0
        if not args.yes:
            print("scraper: --write requires --yes to confirm overwrite of data/cves.json", file=sys.stderr)
            return 2
        merge_into_data(proposed)
        print(f"scraper: wrote {len(cleaned)} entry/entries into {CVES_JSON.relative_to(REPO_ROOT)}")
        return 0

    # Default: print proposed as JSON
    print(json.dumps(cleaned, indent=2, ensure_ascii=False))
    if cleaned:
        print(f"\n# ({len(cleaned)} proposed addition(s); threshold CVSS >= {args.min_cvss}, majors {majors})",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
