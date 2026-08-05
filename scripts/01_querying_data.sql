-- =============================================================================
-- AAA Snowflake SQL Training — Module 1: Querying Data
-- 01_querying_data.sql
--
-- HOW TO USE THIS SCRIPT:
--   Run each section one block at a time in Snowsight.
--   Each demo is labeled with ▶ RUN markers showing what to execute together.
--   Comments explain what to observe after each execution.
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

-- ▶ RUN: Set context (run once at the start of the session)
USE WAREHOUSE TRAINING_WH;
USE DATABASE AAA_TRAINING;
USE SCHEMA MEMBER_SERVICES;


-- ============================================================
-- SECTION 1: Snowflake SQL Features
-- ============================================================

-- ┌─────────────────────────────────────────────────────────┐
-- │ DEMO 1.1: QUALIFY                                       │
-- │ Filter on a window function result without a subquery.  │
-- │ This is a Snowflake-specific extension not in ANSI SQL. │
-- └─────────────────────────────────────────────────────────┘
-- ▶ RUN: Find the earliest-joined active member in each state (with QUALIFY)
--   Notice: no subquery needed — QUALIFY filters AFTER the window function.
SELECT
    member_id, full_name, state, join_date,
    ROW_NUMBER() OVER (PARTITION BY state ORDER BY join_date) AS rn
FROM MEMBERS
WHERE status = 'Active'
QUALIFY rn = 1;

-- ▶ RUN: Same result WITHOUT QUALIFY (standard SQL — requires a subquery wrapper)
SELECT member_id, full_name, state, join_date
FROM (
    SELECT member_id, full_name, state, join_date,
           ROW_NUMBER() OVER (PARTITION BY state ORDER BY join_date) AS rn
    FROM MEMBERS
    WHERE status = 'Active'
)
WHERE rn = 1;

-- ▶ RUN: Top-3 most expensive assists per state using QUALIFY
--   Observe: RANK() gives ties the same value; QUALIFY filters to top 3 per partition.
SELECT
    state, assist_id, issue_type, cost,
    RANK() OVER (PARTITION BY state ORDER BY cost DESC) AS cost_rank
FROM ROADSIDE_ASSISTS
WHERE resolved_flag = TRUE
QUALIFY cost_rank <= 3
ORDER BY state, cost_rank;


-- ┌─────────────────────────────────────────────────────────┐
-- │ DEMO 1.2: LATERAL FLATTEN                               │
-- │ Unpack VARIANT (JSON) arrays into relational rows.      │
-- │ Turns semi-structured data into queryable tabular data. │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: First, inspect the raw VARIANT column — notice it's a JSON array
SELECT plan_name, benefits FROM MEMBERSHIP_PLANS;

-- ▶ RUN: FLATTEN turns each array element into its own row
--   f.value = the array element; f.index = position (0-based)
SELECT
    p.plan_name,
    f.index  AS position,
    f.value::VARCHAR AS benefit
FROM MEMBERSHIP_PLANS p,
LATERAL FLATTEN(input => p.benefits) f
ORDER BY p.plan_id, f.index;

-- ▶ RUN: Access semi-structured weather data using dot-notation
--   The weather column is a VARIANT with keys: conditions, temp_f, precip_in, wind_mph
SELECT
    assist_id,
    issue_type,
    weather:conditions::VARCHAR   AS conditions,
    weather:temp_f::INTEGER       AS temp_f,
    weather:precip_in::FLOAT      AS precipitation_in,
    weather:wind_mph::INTEGER     AS wind_mph
FROM ROADSIDE_ASSISTS
LIMIT 10;
-- ▶ RUN: Aggregate on semi-structured fields — average response time by weather
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


-- ┌─────────────────────────────────────────────────────────┐
-- │ DEMO 1.3: OBJECT_CONSTRUCT                              │
-- │ Build JSON objects from relational columns on the fly.  │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: Construct a JSON member profile from relational columns
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


-- ┌─────────────────────────────────────────────────────────┐
-- │ DEMO 1.4: TRY_CAST                                     │
-- │ Safe type conversion that returns NULL instead of an    │
-- │ error when the value can't be converted.                │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: Notice TRY_CAST returns NULL on invalid inputs (no error thrown)
SELECT
    TRY_CAST('42'         AS INTEGER)  AS valid_int,     -- returns 42
    TRY_CAST('hello'      AS INTEGER)  AS invalid_int,   -- returns NULL
    TRY_CAST('2024-01-15' AS DATE)     AS valid_date,    -- returns date
    TRY_CAST('not-a-date' AS DATE)     AS invalid_date;  -- returns NULL
-- ▶ RUN: Practical use — safely cast VARIANT fields from adjuster notes
SELECT
    claim_id,
    adjuster_notes:priority::VARCHAR                        AS priority,
    TRY_CAST(adjuster_notes:follow_up::VARCHAR AS BOOLEAN) AS follow_up_flag
FROM CLAIMS
LIMIT 10;


