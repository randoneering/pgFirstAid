-- 05_low_tests.sql: LOW severity health checks
BEGIN;
SELECT plan(8);

-- =============================================================================
-- Missing Foreign Key Index Tests
-- =============================================================================

-- Fixture: Parent table with PK
CREATE TABLE pgfirstaid_test.fk_parent (
    id serial PRIMARY KEY,
    name text
);

-- Fixture: Child table with FK but NO index on FK column
CREATE TABLE pgfirstaid_test.fk_child_no_idx (
    id serial PRIMARY KEY,
    parent_id integer REFERENCES pgfirstaid_test.fk_parent(id),
    data text
);

-- Test 1: Missing FK index detected by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Missing FK Index'
          AND object_name LIKE '%fk_child_no_idx%'
    ),
    'Function detects missing index on foreign key column'
);

-- Test 2: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Missing FK Index'
          AND object_name LIKE '%fk_child_no_idx%'
    ),
    'View detects missing index on foreign key column'
);

-- Test 3: Severity is LOW
SELECT is(
    (SELECT severity FROM pg_firstAid()
     WHERE check_name = 'Missing FK Index'
       AND object_name LIKE '%fk_child_no_idx%'
     LIMIT 1),
    'LOW',
    'Missing FK Index has LOW severity'
);

-- Test 4: View severity matches
SELECT is(
    (SELECT severity FROM v_pgfirstAid
     WHERE check_name = 'Missing FK Index'
       AND object_name LIKE '%fk_child_no_idx%'
     LIMIT 1),
    'LOW',
    'View: Missing FK Index has LOW severity'
);

-- =============================================================================
-- Negative Test: FK with supporting index
-- =============================================================================

-- Fixture: Child table with FK AND index on FK column
CREATE TABLE pgfirstaid_test.fk_child_with_idx (
    id serial PRIMARY KEY,
    parent_id integer REFERENCES pgfirstaid_test.fk_parent(id),
    data text
);
CREATE INDEX idx_fk_child_parent ON pgfirstaid_test.fk_child_with_idx(parent_id);

-- Test 5: FK with index not flagged by function
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Missing FK Index'
          AND object_name LIKE '%fk_child_with_idx%'
    ),
    'Function does not flag FK with supporting index'
);

-- Test 6: View parity
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Missing FK Index'
          AND object_name LIKE '%fk_child_with_idx%'
    ),
    'View does not flag FK with supporting index'
);

-- =============================================================================
-- Edge Case: Multi-column FK
-- =============================================================================

-- Fixture: Parent with composite PK
CREATE TABLE pgfirstaid_test.fk_parent_composite (
    a integer,
    b integer,
    name text,
    PRIMARY KEY (a, b)
);

-- Fixture: Child with composite FK but no index
CREATE TABLE pgfirstaid_test.fk_child_composite (
    id serial PRIMARY KEY,
    a integer,
    b integer,
    data text,
    FOREIGN KEY (a, b) REFERENCES pgfirstaid_test.fk_parent_composite(a, b)
);

-- Test 7: Multi-column FK without index detected by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Missing FK Index'
          AND object_name LIKE '%fk_child_composite%'
    ),
    'Function detects missing index on composite foreign key'
);

-- Test 8: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Missing FK Index'
          AND object_name LIKE '%fk_child_composite%'
    ),
    'View detects missing index on composite foreign key'
);

SELECT * FROM finish();
ROLLBACK;
