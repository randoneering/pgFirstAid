-- pgFirstAid seed: structural and static checks
-- Idempotent. Run against the pgfirstaid_test database.
-- Drops and recreates the pgfirstaid_seed schema on each run.

DROP SCHEMA IF EXISTS pgfirstaid_seed CASCADE;
CREATE SCHEMA pgfirstaid_seed;

-- ============================================================
-- CRITICAL: Missing Primary Key
-- ============================================================
CREATE TABLE pgfirstaid_seed.no_pk_table (
    data text
);
INSERT INTO pgfirstaid_seed.no_pk_table
SELECT md5(g::text) FROM generate_series(1, 100) g;

-- ============================================================
-- CRITICAL: Unused Large Index (threshold patched to >8KB)
-- Index is created but never scanned (idx_scan = 0).
-- ============================================================
CREATE TABLE pgfirstaid_seed.unused_idx_table (
    id bigint PRIMARY KEY,
    payload text NOT NULL
);
INSERT INTO pgfirstaid_seed.unused_idx_table
SELECT g, repeat(md5(g::text), 4)
FROM generate_series(1, 10000) g;
CREATE INDEX pgfirstaid_seed_unused_large_idx
    ON pgfirstaid_seed.unused_idx_table (payload);
ANALYZE pgfirstaid_seed.unused_idx_table;
-- Deliberately not querying this index.

-- ============================================================
-- HIGH: Duplicate Indexes
-- Two indexes with identical column sets on the same table.
-- ============================================================
CREATE TABLE pgfirstaid_seed.dup_idx_table (
    id bigint PRIMARY KEY,
    val int NOT NULL
);
INSERT INTO pgfirstaid_seed.dup_idx_table
SELECT g, g % 1000 FROM generate_series(1, 10000) g;
CREATE INDEX pgfirstaid_seed_dup_idx_a ON pgfirstaid_seed.dup_idx_table (val);
CREATE INDEX pgfirstaid_seed_dup_idx_b ON pgfirstaid_seed.dup_idx_table (val);
ANALYZE pgfirstaid_seed.dup_idx_table;

-- ============================================================
-- HIGH: Table with 201 columns (threshold is >200)
-- ============================================================
DO $$
DECLARE
    col_list text := 'id bigint PRIMARY KEY';
    i int;
BEGIN
    FOR i IN 1..200 LOOP
        col_list := col_list || ', col_' || i || ' text';
    END LOOP;
    EXECUTE 'CREATE TABLE pgfirstaid_seed.wide_table_201 (' || col_list || ')';
END $$;

-- ============================================================
-- HIGH: Missing Statistics
-- Table with >1000 modifications, never analyzed.
-- autovacuum disabled to prevent background analyze.
-- ============================================================
CREATE TABLE pgfirstaid_seed.no_stats_table (
    id bigint,
    payload text
) WITH (autovacuum_enabled = false);
INSERT INTO pgfirstaid_seed.no_stats_table
SELECT g, md5(g::text) FROM generate_series(1, 2000) g;
-- Deliberately NOT running ANALYZE.

-- ============================================================
-- HIGH: Tables larger than 100GB (threshold patched to >1MB)
-- ~300 bytes/row * 20000 rows ≈ 6MB, safely above 1MB.
-- ============================================================
CREATE TABLE pgfirstaid_seed.large_table (
    id bigint PRIMARY KEY,
    payload text NOT NULL
);
INSERT INTO pgfirstaid_seed.large_table
SELECT g, repeat(md5(g::text), 8)
FROM generate_series(1, 20000) g;
ANALYZE pgfirstaid_seed.large_table;

-- ============================================================
-- MEDIUM: Tables larger than 50GB (threshold patched to 512KB–1MB)
-- ~100 bytes/row * 7000 rows ≈ 700KB, inside the 512KB–1MB band.
-- ============================================================
CREATE TABLE pgfirstaid_seed.medium_table (
    id bigint PRIMARY KEY,
    payload text NOT NULL
);
INSERT INTO pgfirstaid_seed.medium_table
SELECT g, repeat(md5(g::text), 2)
FROM generate_series(1, 7000) g;
ANALYZE pgfirstaid_seed.medium_table;

-- ============================================================
-- MEDIUM: Outdated Statistics
-- Dead tuples exceed autovacuum threshold; no vacuum runs.
-- With 10000 rows: vacuum threshold = 0.2*10000+50 = 2050.
-- After UPDATE all rows: n_dead_tup ≈ 10000 > 2050.
-- ============================================================
CREATE TABLE pgfirstaid_seed.dead_tuples_table (
    id bigint PRIMARY KEY,
    payload text
) WITH (autovacuum_enabled = false);
INSERT INTO pgfirstaid_seed.dead_tuples_table
SELECT g, md5(g::text) FROM generate_series(1, 10000) g;
ANALYZE pgfirstaid_seed.dead_tuples_table;
UPDATE pgfirstaid_seed.dead_tuples_table SET payload = md5(payload);
-- No VACUUM - dead tuples stay.

-- ============================================================
-- MEDIUM: Table with more than 50 columns (50-199 range)
-- ============================================================
DO $$
DECLARE
    col_list text := 'id bigint PRIMARY KEY';
    i int;
BEGIN
    FOR i IN 1..59 LOOP
        col_list := col_list || ', col_' || i || ' text';
    END LOOP;
    EXECUTE 'CREATE TABLE pgfirstaid_seed.wide_table_60 (' || col_list || ')';
END $$;

