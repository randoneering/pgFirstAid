"""Tests for tools/scrape_release_notes.py.

Frozen HTML fixtures + targeted unit tests for the parser, severity
classifier, and proposal-filter pipeline.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS_DIR))

import scrape_release_notes as scout  # noqa: E402

FIXTURES_DIR = TOOLS_DIR / "tests" / "fixtures"


def _load(name: str) -> str:
    return (FIXTURES_DIR / name).read_text()


# ---------- Page parser ----------

class ParseReleasePageTests(unittest.TestCase):

    @classmethod
    def setUpClass(cls) -> None:
        cls.html = _load("release_notes_synthetic.html")

    def test_parses_all_listitems(self) -> None:
        entries = scout.parse_release_page(
            self.html, major="17", minor="11",
            doc_link="https://www.postgresql.org/docs/release/17.11/",
        )
        self.assertEqual(len(entries), 6)

    def test_severity_classifier_flags_data_integrity(self) -> None:
        entries = scout.parse_release_page(
            self.html, major="17", minor="11",
            doc_link="x/",
        )
        # The memory-safety bugs entry
        mem_safety = next(e for e in entries if "memory-safety" in e["summary"])
        self.assertEqual(mem_safety["_severity"], "high")

    def test_severity_classifier_flags_crash(self) -> None:
        entries = scout.parse_release_page(self.html, major="17", minor="11", doc_link="x/")
        crash = next(e for e in entries if "crash" in e["summary"])
        self.assertEqual(crash["_severity"], "high")

    def test_severity_classifier_flags_replication_medium(self) -> None:
        entries = scout.parse_release_page(self.html, major="17", minor="11", doc_link="x/")
        repl = next(e for e in entries if "logical replication" in e["summary"])
        self.assertEqual(repl["_severity"], "medium")

    def test_severity_classifier_low_for_documentation(self) -> None:
        entries = scout.parse_release_page(self.html, major="17", minor="11", doc_link="x/")
        doc = next(e for e in entries if "documentation" in e["summary"])
        self.assertEqual(doc["_severity"], "low")

    def test_strips_trailing_author_attribution(self) -> None:
        entries = scout.parse_release_page(self.html, major="17", minor="11", doc_link="x/")
        for entry in entries:
            # "(Author Name)" should be trimmed from the summary.
            self.assertNotRegex(entry["summary"], r"\([A-Z][\w .'-]*(?:,.*?)*\)\s*$",
                                f"author not stripped: {entry['summary']!r}")

    def test_strips_trailing_section_marker(self) -> None:
        entries = scout.parse_release_page(self.html, major="17", minor="11", doc_link="x/")
        for entry in entries:
            # The section anchor at the end (from postgr.es/c/<hash>) is HTML,
            # but if our _strip_tags missed it the text would contain it.
            self.assertNotIn("sec.", entry["summary"])

    def test_stable_id_uses_commit_hash(self) -> None:
        entries = scout.parse_release_page(self.html, major="17", minor="11", doc_link="x/")
        mem_safety = next(e for e in entries if "memory-safety" in e["summary"])
        # Commit hash from URL is "a1b2c3d4e" → issue_id uses first 9 chars with major prefix.
        self.assertEqual(mem_safety["issue_id"], "PG17-a1b2c3d4e")
        self.assertEqual(mem_safety["_commit"], "a1b2c3d4e")

    def test_stable_id_falls_back_to_summary_hash(self) -> None:
        entries = scout.parse_release_page(self.html, major="17", minor="11", doc_link="x/")
        no_commit = next(e for e in entries if "no commit URL" in e["summary"])
        # digest is sha1("...")[:8]
        self.assertTrue(no_commit["issue_id"].startswith("PG17-FIX-"))
        self.assertEqual(len(no_commit["issue_id"].split("-")[-1]), 8)
        self.assertIsNone(no_commit["_commit"])


# ---------- Release-index parser ----------

class ListRecentReleasesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        # The realistic fixture is committed to the repo. If it's
        # missing (e.g. first-time contributor check-out), skip the
        # network-bootstrap fallback: tests should be deterministic and
        # not silently start hitting PGDG on every CI run.
        realistic = FIXTURES_DIR / "release_index_realistic.html"
        if not realistic.exists():
            raise unittest.SkipTest(
                f"missing fixture: {realistic}. Add the file before running this test."
            )
        cls.index_html = _load("release_index_realistic.html")

    def test_finds_per_major_minors(self) -> None:
        recent = scout.list_recent_releases(
            self.index_html, majors=["15", "16", "17", "18"],
            revisions_back=2,
        )
        for major in ("15", "16", "17", "18"):
            self.assertIn(major, recent)
            self.assertGreaterEqual(len(recent[major]), 2)
        # Each major's list is in ascending numeric order.
        for entries in recent.values():
            self.assertEqual(entries, sorted(entries, key=int))


# ---------- Filter pipeline ----------

class FilterProposedTests(unittest.TestCase):
    def _entries(self, ids_and_severities):
        return [
            {"issue_id": i, "_severity": s, "doc_link": "https://x/release/15.1/",
             "summary": i, "fixed_in_minor": 1, "_commit": None}
            for i, s in ids_and_severities
        ]

    def test_keeps_high_and_medium_by_default(self) -> None:
        all_entries = self._entries([("X", "high"), ("Y", "medium"), ("Z", "low")])
        out = scout.filter_proposed(
            all_entries, [],
            majors=["15"], min_severity="medium", top_per_major=10,
        )
        ids = {e["issue_id"] for e in out}
        self.assertEqual(ids, {"X", "Y"})

    def test_drop_threshold_low_only_returns_high(self) -> None:
        all_entries = self._entries([("X", "high"), ("Y", "medium"), ("Z", "low")])
        out = scout.filter_proposed(
            all_entries, [], majors=["15"], min_severity="high", top_per_major=10,
        )
        ids = {e["issue_id"] for e in out}
        self.assertEqual(ids, {"X"})

    def test_drop_threshold_low_returns_everything(self) -> None:
        all_entries = self._entries([("X", "high"), ("Y", "low")])
        out = scout.filter_proposed(
            all_entries, [], majors=["15"], min_severity="low", top_per_major=10,
        )
        ids = {e["issue_id"] for e in out}
        self.assertEqual(ids, {"X", "Y"})

    def test_dedupes_against_existing_by_id(self) -> None:
        all_entries = self._entries([("X", "high"), ("Y", "high")])
        existing = [{"issue_id": "X"}]
        out = scout.filter_proposed(
            all_entries, existing,
            majors=["15"], min_severity="medium", top_per_major=10,
        )
        ids = {e["issue_id"] for e in out}
        self.assertEqual(ids, {"Y"})

    def test_caps_per_major(self) -> None:
        all_entries = self._entries(
            [(f"PG15-X{i:02}", "high") for i in range(20)]
        )
        out = scout.filter_proposed(
            all_entries, [], majors=["15"], min_severity="high", top_per_major=5,
        )
        self.assertEqual(len(out), 5)

    def test_filters_by_major_scope(self) -> None:
        # Mix of PG 15 and PG 17 entries; with majors=[17] only the 17 ones come through.
        all_entries = (
            self._entries([("PG15-X", "high"), ("PG15-Y", "high")])
            + [
                {"issue_id": "PG17-Z", "_severity": "high",
                 "doc_link": "https://x/release/17.5/", "summary": "x",
                 "fixed_in_minor": 5, "_commit": None}
            ]
        )
        out = scout.filter_proposed(
            all_entries, [], majors=["17"], min_severity="medium", top_per_major=10,
        )
        ids = {e["issue_id"] for e in out}
        self.assertEqual(ids, {"PG17-Z"})

    def test_output_sorted_highest_severity_first(self) -> None:
        all_entries = self._entries(
            [("PG15-A", "low"), ("PG15-B", "high"), ("PG15-C", "medium")]
        )
        out = scout.filter_proposed(
            all_entries, [], majors=["15"], min_severity="low", top_per_major=10,
        )
        self.assertEqual([e["issue_id"] for e in out], ["PG15-B", "PG15-C", "PG15-A"])


class ToJsonFormatTests(unittest.TestCase):
    def test_internal_fields_stripped(self) -> None:
        cleaned = scout.to_json_format([
            {"issue_id": "PG15-X", "summary": "s", "doc_link": "u",
             "fixed_in_minor": 1, "_severity": "high", "_commit": "abcdefg"}
        ])
        self.assertEqual(len(cleaned), 1)
        self.assertNotIn("_severity", cleaned[0])
        self.assertNotIn("_commit", cleaned[0])
        self.assertEqual(cleaned[0]["issue_id"], "PG15-X")


class MergeIntoDataTests(unittest.TestCase):
    def test_appends_only_new_entries(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            data_path = Path(d) / "known_bugs.json"
            data_path.write_text(json.dumps({
                "version": 1, "last_reviewed": "2026-01-01",
                "bugs": [{"issue_id": "PG15-KEEP", "summary": "kept",
                          "doc_link": "https://x", "fixed_in_minor": 1}],
            }))
            original_path = scout.BUGS_JSON
            scout.BUGS_JSON = data_path
            try:
                scout.merge_into_data([
                    {"issue_id": "PG15-KEEP", "summary": "kept",
                     "doc_link": "https://x", "fixed_in_minor": 1,
                     "_severity": "high", "_commit": None},
                    {"issue_id": "PG15-NEW", "summary": "new",
                     "doc_link": "https://y", "fixed_in_minor": 4,
                     "_severity": "high", "_commit": None},
                ])
            finally:
                scout.BUGS_JSON = original_path

            doc = json.loads(data_path.read_text())
            ids = sorted(b["issue_id"] for b in doc["bugs"])
            self.assertEqual(ids, ["PG15-KEEP", "PG15-NEW"])
            self.assertTrue(doc["last_reviewed"] >= "2026-08-01")


class DocLinkMajorTests(unittest.TestCase):
    def test_extracts_major_from_doc_link(self) -> None:
        self.assertEqual(scout.doc_link_major("https://x/release/17.11/"), "17")
        self.assertEqual(scout.doc_link_major("https://x/release/15.19/"), "15")
        self.assertEqual(scout.doc_link_major(""), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