-- ┌─────────────────────────────────────────────────────────┐
-- │ DEMO 1.5: IFF and DECODE                                │
-- │ Concise conditional expressions (shorter than CASE).    │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: IFF is a simple inline IF/ELSE; DECODE maps discrete values
SELECT
    member_id,
    full_name,
    status,
    IFF(status = 'Active', 'Yes', 'No') AS is_active,
    DECODE(membership_tier,
        'Basic',   '$7/mo',
        'Plus',    '$11/mo',
        'Premier', '$15/mo',
        'Unknown'
    )                                   AS monthly_cost
FROM MEMBERS
LIMIT 20;


-- ============================================================
-- SECTION 2: Query Profile — what to look for
-- ============================================================
-- ┌─────────────────────────────────────────────────────────┐
-- │ DEMO 2.1: Run a complex query, then examine its profile │
-- │ After running, go to: Snowsight → History → this query  │
-- │ → click "Query Profile" tab                             │
-- │                                                          │
-- │ KEY THINGS TO LOOK FOR IN THE PROFILE:                  │
-- │  • "Bytes Scanned" vs "Bytes Scanned From Cache"        │
-- │  • Partition pruning (Partitions Scanned vs Total)      │
-- │  • Spilling to local/remote storage (warning sign)      │
-- │  • Long-running operators (wide bars in timeline)       │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: Execute this join query, then open its Query Profile
SELECT
    m.state,
    m.membership_tier,
    COUNT(DISTINCT m.member_id)         AS member_count,
    COUNT(ra.assist_id)                 AS total_assists,
    ROUND(AVG(ra.response_time_min), 1) AS avg_response_min,
    ROUND(SUM(ra.cost), 2)             AS total_assist_cost,
    COUNT(c.claim_id)                   AS total_claims,
    ROUND(SUM(c.amount), 2)            AS total_claim_amount
FROM MEMBERS m
    LEFT JOIN ROADSIDE_ASSISTS ra ON m.member_id = ra.member_id
    LEFT JOIN CLAIMS c            ON m.member_id = c.member_id
WHERE m.status = 'Active'
GROUP BY 1, 2
ORDER BY total_assists DESC;

-- After running: go to Snowsight → History → click this query → "Query Profile"

-- ============================================================
-- SECTION 3: Time Travel
-- ============================================================
-- ┌─────────────────────────────────────────────────────────┐
-- │ IMPORTANT: Run these demos IN ORDER, one block at a     │
-- │ time. Time Travel references are relative to when the   │
-- │ statements were executed.                                │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN STEP 1: Capture current count of Active/Basic/CA members BEFORE any changes
SELECT COUNT(*) AS active_basic_ca_before
FROM MEMBERS
WHERE membership_tier = 'Basic' AND state = 'CA' AND status = 'Active';
-- NOTE: Remember this number — we will compare it after the update.
-- ▶ RUN STEP 2: Make a change AND capture the query ID in a variable
--   (Run both lines together as one block)
UPDATE MEMBERS
SET    status = 'Lapsed'
WHERE  membership_tier = 'Basic'
  AND  state = 'CA'
  AND  status = 'Active'
  AND  UNIFORM(0,10,RANDOM()) < 2;
SET update_qid = LAST_QUERY_ID();

-- ▶ RUN STEP 3: Confirm the update happened — count should be HIGHER than before
SELECT COUNT(*) AS lapsed_basic_ca_after_update
FROM MEMBERS
WHERE membership_tier = 'Basic' AND state = 'CA' AND status = 'Lapsed';
-- ▶ RUN STEP 4: AT(OFFSET) — look at data from 60 seconds ago
--   (Run this within 60 seconds of the UPDATE above)
--   The count of Active members should match what it was BEFORE the update.
SELECT COUNT(*) AS active_basic_ca_60sec_ago
FROM MEMBERS AT(OFFSET => -60)
WHERE membership_tier = 'Basic' AND state = 'CA' AND status = 'Active';
-- ▶ RUN STEP 5: BEFORE(STATEMENT) — look at data before the specific UPDATE
--   This uses the query ID we captured in Step 2 — always points to the right query.
SELECT COUNT(*) AS active_basic_ca_before_update
FROM MEMBERS BEFORE(STATEMENT => $update_qid)
WHERE membership_tier = 'Basic' AND state = 'CA' AND status = 'Active';
-- ▶ RUN STEP 6: Restore the data — CLONE at the pre-update point in time
--   Instead of CREATE OR REPLACE (which destroys time travel), we clone then swap.
CREATE OR REPLACE TABLE MEMBERS_RESTORED
    CLONE MEMBERS BEFORE(STATEMENT => $update_qid);
-- Verify the restored clone has the original count
SELECT COUNT(*) AS restored_active_count
FROM MEMBERS_RESTORED
WHERE membership_tier = 'Basic' AND state = 'CA' AND status = 'Active';
-- Swap: rename the tables to complete the restore
ALTER TABLE MEMBERS RENAME TO MEMBERS_DAMAGED;
ALTER TABLE MEMBERS_RESTORED RENAME TO MEMBERS;
-- Verify the restore is complete
SELECT COUNT(*) AS final_active_basic_ca
FROM MEMBERS
WHERE membership_tier = 'Basic' AND state = 'CA' AND status = 'Active';

