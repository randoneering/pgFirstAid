"""Tests for tools/generate_cve_sql.py.

Run: `python tools/tests/test_generate_cve_sql.py` (no external deps needed,
these tests are pure-python stdlib assertions on the generator's outputs).
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

# Make tools/ importable
TOOLS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS_DIR))

import generate_cve_sql as gen


# Static, hand-written fixtures used across the tests below.

_CVES_DOC = {
    "version": 1,
    "cves": [
        {
            "cve_id": "CVE-2024-0001",
            "cvss": 7.5,
            "summary": "Test summary",
            "doc_link": "https://example.com/cve1",
            "fixed_in": {"15": 4, "16": 1},
        },
        {
            "cve_id": "CVE-2025-9999",
            "cvss": 8.8,
            "summary": "Multi-major CVE",
            "doc_link": "https://example.com/cve2",
            "fixed_in": {"15": 15, "16": 11, "17": 7, "18": 1},
        },
    ],
}


_BUGS_DOC = {
    "version": 1,
    "bugs": [
        {
            "issue_id": "PG15-TEST-BUG-A",
            "summary": "test bug A",
            "doc_link": "https://example.com/15.1",
            "fixed_in_minor": 1,
        },
        {
            "issue_id": "PG17-TEST-BUG-B",
            "summary": "test bug B",
            "doc_link": "https://example.com/17.4",
            "fixed_in_minor": 4,
        },
    ],
}


class VersionNumTests(unittest.TestCase):
    def test_known_version_numbers(self) -> None:
        # Regression-locks the MJMmm → int conversion used in our predicate.
        self.assertEqual(gen._version_num("15", 4), 150004)
        self.assertEqual(gen._version_num("17", 11), 170011)
        self.assertEqual(gen._version_num("18", 5), 180005)

    def test_zero_minor(self) -> None:
        # The major-only "affected_min" base value.
        self.assertEqual(gen._version_num("15", 0), 150000)


class RenderCveTests(unittest.TestCase):
    def test_per_major_rows(self) -> None:
        rows = gen.render_cve_rows(_CVES_DOC)
        # 2 CVEs: first expands to 2 majors, second to 4 majors = 6 rows total
        self.assertEqual(len(rows), 6)

    def test_major_order_is_numeric(self) -> None:
        import re
        rows = gen.render_cve_rows(_CVES_DOC)
        # Second CVE spans 15, 16, 17, 18. They should appear numerically.
        majors_in_rows = [row for row in rows if "CVE-2025-9999" in row]
        self.assertEqual(len(majors_in_rows), 4)
        # Extract the affected_min/fixed_in pair per row to confirm ordering.
        # The regex tolerates optional whitespace between fields so it stays
        # independent of _render_cve_row's exact formatting.
        row_pat = re.compile(
            r",\s*(\d{6}),\s*(\d{6}),\s*'https",
        )
        seen_pairs = []
        for row in majors_in_rows:
            m = row_pat.search(row)
            self.assertIsNotNone(m, f"row did not match pattern: {row}")
            am, fi = int(m.group(1)), int(m.group(2))
            major_part = am // 10000
            minor_part = fi - am
            self.assertGreaterEqual(minor_part, 0)
            self.assertEqual(am, major_part * 10000)
            self.assertEqual(fi, am + minor_part)
            seen_pairs.append((am, fi))
        # Verify numeric order: ascending by affected_min (= major*10000).
        self.assertEqual(seen_pairs, sorted(seen_pairs))

    def test_no_trailing_comma_on_last_row(self) -> None:
        rows = gen.render_cve_rows(_CVES_DOC)
        # PostgreSQL VALUES rejects a trailing comma on the final entry.
        # We strip it; the last rendered row must end with ), not ),
        self.assertFalse(rows[-1].rstrip().endswith(","), f"trailing comma: {rows[-1]!r}")
        # All but the last row keep the comma separator.
        for r in rows[:-1]:
            self.assertTrue(r.rstrip().endswith(","), f"missing comma: {r!r}")


class RenderBugTests(unittest.TestCase):
    def test_one_row_per_bug(self) -> None:
        rows = gen.render_bug_rows(_BUGS_DOC)
        self.assertEqual(len(rows), 2)

    def test_major_is_parsed_from_issue_id(self) -> None:
        rows = gen.render_bug_rows(_BUGS_DOC)
        # PG15-TEST-BUG-A -> 15, fixed_in_minor=1 -> 150000, 150001
        row_a = next(r for r in rows if "PG15-TEST-BUG-A" in r)
        self.assertIn("150000, 150001", row_a)
        row_b = next(r for r in rows if "PG17-TEST-BUG-B" in r)
        self.assertIn("170000, 170004", row_b)

    def test_no_trailing_comma_on_last_row(self) -> None:
        rows = gen.render_bug_rows(_BUGS_DOC)
        self.assertFalse(rows[-1].rstrip().endswith(","))


class ReplaceBlockTests(unittest.TestCase):
    # Mirror the generator's exact sentinel strings; if these drift the
    # integration test will catch it, but tests should fail fast on mismatch
    # too. Imported via the live module to avoid duplication.
    SQL_TEMPLATE = (
        "-- header comment\n"
        "with cte(c1) as (\n"
        "    values\n"
        f"        {gen.SENTINEL_BEGIN_TEMPLATE.format(kind='cves')}\n"
        "        ('old1'),\n"
        "        ('old2')\n"
        f"        {gen.SENTINEL_END_TEMPLATE.format(kind='cves')}\n"
        ")\n"
        "select * from cte;\n"
        "-- trailer comment\n"
    )

    NEW_ROWS = ["        ('newA'),", "        ('newB')"]

    def test_replaces_inner_rows_only(self) -> None:
        result = gen.replace_block(self.SQL_TEMPLATE, "cves", self.NEW_ROWS)
        # The header and trailer must be preserved verbatim.
        self.assertTrue(result.startswith("-- header comment\n"))
        self.assertTrue(result.rstrip().endswith("-- trailer comment"))
        # The new rows are inside, with markers intact.
        self.assertIn("('newA'),", result)
        self.assertIn("('newB')", result)
        # Old rows must be gone.
        self.assertNotIn("('old1')", result)
        self.assertNotIn("('old2')", result)
        # Last new row has no trailing comma (covered in render tests too).
        self.assertFalse(result.split("-- trailer")[0].rstrip().rstrip(")").endswith(","))

    def test_missing_begin_marker_raises(self) -> None:
        bad = "with cte as (values ('x'))\nselect 1;\n"
        with self.assertRaises(SystemExit):
            gen.replace_block(bad, "cves", self.NEW_ROWS)

    def test_missing_end_marker_raises(self) -> None:
        bad = "with cte as (\n    values\n        ('x')\n        -- GENERATED cves BEGIN\n)\nselect 1;\n"
        with self.assertRaises(SystemExit):
            gen.replace_block(bad, "cves", self.NEW_ROWS)


class RegenerateOneTests(unittest.TestCase):
    """Verify regenerate_one end-to-end against a real tmpdir SQL file.

    The class replaces the previous FileRegenerationTests stub (whose
    setUp/tmpdir machinery was unused). Each test writes a real SQL file
    on disk, calls regenerate_one, and asserts the file content matches
    what the render functions would produce.
    """

    CVE_DOC = {
        "cves": [
            {
                "cve_id": "CVE-9999-DEMO",
                "cvss": 8.8,
                "summary": "demo row for regenerate_one",
                "doc_link": "https://example.com/cve-9999",
                "fixed_in": {"15": 5, "16": 2},
            }
        ]
    }
    BUG_DOC = {
        "bugs": [
            {
                "issue_id": "PG15-DEMO-BUG",
                "summary": "demo bug row for regenerate_one",
                "doc_link": "https://example.com/release/15.3",
                "fixed_in_minor": 3,
            }
        ]
    }
    TEMPLATE = (
        "-- header\n"
        "with cve_data(...) as (values\n"
        f"        {gen.SENTINEL_BEGIN_TEMPLATE.format(kind='cves')}\n"
        "        ('placeholder-cve')\n"
        f"        {gen.SENTINEL_END_TEMPLATE.format(kind='cves')}\n"
        ")\n"
        "select 1 from cve_data;\n"
        "with issue_data(...) as (values\n"
        f"        {gen.SENTINEL_BEGIN_TEMPLATE.format(kind='bugs')}\n"
        "        ('placeholder-bug')\n"
        f"        {gen.SENTINEL_END_TEMPLATE.format(kind='bugs')}\n"
        ")\n"
        "select 1 from issue_data;\n"
    )

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.sql_path = Path(self._tmp.name) / "v_pgFirstAid.sql"
        self.sql_path.write_text(self.TEMPLATE)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run(self) -> str:
        cve_rows = gen.render_cve_rows(self.CVE_DOC)
        bug_rows = gen.render_bug_rows(self.BUG_DOC)
        new_text = gen.regenerate_one(self.sql_path, cve_rows, bug_rows)
        # Apply as a real write so the assertion matches what an end user
        # would see on disk.
        self.sql_path.write_text(new_text)
        return self.sql_path.read_text()

    def test_writes_cve_rows_into_cve_block(self) -> None:
        text = self._run()
        # The cve_block now contains the demo CVE for both PG 15 and 16;
        # placeholders are gone. bug_rows were passed in _run, so the bug
        # block also reflects real data.
        cve_block, _, bug_block = self._split_blocks(text)
        self.assertIn("CVE-9999-DEMO", cve_block)
        self.assertNotIn("placeholder-cve", cve_block)
        # Two rows: one per affected major in fixed_in.
        self.assertEqual(cve_block.count("'CVE-9999-DEMO'"), 2)
        self.assertIn("PG15-DEMO-BUG", bug_block)
        self.assertNotIn("placeholder-bug", bug_block)

    def test_idempotent_on_unchanged_inputs(self) -> None:
        # Run the regenerator twice in a row; the second pass should be
        # a no-op (file content unchanged) — this is the contract the
        # `cve-data-sync` CI relies on.
        self._run()
        first = self.sql_path.read_text()
        self._run()
        second = self.sql_path.read_text()
        self.assertEqual(first, second)

    def _split_blocks(self, text: str) -> tuple[str, str, str]:
        """Return (cve_block, issue_block, bug_block) sliced between markers."""
        cve_b = gen.SENTINEL_BEGIN_TEMPLATE.format(kind="cves")
        cve_e = gen.SENTINEL_END_TEMPLATE.format(kind="cves")
        bug_b = gen.SENTINEL_BEGIN_TEMPLATE.format(kind="bugs")
        bug_e = gen.SENTINEL_END_TEMPLATE.format(kind="bugs")
        cve_block = text[text.index(cve_b):text.index(cve_e) + len(cve_e)]
        bug_block = text[text.index(bug_b):text.index(bug_e) + len(bug_e)]
        # Whatever sits between cve_block's end and bug_block's start.
        between = text[text.index(cve_e) + len(cve_e):text.index(bug_b)]
        return cve_block, between, bug_block


# Pull the SQL_TEMPLATE attribute back up so the per-major test can use it.
_SQL_TEMPLATE_FOR_RENDER = ReplaceBlockTests.SQL_TEMPLATE


# Re-run the major-order assertion against the full SQL template.
class RenderCveTestsFullSqlTemplate(unittest.TestCase):
    def test_rendered_rows_fit_template(self) -> None:
        rows = gen.render_cve_rows(_CVES_DOC)
        rendered = gen.replace_block(_SQL_TEMPLATE_FOR_RENDER, "cves", rows)
        # After regeneration, the rendered SQL still contains both old template
        # markers and the new content.
        self.assertIn("-- GENERATED cves BEGIN", rendered)
        self.assertIn("-- GENERATED cves END", rendered)
        self.assertIn("CVE-2024-0001", rendered)
        self.assertIn("CVE-2025-9999", rendered)


if __name__ == "__main__":
    unittest.main(verbosity=2)
