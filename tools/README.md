# pgFirstAid CVE data tools

Source-of-truth data + generator for the inline CVE and known-bug VALUES rows that live inside the three SQL install scripts.

## What's here

```
data/
 cves.json curated CVE entries (one source of truth)
 known_bugs.json curated non-CVE release-note bugs
tools/
 generate_cve_sql.py reads JSON → writes VALUES rows into the SQL files
 scrape_pgdg.py fetches PGDG security index, proposes new CVEs
 scrape_release_notes.py fetches PGDG release notes, proposes notable bugs
 tests/
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

## How to add a CVE

Edit `data/cves.json` and add an entry:

```json
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

```
python tools/generate_cve_sql.py # write fresh rows into all SQL files
python tools/generate_cve_sql.py --check # exit non-zero if any file is stale (CI mode)
```

The generator is idempotent: running it twice with no JSON changes writes identical bytes and reports `ok <file>` for each file.

## Why inline VALUES, not a runtime lookup

The project's install promise is "paste one SQL file." A runtime `pg_read_file()` lookup would require `pg_read_server_files` privilege, a known file path, and a network-or-disk dependency at query time. Inline VALUES give us a fully offline, no-extra-privilege install.

The trade-off is curation: every row is reviewed-by-hand and added to JSON. The weekly scraper (next section) keeps it current.
