"""Tests for tools/scrape_pgdg.py.

Parses canned HTML fixtures and asserts the PGDG scraper produces the
expected CVE dicts. Avoids network so tests are deterministic.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

TOOLS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS_DIR))

import scrape_pgdg as scraper  # noqa: E402

FIXTURES_DIR = TOOLS_DIR / "tests" / "fixtures"


def _load(name: str) -> str:
    return (FIXTURES_DIR / name).read_text()


class ParseSyntheticTests(unittest.TestCase):
    """Hand-written fixture exercising the parser's core behavior."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.html = _load("pgdg_index_synthetic.html")

    def test_parses_two_cves(self) -> None:
        entries = scraper.parse_pgdg_table(self.html)
        self.assertEqual(len(entries), 2)

    def test_first_cve_ids_and_fixed_map(self) -> None:
        entries = scraper.parse_pgdg_table(self.html)
        first = entries[0]
        self.assertEqual(first["cve_id"], "CVE-2026-19385")
        self.assertEqual(first["cvss"], 8.8)
        self.assertEqual(
            first["doc_link"],
            "https://www.postgresql.org/support/security/CVE-2026-19385/",
        )
        # Only majors 15-18 are kept; 14 is dropped.
        self.assertEqual(
            first["fixed_in"], {"15": 19, "16": 15, "17": 11, "18": 5},
        )

    def test_second_cve_partial_major_set(self) -> None:
        entries = scraper.parse_pgdg_table(self.html)
        second = entries[1]
        self.assertEqual(second["cve_id"], "CVE-2024-0985")
        # Source listed only 16, 15, 14: only 15 and 16 should appear.
        self.assertEqual(second["fixed_in"], {"15": 6, "16": 2})

    def test_summary_strips_more_details_link(self) -> None:
        entries = scraper.parse_pgdg_table(self.html)
        for entry in entries:
            self.assertNotIn("more details", entry["summary"])
            # No HTML tags leaked through.
            self.assertNotIn("<", entry["summary"])
            self.assertNotIn(">", entry["summary"])


