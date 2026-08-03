-- =============================================================================
-- AAA Snowflake SQL Training — Module 1: Querying Data
-- 01_querying_data.sql
--
-- Topics covered:
--   1. Snowflake SQL Features (QUALIFY, FLATTEN, OBJECT_CONSTRUCT, TRY_CAST)
--   2. Query Profile — what to look for
--   3. Time Travel — AT, BEFORE, UNDROP
--   4. Zero-Copy Cloning
--   5. Caching — metadata, result, and warehouse cache
--
-- Prerequisites: Run 00_setup_data.sql first
-- =============================================================================

USE WAREHOUSE TRAINING_WH;
USE DATABASE AAA_TRAINING;
USE SCHEMA MEMBER_SERVICES;

-- ============================================================
-- SECTION 1: Snowflake SQL Features
-- ============================================================

-- ------------------------------------------------------------
-- DEMO 1.1: QUALIFY — filter on a window function result
--            without a subquery
-- ------------------------------------------------------------
-- Without QUALIFY (standard SQL — requires subquery)
SELECT member_id, full_name, state, join_date,
       ROW_NUMBER() OVER (PARTITION BY state ORDER BY join_date) AS rn
FROM   MEMBERS
WHERE  status = 'Active'
QUALIFY rn = 1;  -- <-- Snowflake extension: filter AFTER window function

-- Equivalent without QUALIFY (more verbose)
SELECT member_id, full_name, state, join_date
FROM (
    SELECT member_id, full_name, state, join_date,
           ROW_NUMBER() OVER (PARTITION BY state ORDER BY join_date) AS rn
    FROM   MEMBERS
    WHERE  status = 'Active'
)
WHERE rn = 1;

-- QUALIFY in action: top-3 most expensive assists per state
SELECT
    state,
    assist_id,
    issue_type,
    cost,
    RANK() OVER (PARTITION BY state ORDER BY cost DESC) AS cost_rank
FROM ROADSIDE_ASSISTS
WHERE resolved_flag = TRUE
QUALIFY cost_rank <= 3
ORDER BY state, cost_rank;

-- ------------------------------------------------------------
-- DEMO 1.2: LATERAL FLATTEN — unpack VARIANT/JSON arrays
-- ------------------------------------------------------------
-- Inspect the benefits VARIANT column structure
SELECT plan_name, benefits FROM MEMBERSHIP_PLANS;

-- FLATTEN to turn JSON array elements into rows
SELECT
    p.plan_name,
    f.value::VARCHAR  AS benefit
FROM MEMBERSHIP_PLANS p,
LATERAL FLATTEN(input => p.benefits) f
ORDER BY p.plan_id, f.index;

-- Flatten semi-structured weather data from roadside assists
-- See what fields exist inside the VARIANT
SELECT weather FROM ROADSIDE_ASSISTS LIMIT 5;

SELECT
    assist_id,
    issue_type,
    weather:conditions::VARCHAR   AS conditions,
    weather:temp_f::INTEGER       AS temp_f,
    weather:precip_in::FLOAT      AS precipitation_in,
    weather:wind_mph::INTEGER     AS wind_mph
FROM ROADSIDE_ASSISTS
LIMIT 20;

-- Aggregate: average response time by weather condition
SELECT
    weather:conditions::VARCHAR          AS weather_condition,
    COUNT(*)                             AS assist_count,
    ROUND(AVG(response_time_min), 1)     AS avg_response_min,
    ROUND(AVG(cost), 2)                  AS avg_cost
FROM ROADSIDE_ASSISTS
WHERE resolved_flag = TRUE
  AND weather:conditions IS NOT NULL
GROUP BY 1
ORDER BY avg_response_min DESC;

-- ------------------------------------------------------------
-- DEMO 1.3: OBJECT_CONSTRUCT — build JSON from relational cols
-- ------------------------------------------------------------
-- Construct a member summary object on the fly
SELECT
    member_id,
    OBJECT_CONSTRUCT(
        'name',   full_name,
        'tier',   membership_tier,
        'state',  state,
        'status', status
    ) AS member_profile
FROM MEMBERS
LIMIT 5;

-- ------------------------------------------------------------
-- DEMO 1.4: TRY_CAST — safe type conversion (no errors)
-- ------------------------------------------------------------
-- Simulate a column that contains mixed values
SELECT
    TRY_CAST('42'        AS INTEGER),    -- returns 42
    TRY_CAST('hello'     AS INTEGER),    -- returns NULL (no error!)
    TRY_CAST('2024-01-15' AS DATE),      -- returns date
    TRY_CAST('not-a-date' AS DATE);      -- returns NULL (no error!)