-- ============================================================
-- MEDIUM: Low Index Efficiency
-- idx_scan > 100 AND idx_tup_read/idx_scan > 1000.
-- grp has 5 distinct values over 50000 rows:
--   each scan with grp = X reads ~10000 tuples.
-- 110 scans * 10000 tuples/scan -> ratio = 10000 >> 1000.
-- ============================================================
CREATE TABLE pgfirstaid_seed.low_eff_idx_table (
    id bigint PRIMARY KEY,
    grp int NOT NULL,
    payload text
);
INSERT INTO pgfirstaid_seed.low_eff_idx_table
SELECT g, g % 5, md5(g::text)
FROM generate_series(1, 50000) g;
CREATE INDEX pgfirstaid_seed_low_eff_idx
    ON pgfirstaid_seed.low_eff_idx_table (grp);
ANALYZE pgfirstaid_seed.low_eff_idx_table;

DO $$
DECLARE
    dummy bigint;
BEGIN
    FOR i IN 1..110 LOOP
        SELECT count(*) INTO dummy
        FROM pgfirstaid_seed.low_eff_idx_table
        WHERE grp = (i % 5);
    END LOOP;
END $$;

-- ============================================================
-- MEDIUM: Excessive Sequential Scans
-- seq_scan > 1000 AND seq_tup_read > seq_scan * 10000.
-- 15000 rows * 1002 scans = 15,030,000 tuples read.
-- Threshold: 1002 * 10000 = 10,020,000. 15,030,000 > 10,020,000.
-- index scan disabled inside DO block to force seq scan.
-- ============================================================
CREATE TABLE pgfirstaid_seed.seq_scan_table (
    id bigint PRIMARY KEY,
    payload text
);
INSERT INTO pgfirstaid_seed.seq_scan_table
SELECT g, md5(g::text)
FROM generate_series(1, 15000) g;
ANALYZE pgfirstaid_seed.seq_scan_table;

DO $$
DECLARE
    dummy bigint;
BEGIN
    SET LOCAL enable_indexscan = off;
    SET LOCAL enable_bitmapscan = off;
    FOR i IN 1..1002 LOOP
        SELECT count(*) INTO dummy
        FROM pgfirstaid_seed.seq_scan_table
        WHERE id > 0;
    END LOOP;
END $$;

-- ============================================================
-- LOW: Missing FK Index
-- FK on parent_id with no supporting index.
-- ============================================================
CREATE TABLE pgfirstaid_seed.fk_parent_table (
    id bigint PRIMARY KEY
);
INSERT INTO pgfirstaid_seed.fk_parent_table
SELECT g FROM generate_series(1, 100) g;

CREATE TABLE pgfirstaid_seed.fk_child_table (
    id bigint PRIMARY KEY,
    parent_id bigint REFERENCES pgfirstaid_seed.fk_parent_table (id)
    -- Deliberately no index on parent_id.
);

-- ============================================================
-- LOW: Table With Single Or No Columns
-- ============================================================
CREATE TABLE pgfirstaid_seed.single_col_table (
    only_col text
);

-- ============================================================
-- LOW: Table With No Activity Since Stats Reset
-- Created but never read or written; all stat counters stay at 0.
-- ============================================================
CREATE TABLE pgfirstaid_seed.inactive_table (
    id bigint PRIMARY KEY,
    data text
);
-- Deliberately not inserting, updating, or querying.

-- ============================================================
-- LOW: Role Never Logged In
-- Role has LOGIN privilege but has never connected.
-- Drop first so re-runs start clean (roles are cluster-level,
-- not dropped by DROP SCHEMA CASCADE).
-- ============================================================
DROP ROLE IF EXISTS pgfirstaid_seed_role;
-- PASSWORD NULL: the check fires on schema structure, not authentication.
CREATE ROLE pgfirstaid_seed_role LOGIN PASSWORD NULL;

-- ============================================================
-- LOW: Empty Table
-- reltuples = 0 AND n_live_tup = 0.
-- ============================================================
CREATE TABLE pgfirstaid_seed.empty_table (
    id bigint PRIMARY KEY,
    data text
);
ANALYZE pgfirstaid_seed.empty_table;

-- ============================================================
-- LOW: Index With Very Low Usage
-- idx_scan > 0 AND idx_scan < 100 AND pg_relation_size > 1MB.
-- 25000 rows * ~70 bytes/row ≈ 1.75MB index, safely above 1MB threshold.
-- Run five top-level lookups so pg_stat_user_indexes records visible scans.
-- ============================================================
CREATE TABLE pgfirstaid_seed.low_usage_idx_table (
    id bigint PRIMARY KEY,
    search_key text NOT NULL
);
INSERT INTO pgfirstaid_seed.low_usage_idx_table
SELECT g, md5(g::text)
FROM generate_series(1, 25000) g;
CREATE INDEX pgfirstaid_seed_low_usage_idx
    ON pgfirstaid_seed.low_usage_idx_table (search_key);
ANALYZE pgfirstaid_seed.low_usage_idx_table;

SELECT id FROM pgfirstaid_seed.low_usage_idx_table
WHERE search_key = md5('1')
LIMIT 1;

SELECT id FROM pgfirstaid_seed.low_usage_idx_table
WHERE search_key = md5('2')
LIMIT 1;

SELECT id FROM pgfirstaid_seed.low_usage_idx_table
WHERE search_key = md5('3')
LIMIT 1;

SELECT id FROM pgfirstaid_seed.low_usage_idx_table
WHERE search_key = md5('4')
LIMIT 1;

SELECT id FROM pgfirstaid_seed.low_usage_idx_table
WHERE search_key = md5('5')
LIMIT 1;

-- ============================================================
-- Lock target for live session threads (blocker/blocked checks).
-- ============================================================
CREATE TABLE pgfirstaid_seed.lock_target (
    id int PRIMARY KEY,
    payload text
);
INSERT INTO pgfirstaid_seed.lock_target (id, payload) VALUES (1, 'seed');
