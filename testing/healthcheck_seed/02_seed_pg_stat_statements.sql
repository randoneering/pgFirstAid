-- pgFirstAid seed: pg_stat_statements workload checks
-- Requires pg_stat_statements to be preload-enabled and extension installed.
-- This script uses psql \gexec to issue many top-level statements.

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT pg_stat_statements_reset();

CREATE SCHEMA IF NOT EXISTS pgfirstaid_seed;

DROP TABLE IF EXISTS pgfirstaid_seed.pss_rows_table CASCADE;
DROP TABLE IF EXISTS pgfirstaid_seed.pss_wal_table CASCADE;
DROP TABLE IF EXISTS pgfirstaid_seed.pss_temp_table CASCADE;

CREATE TABLE pgfirstaid_seed.pss_rows_table (
    id bigint PRIMARY KEY,
    grp int NOT NULL,
    payload text
);
INSERT INTO pgfirstaid_seed.pss_rows_table (id, grp, payload)
SELECT g, (g % 10), repeat(md5(g::text), 3)
FROM generate_series(1, 300000) AS g;
CREATE INDEX pss_rows_table_grp_idx ON pgfirstaid_seed.pss_rows_table(grp);
ANALYZE pgfirstaid_seed.pss_rows_table;

CREATE TABLE pgfirstaid_seed.pss_wal_table (
    id bigint PRIMARY KEY,
    payload text
);
INSERT INTO pgfirstaid_seed.pss_wal_table (id, payload)
SELECT g, repeat(md5(g::text), 15)
FROM generate_series(1, 15000) AS g;
ANALYZE pgfirstaid_seed.pss_wal_table;

CREATE TABLE pgfirstaid_seed.pss_temp_table (
    id bigint PRIMARY KEY,
    sort_key int NOT NULL,
    payload text NOT NULL
);
INSERT INTO pgfirstaid_seed.pss_temp_table (id, sort_key, payload)
SELECT g, (random() * 1000000)::int, repeat(md5(g::text), 4)
FROM generate_series(1, 200000) AS g;
ANALYZE pgfirstaid_seed.pss_temp_table;

-- High mean execution time (>=20 calls and >100ms)
SELECT 'SELECT pg_sleep(0.12);'
FROM generate_series(1, 25)
\gexec

-- High runtime variance (stddev > mean)
SELECT CASE
         WHEN g % 10 = 0 THEN 'SELECT pg_sleep(1.2);'
         ELSE 'SELECT pg_sleep(0.005);'
       END
FROM generate_series(1, 100) AS g
\gexec

-- High calls, low value (>=5000 calls, <=2ms mean, <=2 rows/call)
SELECT 'SELECT 1;'
FROM generate_series(1, 6000)
\gexec

-- High rows per call (>10000 rows/call, >=20 calls)
SELECT 'SELECT count(*) FROM pgfirstaid_seed.pss_rows_table WHERE grp IN (0,1,2,3,4,5,6,7,8,9);'
FROM generate_series(1, 25)
\gexec

-- Shared block reads per call and low cache hit ratio candidates.
-- On smaller systems results are less deterministic because cache behavior is environment-specific.
SET enable_indexscan = off;
SET enable_bitmapscan = off;
SELECT 'SELECT sum(length(payload)) FROM pgfirstaid_seed.pss_rows_table WHERE id > 0;'
FROM generate_series(1, 30)
\gexec

-- Temp block spills (sort large set with low work_mem)
SET work_mem = '64kB';
SELECT 'SELECT sort_key, payload FROM pgfirstaid_seed.pss_temp_table ORDER BY sort_key DESC LIMIT 120000;'
FROM generate_series(1, 25)
\gexec

-- High WAL bytes per call (>1MB/call)
SELECT format(
  $$UPDATE pgfirstaid_seed.pss_wal_table
    SET payload = md5(payload || '%s') || repeat(md5('%s'), 12)
    WHERE id %% 3 = 0;$$,
  g,
  g
)
FROM generate_series(1, 25) AS g
\gexec

SELECT
    check_name,
    count(*) AS findings
FROM pg_firstAid()
WHERE check_name IN (
    'Top 10 Queries by Total Execution Time',
    'High Mean Execution Time Queries',
    'Top 10 Queries by Temp Block Spills',
    'Low Cache Hit Ratio Queries',
    'High Runtime Variance Queries',
    'High Calls Low Value Queries',
    'High Rows Per Call Queries',
    'High Shared Block Reads Per Call Queries',
    'Top Queries by WAL Bytes Per Call'
)
GROUP BY check_name
ORDER BY check_name;

RESET work_mem;
RESET enable_indexscan;
RESET enable_bitmapscan;
