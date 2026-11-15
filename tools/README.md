# pgFirstAid SQL generation tools

Canonical helper SQL and CVE/known-bug data feed the three standalone SQL installers.

## What's here

```text
data/
 cves.json curated CVE entries (one source of truth)
 known_bugs.json curated non-CVE release-note bugs
 agent_prompt.sql canonical pgfirstaid_agent_prompt function
 view_installer.sql canonical _pgfirstaid_install_view function
tools/
 sync_sql_helpers.py embeds canonical helpers in standalone SQL installers
 generate_cve_sql.py reads JSON → writes VALUES rows into the SQL files
 scrape_pgdg.py fetches PGDG security index, proposes new CVEs
 scrape_release_notes.py fetches PGDG release notes, proposes notable bugs
 tests/
 test_sync_sql_helpers.py temporary-repo helper generation and validation tests
 test_generate_cve_sql.py unit tests for the generator
 test_scrape_pgdg.py PGDG scraper + filter tests with fixtures
 test_scrape_release_notes.py release-notes scraper + filter tests with fixtures
 fixtures/
 pgdg_index_synthetic.html hand-written two-CVE fixture
 pgdg_index_realistic.html snapshot of the live PGDG security index
 release_notes_synthetic.html hand-written six-listitem fixture
 release_index_realistic.html snapshot of the live release-notes index
.github/workflows/
 cve-data-sync.yml CI drift check: fails if SQL files are out of sync with JSON
 pgdg-cve-scraper.yml Weekly PGDG security scrape → opens a PR
 release-notes-scout.yml Weekly PGDG release-notes scout → opens a PR
```

## Edit shared SQL helpers

Edit only `data/agent_prompt.sql` or `data/view_installer.sql`, then regenerate:

```bash
uv run python tools/sync_sql_helpers.py
uv run python tools/sync_sql_helpers.py --check
uv run python -m pytest tools/tests/test_sync_sql_helpers.py
```

The prompt helper appears in all three root installers.
The view installer helper appears only in `view_pgFirstAid.sql` and `view_pgFirstAid_managed.sql`.
Their embedded functions remain generated release artifacts, so each installer still works alone without runtime file dependencies.

The tool replaces only `-- GENERATED agent_prompt BEGIN/END` and `-- GENERATED view_installer BEGIN/END` blocks.
On the first run, it wraps uniquely identified unmarked helper functions.
It validates every source and target before writing, preserves unrelated SQL and CVE/bug blocks byte-for-byte, and leaves current files untouched.
`--check` never writes and exits nonzero for drift, missing helpers, or malformed blocks.
Restore invalid helper boundaries before rerunning; the tool does not guess.
Use `--root /path/to/repo` to target a temporary repository fixture.

## How to add a CVE

Edit `data/cves.json` and add an entry:

```text
{
 "cve_id": "CVE-2027-NNNNN",
 "cvss": 7.5,
 "summary": "Short description matching the PGDG advisory.",
 "doc_link": "https://www.postgresql.org/support/security/CVE-2027-NNNNN/",
 "fixed_in": {"15": 7, "16": 4, "17": 1}
}
```

Inclusions rule: PG 15-18 only, CVSS ≥ 7.0. The map's keys are PostgreSQL **major** version strings; values are the first patched **minor** number. A CVE missing a major simply doesn't appear for that major.

Then run:

```bash
uv run python tools/generate_cve_sql.py
```

This rewrites the inline VALUES rows in `pgFirstAid.sql`, `view_pgFirstAid.sql`, and `view_pgFirstAid_managed.sql`. Commit the diff and open a PR.

## How to add a known bug

Same idea in `data/known_bugs.json`:

```json
{
 "issue_id": "PG16-NEW-BUG-XX",
 "summary": "Short description.",
 "doc_link": "https://www.postgresql.org/docs/release/16.3/",
 "fixed_in_minor": 3
}
```

Each bug entry covers exactly one major (`issue_id` starts with `PG<MAJOR>`). Run the generator, commit, push.

## CI check

`.github/workflows/cve-data-sync.yml` runs `python tools/generate_cve_sql.py --check` on every push and PR. If the SQL files would change when regenerated, the job fails: which means a PR forgot to run the generator after editing the JSON.

## Manual flags

```bash
python tools/generate_cve_sql.py            # write fresh rows into all SQL files
python tools/generate_cve_sql.py --check    # exit non-zero if any file is stale (CI mode)
```

The generator is idempotent: running it twice with no JSON changes writes identical bytes and reports `ok <file>` for each file.

## Why inline VALUES, not a runtime lookup

The install promise is "paste one SQL file": no DB-side privileges, no disk dependency. The trade-off is curation.