-- Practical example: safe cast on adjuster_notes content
SELECT
    claim_id,
    adjuster_notes:priority::VARCHAR                         AS priority,
    TRY_CAST(adjuster_notes:follow_up::VARCHAR AS BOOLEAN)  AS follow_up_flag
FROM CLAIMS
LIMIT 10;

-- ------------------------------------------------------------
-- DEMO 1.5: IFF and DECODE shortcuts
-- ------------------------------------------------------------
-- IFF: inline IF/ELSE (cleaner than CASE for simple conditions)
SELECT
    member_id,
    full_name,
    status,
    IFF(status = 'Active', 'Yes', 'No')                          AS is_active,
    DECODE(membership_tier,
        'Basic',   '$7/mo',
        'Plus',    '$11/mo',
        'Premier', '$15/mo',
        'Unknown'
    )                                                            AS monthly_cost
FROM MEMBERS
LIMIT 20;

-- ============================================================
-- SECTION 2: Query Profile — what to look for
-- ============================================================

-- DEMO 2.1: Run a query that will show interesting profile data.
--           After running, click "Query Profile" in Snowsight.
--
--           Things to look for in the profile:
--           - "Bytes Scanned" vs "Bytes Scanned From Cache"
--           - Partition pruning (Partitions Scanned vs Total)
--           - Spilling to local/remote storage (warning sign)
--           - Long-running operators (wide bars in timeline)

SELECT
    m.state,
    m.membership_tier,
    COUNT(DISTINCT m.member_id)            AS member_count,
    COUNT(ra.assist_id)                    AS total_assists,
    ROUND(AVG(ra.response_time_min), 1)    AS avg_response_min,
    ROUND(SUM(ra.cost), 2)                 AS total_assist_cost,
    COUNT(c.claim_id)                      AS total_claims,
    ROUND(SUM(c.amount), 2)                AS total_claim_amount
FROM MEMBERS m
    LEFT JOIN ROADSIDE_ASSISTS ra ON m.member_id = ra.member_id
    LEFT JOIN CLAIMS c            ON m.member_id = c.member_id
WHERE m.status = 'Active'
GROUP BY 1, 2
ORDER BY total_assists DESC;

-- After running: open Snowsight → History → this query → Query Profile

-- ============================================================
-- SECTION 3: Time Travel
-- ============================================================

-- DEMO 3.1: Setup — modify data so we have something to travel back to
-- Note the current timestamp first
SELECT CURRENT_TIMESTAMP() AS before_update;

-- Update some members (this creates a new micro-version)
UPDATE MEMBERS
SET    status = 'Lapsed'
WHERE  membership_tier = 'Basic'
  AND  state = 'CA'
  AND  status = 'Active'
  AND  UNIFORM(0,10,RANDOM()) < 2;   -- randomly flip ~20% of Basic CA members

-- Check how many rows changed
SELECT COUNT(*) AS current_lapsed_basic_ca
FROM MEMBERS
WHERE membership_tier = 'Basic'
  AND state = 'CA'
  AND status = 'Lapsed';

-- DEMO 3.2: AT(OFFSET) — travel back N seconds
-- (Adjust the offset as needed based on when you ran the update)
SELECT COUNT(*) AS members_5_seconds_ago
FROM MEMBERS AT(OFFSET => -60)   -- 60 seconds ago
WHERE membership_tier = 'Basic'
  AND state = 'CA'
  AND status = 'Active';

-- DEMO 3.3: AT(TIMESTAMP) — travel to a specific point in time
-- Replace this timestamp with the value from the SELECT CURRENT_TIMESTAMP() above
SET before_ts = '2025-01-01 10:00:00';  -- Replace with your actual timestamp

SELECT COUNT(*) AS members_before_update
FROM MEMBERS AT(TIMESTAMP => $before_ts::TIMESTAMP_NTZ)
WHERE membership_tier = 'Basic'
  AND state = 'CA'
  AND status = 'Active';

-- DEMO 3.4: BEFORE(STATEMENT) — travel to before a specific statement
-- Get the last query ID from the UPDATE above
SELECT LAST_QUERY_ID() AS update_query_id;

-- Use that query ID to look at data before the update
SELECT COUNT(*) AS members_before_the_update
FROM MEMBERS BEFORE(STATEMENT => LAST_QUERY_ID())
WHERE membership_tier = 'Basic'
  AND state = 'CA'
  AND status = 'Active';

-- DEMO 3.5: Restore from Time Travel — undo the update
CREATE OR REPLACE TABLE MEMBERS AS
SELECT * FROM MEMBERS BEFORE(STATEMENT => LAST_QUERY_ID(-2));