-- Clean up the damaged copy
DROP TABLE IF EXISTS MEMBERS_DAMAGED;


-- ┌─────────────────────────────────────────────────────────┐
-- │ DEMO 3.6: UNDROP TABLE                                  │
-- │ Drop a table and recover it instantly.                  │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN STEP 1: Drop the CLAIMS table
DROP TABLE CLAIMS;
-- ▶ RUN STEP 2: Confirm it's gone
SHOW TABLES LIKE 'CLAIMS' IN SCHEMA MEMBER_SERVICES;

-- ▶ RUN STEP 3: Recover it with UNDROP — data is fully intact
UNDROP TABLE CLAIMS;
-- ▶ RUN STEP 4: Verify recovery — all 20,000 rows are back
SELECT COUNT(*) AS claims_recovered FROM CLAIMS;


-- ============================================================
-- SECTION 4: Zero-Copy Cloning
-- ============================================================
-- ┌─────────────────────────────────────────────────────────┐
-- │ Zero-copy clone creates an instant copy that shares the │
-- │ same underlying micro-partitions. No data is duplicated │
-- │ until one side writes new data (copy-on-write).         │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: Clone the MEMBERS table — notice it completes in under 1 second
CREATE OR REPLACE TABLE MEMBERS_DEV
    CLONE MEMBERS
    COMMENT = 'Development copy of MEMBERS — zero-copy clone';

-- ▶ RUN: Both tables have identical row counts (they share the same data)
SELECT 'ORIGINAL' AS source, COUNT(*) AS rows FROM MEMBERS
UNION ALL
SELECT 'CLONE',              COUNT(*)         FROM MEMBERS_DEV;
-- ▶ RUN: Modify the clone — the original is NOT affected
UPDATE MEMBERS_DEV SET membership_tier = 'Premier' WHERE member_id <= 100;

-- ▶ RUN: Verify — original is unchanged, clone is modified
SELECT 'ORIGINAL' AS source, COUNT(*) AS premier_members
FROM MEMBERS WHERE membership_tier = 'Premier' AND member_id <= 100
UNION ALL
SELECT 'CLONE', COUNT(*)
FROM MEMBERS_DEV WHERE membership_tier = 'Premier' AND member_id <= 100;

-- ▶ RUN: Schema-level clone — copies ALL tables in one command
CREATE SCHEMA IF NOT EXISTS MEMBER_SERVICES_DEV
    CLONE MEMBER_SERVICES
    COMMENT = 'Schema-level clone for dev/test environment';

-- ▶ RUN: See all cloned tables
SHOW TABLES IN SCHEMA MEMBER_SERVICES_DEV;

-- ▶ RUN: Clean up demo objects
DROP TABLE IF EXISTS MEMBERS_DEV;
DROP SCHEMA IF EXISTS MEMBER_SERVICES_DEV;

-- ============================================================
-- SECTION 5: Caching
-- ============================================================
-- ┌─────────────────────────────────────────────────────────┐
-- │ Snowflake has three caching layers:                     │
-- │  1. Metadata cache: COUNT(*), MIN, MAX — no scan needed │
-- │  2. Result cache: exact re-run within 24h = 0ms         │
-- │  3. Warehouse cache: SSD cache of recently scanned data │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: Metadata cache — these return instantly from metadata (no warehouse work)
--   Check the Query Profile: "Bytes Scanned" will be 0 for COUNT(*).
SELECT COUNT(*)       AS total_members   FROM MEMBERS;
SELECT MIN(join_date) AS earliest_member FROM MEMBERS;
SELECT MAX(join_date) AS latest_member   FROM MEMBERS;
-- ▶ RUN: Result cache — run this query TWICE
--   First run: warehouse does the work (check "Bytes Scanned" in Query Profile).
--   Second run: returns instantly from cache (Query Profile shows "QUERY RESULT REUSE").
SELECT
    state,
    membership_tier,
    COUNT(*)                                    AS members,
    AVG(DATEDIFF(day, join_date, CURRENT_DATE())) AS avg_tenure_days
FROM MEMBERS
WHERE status = 'Active'
GROUP BY 1, 2
ORDER BY 1, 2;

-- ▶ RUN: Now run it again immediately — observe the 0ms execution time
SELECT
    state,
    membership_tier,
    COUNT(*)                                    AS members,
    AVG(DATEDIFF(day, join_date, CURRENT_DATE())) AS avg_tenure_days
FROM MEMBERS
WHERE status = 'Active'
GROUP BY 1, 2
ORDER BY 1, 2;

-- ▶ RUN: Any change to the query text = cache miss (even adding a filter)
SELECT
    state,
    membership_tier,
    COUNT(*) AS members
FROM MEMBERS
WHERE status = 'Active'
  AND YEAR(join_date) >= 2020  -- different predicate = cache miss
GROUP BY 1, 2
ORDER BY 1, 2;