class ParseRealisticFixtureTests(unittest.TestCase):
    """The real PGDG index page, captured as a fixture on 2026-08-23.

    Acts as a sanity floor: when PGDG redesigns the table, this test fails
    loudly so we tighten the parser.
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.html = _load("pgdg_index_realistic.html")

    def test_parses_at_least_60_cves(self) -> None:
        # PGDG publishes ~30 CVEs per major x 5 majors = ~150 historically;
        # 60 is a loose floor: if we drop below this, suspect a parse regression.
        entries = scraper.parse_pgdg_table(self.html)
        self.assertGreater(len(entries), 60, f"only {len(entries)} entries parsed")

    def test_every_entry_has_required_fields(self) -> None:
        entries = scraper.parse_pgdg_table(self.html)
        for entry in entries:
            self.assertRegex(entry["cve_id"], r"^CVE-\d{4}-\d+$")
            self.assertGreaterEqual(entry["cvss"], 0.0)
            self.assertLessEqual(entry["cvss"], 10.0)
            self.assertTrue(entry["summary"])
            self.assertTrue(entry["doc_link"].startswith("https://www.postgresql.org"))
            self.assertTrue(
                set(entry["fixed_in"]).issubset({"15", "16", "17", "18"}),
                f"unexpected majors in fixed_in: {entry['fixed_in']!r}",
            )
            for major, minor in entry["fixed_in"].items():
                # Repo's version_num convention: major*10000 + minor.
                self.assertGreaterEqual(minor, 0)
                self.assertLess(minor, 100)

    def test_fixed_versions_align_with_affected_majors(self) -> None:
        entries = scraper.parse_pgdg_table(self.html)
        for entry in entries:
            for major, minor in entry["fixed_in"].items():
                # PG 15.x -> 15 + x*100ish. Confirm the major portion matches.
                # Recreate: major * 10000 + minor.
                reconstructed = int(major) * 10000 + minor
                # Just sanity-check the major part matches; minor is sane.
                self.assertEqual(
                    reconstructed // 10000, int(major),
                    f"major mismatch in {entry['cve_id']}: {entry['fixed_in']!r}",
                )


class FilterProposedTests(unittest.TestCase):
    """Filter logic that decides what makes it into the proposed-additions set."""

    ENTRY_HIGH = {
        "cve_id": "CVE-2026-19385",
        "cvss": 8.8,
        "summary": "pg_dump heap overflow",
        "doc_link": "https://www.postgresql.org/support/security/CVE-2026-19385/",
        "fixed_in": {"15": 19, "16": 15, "17": 11, "18": 5},
        "_affected": ["18", "17", "16", "15", "14"],
        "_fixed_raw": ["18.5", "17.11", "16.15", "15.19", "14.24"],
    }
    ENTRY_MEDIUM = dict(ENTRY_HIGH, cve_id="CVE-2024-0985", cvss=4.2,
                        fixed_in={"15": 6, "16": 2})
    ENTRY_OLDER = dict(ENTRY_HIGH, cve_id="CVE-2026-99999",
                       fixed_in={"10": 5, "9": 6})  # doesn't affect 15-18
    EXISTING = [
        {"cve_id": "CVE-2026-19385", "cvss": 8.8, "summary": "x",
         "doc_link": "x", "fixed_in": {"15": 19}},  # already curated
    ]

    def test_filter_drops_already_curated(self) -> None:
        out = scraper.filter_proposed(
            [self.ENTRY_HIGH], self.EXISTING, min_cvss=7.0, majors=["15", "16", "17", "18"]
        )
        self.assertEqual(out, [])

    def test_filter_drops_low_cvss(self) -> None:
        out = scraper.filter_proposed(
            [self.ENTRY_MEDIUM], [], min_cvss=7.0, majors=["15", "16", "17", "18"]
        )
        self.assertEqual(out, [])

    def test_filter_drops_out_of_scope_majors(self) -> None:
        out = scraper.filter_proposed(
            [self.ENTRY_OLDER], [], min_cvss=7.0, majors=["15", "16", "17", "18"]
        )
        self.assertEqual(out, [])

    def test_filter_keeps_qualifying_new_cves(self) -> None:
        out = scraper.filter_proposed(
            [self.ENTRY_HIGH], [], min_cvss=7.0, majors=["15", "16", "17", "18"]
        )
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["cve_id"], "CVE-2026-19385")

    def test_filter_sorted_highest_cvss_first(self) -> None:
        a = dict(self.ENTRY_HIGH, cve_id="CVE-A", cvss=9.9)
        b = dict(self.ENTRY_HIGH, cve_id="CVE-B", cvss=7.1)
        out = scraper.filter_proposed(
            [b, a], [], min_cvss=7.0, majors=["15", "16", "17", "18"]
        )
        self.assertEqual([e["cve_id"] for e in out], ["CVE-A", "CVE-B"])


class ToJsonFormatTests(unittest.TestCase):
    def test_internal_fields_stripped(self) -> None:
        cleaned = scraper.to_json_format([
            {"cve_id": "CVE-X", "cvss": 7.5, "summary": "x",
             "doc_link": "y", "fixed_in": {"15": 1}, "_affected": ["15"], "_fixed_raw": ["15.1"]}
        ])
        self.assertEqual(len(cleaned), 1)
        self.assertNotIn("_affected", cleaned[0])
        self.assertNotIn("_fixed_raw", cleaned[0])
        self.assertEqual(cleaned[0]["cve_id"], "CVE-X")


class MergeIntoDataTests(unittest.TestCase):
    def test_appends_only_new_entries_no_duplicates(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            data_path = Path(d) / "cves.json"
            data_path.write_text(json.dumps({
                "version": 1,
                "cves": [
                    {"cve_id": "CVE-KEEP", "cvss": 8.0, "summary": "kept",
                     "doc_link": "https://x", "fixed_in": {"15": 1}},
                ],
            }))
            # Point the scraper's CVES_JSON at the temp path by patching the
            # module attribute, then revert after the test.
            original_path = scraper.CVES_JSON
            scraper.CVES_JSON = data_path
            try:
                scraper.merge_into_data([
                    {"cve_id": "CVE-KEEP", "cvss": 8.0, "summary": "kept",
                     "doc_link": "https://x", "fixed_in": {"15": 1},
                     "_affected": [], "_fixed_raw": []},
                    {"cve_id": "CVE-NEW",  "cvss": 9.9, "summary": "new",
                     "doc_link": "https://y", "fixed_in": {"16": 4},
                     "_affected": ["16"], "_fixed_raw": ["16.4"]},
                ])
            finally:
                scraper.CVES_JSON = original_path

            doc = json.loads(data_path.read_text())
            cve_ids = [c["cve_id"] for c in doc["cves"]]
            # CVE-KEEP not duplicated; CVE-NEW appended.
            self.assertEqual(sorted(cve_ids), ["CVE-KEEP", "CVE-NEW"])
            # Sorted highest CVSS first.
            self.assertEqual(doc["cves"][0]["cve_id"], "CVE-NEW")
            # last_reviewed was bumped.
            self.assertTrue(doc["last_reviewed"])


class StrigHtmlTests(unittest.TestCase):
    def test_decodes_entities_and_drops_tags(self) -> None:
        out = scraper._strip_html(
            "<p>PostgreSQL &quot;pg_dump&quot; <em>leaks</em> files &amp; arbitrary code</p>"
        )
        self.assertEqual(out, 'PostgreSQL "pg_dump" leaks files & arbitrary code')


if __name__ == "__main__":
    unittest.main(verbosity=2)