-- Verify restore
SELECT COUNT(*) AS active_basic_ca_restored
FROM MEMBERS
WHERE membership_tier = 'Basic' AND state = 'CA' AND status = 'Active';

-- DEMO 3.6: UNDROP — recover a dropped table
DROP TABLE CLAIMS;
-- Verify it's gone
SHOW TABLES LIKE 'CLAIMS';

-- Recover it!
UNDROP TABLE CLAIMS;
-- Verify recovery
SHOW TABLES LIKE 'CLAIMS';
SELECT COUNT(*) FROM CLAIMS;  -- Data is fully intact

-- ============================================================
-- SECTION 4: Zero-Copy Cloning
-- ============================================================

-- DEMO 4.1: Clone a table for development — instant, zero storage overhead
CREATE OR REPLACE TABLE MEMBERS_DEV
    CLONE MEMBERS
    COMMENT = 'Development copy of MEMBERS — zero-copy clone';

-- Verify the clone looks identical
SELECT COUNT(*) AS original_count FROM MEMBERS;
SELECT COUNT(*) AS clone_count     FROM MEMBERS_DEV;

-- DEMO 4.2: Modify the clone without affecting the original
UPDATE MEMBERS_DEV SET membership_tier = 'Premier' WHERE member_id <= 100;

-- Original is unchanged
SELECT COUNT(*) AS original_premier
FROM MEMBERS WHERE membership_tier = 'Premier' AND member_id <= 100;

-- Clone is modified
SELECT COUNT(*) AS clone_premier
FROM MEMBERS_DEV WHERE membership_tier = 'Premier' AND member_id <= 100;

-- DEMO 4.3: Clone a schema (zero-copy copy of ALL tables at once!)
CREATE SCHEMA IF NOT EXISTS MEMBER_SERVICES_DEV
    CLONE MEMBER_SERVICES
    COMMENT = 'Schema-level clone for dev/test environment';

-- Inspect what was cloned
SHOW TABLES IN SCHEMA MEMBER_SERVICES_DEV;

-- DEMO 4.4: Clean up clones
DROP TABLE MEMBERS_DEV;
DROP SCHEMA MEMBER_SERVICES_DEV;

-- ============================================================
-- SECTION 5: Caching
-- ============================================================

-- DEMO 5.1: Metadata cache — COUNT(*) and MIN/MAX skip data scan
-- These return instantly from metadata — no warehouse needed
SELECT COUNT(*)         AS total_members    FROM MEMBERS;
SELECT MIN(join_date)   AS earliest_member  FROM MEMBERS;
SELECT MAX(join_date)   AS latest_member    FROM MEMBERS;

-- DEMO 5.2: Result cache — exact same query returns instantly
-- Run this query twice and compare the execution time in history

-- First run (cold — warehouse does work)
SELECT
    state,
    membership_tier,
    COUNT(*)            AS members,
    AVG(
        DATEDIFF(day, join_date, CURRENT_DATE())
    )                   AS avg_tenure_days
FROM MEMBERS
WHERE status = 'Active'
GROUP BY 1, 2
ORDER BY 1, 2;

-- Second run immediately after — should show "Results returned from cache"
-- in the Query Profile. Executes in ~0ms.
SELECT
    state,
    membership_tier,
    COUNT(*)            AS members,
    AVG(
        DATEDIFF(day, join_date, CURRENT_DATE())
    )                   AS avg_tenure_days
FROM MEMBERS
WHERE status = 'Active'
GROUP BY 1, 2
ORDER BY 1, 2;

-- DEMO 5.3: Bypass result cache with a different predicate
-- Even a tiny change (different filter) means cache miss
SELECT
    state,
    membership_tier,
    COUNT(*)  AS members
FROM MEMBERS
WHERE status = 'Active'
  AND YEAR(join_date) >= 2020  -- <-- different predicate = cache miss
GROUP BY 1, 2
ORDER BY 1, 2;

-- DEMO 5.4: Check query history to see caching in action
-- Run in Snowsight — compare "Bytes Scanned From Cache" vs "Bytes Scanned"
SELECT
    query_text,
    bytes_scanned,
    bytes_scanned_from_cache,
    ROUND(bytes_scanned_from_cache / NULLIF(bytes_scanned,0) * 100, 1)
        AS cache_hit_pct,
    total_elapsed_time / 1000.0  AS elapsed_sec
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_text ILIKE '%MEMBERS%'
  AND start_time >= DATEADD(hour, -1, CURRENT_TIMESTAMP())
  AND bytes_scanned > 0
ORDER BY start_time DESC
LIMIT 20;
