-- =============================================================================
-- AAA Snowflake SQL Training — Module 2: Query Best Practices
-- 02_best_practices.sql
--
-- Topics covered:
--   1. Micro-partitions and pruning — how Snowflake stores data
--   2. Clustering keys — when and how to use them
--   3. Common anti-patterns — mistakes that hurt performance
--   4. EXPLAIN — reading execution plans
--   5. Warehouse sizing — choosing the right size
-- =============================================================================

USE WAREHOUSE TRAINING_WH;
USE DATABASE AAA_TRAINING;
USE SCHEMA MEMBER_SERVICES;

-- ============================================================
-- SECTION 1: Micro-Partitions and Pruning
-- ============================================================

-- DEMO 1.1: Understand how data is physically stored
-- Snowflake automatically divides each table into micro-partitions
-- (50–500 MB compressed chunks), each with min/max metadata per column.

-- Check clustering information on ROADSIDE_ASSISTS
SELECT SYSTEM$CLUSTERING_INFORMATION(
    'ROADSIDE_ASSISTS',
    '(request_ts)'    -- check how well this table clusters on the timestamp
);

-- Key metrics to explain:
--   average_overlaps: lower = better pruning
--   average_depth:    lower = more selective (closer to 1 is ideal)
--   total_partition_count: total micro-partitions in the table

-- DEMO 1.2: Pruning in action — compare a selective vs non-selective predicate

-- Query 1: selective date predicate — Snowflake prunes most partitions
-- Check Query Profile → "Partitions Scanned" vs "Partitions Total"
SELECT
    issue_type,
    COUNT(*)                     AS assists,
    ROUND(AVG(response_time_min), 1) AS avg_response_min
FROM ROADSIDE_ASSISTS
WHERE request_ts BETWEEN '2024-01-01' AND '2024-03-31'  -- 3-month slice
GROUP BY 1
ORDER BY 1;

-- Query 2: same data but SUPPRESSED pruning — YEAR() wraps the column
-- This forces a full scan because Snowflake can't prune on derived values
SELECT
    issue_type,
    COUNT(*)                     AS assists,
    ROUND(AVG(response_time_min), 1) AS avg_response_min
FROM ROADSIDE_ASSISTS
WHERE YEAR(request_ts) = 2024 AND MONTH(request_ts) IN (1, 2, 3)
GROUP BY 1
ORDER BY 1;

-- Key takeaway: the first query prunes partitions; the second does a full scan.
-- Check Query Profile for both to see the difference in partitions scanned.

-- DEMO 1.3: Check clustering depth on the state column
SELECT SYSTEM$CLUSTERING_INFORMATION(
    'ROADSIDE_ASSISTS',
    '(state)'
);
-- state has only 10 distinct values — micro-partitions overlap a lot.
-- Not a good clustering key candidate on its own.

-- ============================================================
-- SECTION 2: Clustering Keys
-- ============================================================

-- DEMO 2.1: When is a clustering key worth it?
-- - Very large tables (100M+ rows, or multi-TB after compression)
-- - Most queries filter on the same 1-2 columns
-- - Natural insert order doesn't match query filter columns

-- Check the most common filter column in our queries:
-- ROADSIDE_ASSISTS is almost always filtered by request_ts or state+request_ts

-- DEMO 2.2: EXPLAIN shows estimated partitions scanned
-- "No Stats" means Snowflake doesn't have column stats yet — 
-- it will scan all partitions.

EXPLAIN USING TABULAR
SELECT COUNT(*) FROM ROADSIDE_ASSISTS
WHERE request_ts >= '2024-01-01';

-- DEMO 2.3: A well-clustered query scan
-- This shows fewer partitions when data is clustered on request_ts
-- (In our training data, request_ts is naturally ordered since we used DATEADD)
EXPLAIN USING TABULAR
SELECT
    DATE_TRUNC('month', request_ts)  AS month,
    COUNT(*)                         AS assists
FROM ROADSIDE_ASSISTS
WHERE request_ts >= DATEADD(year, -1, CURRENT_DATE())
GROUP BY 1
ORDER BY 1;

-- ============================================================
-- SECTION 3: Common Anti-Patterns
-- ============================================================

-- DEMO 3.1: ANTI-PATTERN — SELECT * in production queries
-- Reads ALL columns even if only 2 are needed. Wastes I/O and memory.

-- BAD: pulls all 9 columns from ROADSIDE_ASSISTS
SELECT *
FROM ROADSIDE_ASSISTS
WHERE state = 'CA'
LIMIT 100;

-- GOOD: only the columns you need
SELECT assist_id, member_id, issue_type, cost
FROM ROADSIDE_ASSISTS
WHERE state = 'CA'
LIMIT 100;

-- DEMO 3.2: ANTI-PATTERN — Functions on filter columns (defeats pruning)

-- BAD: wrapping the column prevents partition pruning
SELECT COUNT(*) FROM ROADSIDE_ASSISTS
WHERE UPPER(state) = 'CA';           -- forces full scan — UPPER() on every row

SELECT COUNT(*) FROM MEMBERS
WHERE DATE_TRUNC('year', join_date) = '2023-01-01';  -- wrapping date column

-- GOOD: filter on the raw column value
SELECT COUNT(*) FROM ROADSIDE_ASSISTS
WHERE state = 'CA';                  -- Snowflake can prune via column metadata

SELECT COUNT(*) FROM MEMBERS
WHERE join_date BETWEEN '2023-01-01' AND '2023-12-31'; -- prunable date range

-- DEMO 3.3: ANTI-PATTERN — ORDER BY without LIMIT on large result sets
-- Sorting millions of rows when you only need the top 10 is wasteful.

-- BAD: sorts entire 50K row result set
SELECT member_id, cost FROM ROADSIDE_ASSISTS ORDER BY cost DESC;

-- GOOD: top 10 most expensive assists only
SELECT member_id, cost FROM ROADSIDE_ASSISTS ORDER BY cost DESC LIMIT 10;

-- DEMO 3.4: ANTI-PATTERN — Implicit cartesian join (missing join condition)

-- BAD: forgot the ON clause — produces member_count * plan_count rows!
SELECT m.member_id, p.plan_name
FROM MEMBERS m, MEMBERSHIP_PLANS p
LIMIT 10;
-- ^ This returns 10,000 * 3 = 30,000 rows. Harmless here but catastrophic at scale.

-- GOOD: always explicit join conditions
SELECT m.member_id, p.plan_name
FROM MEMBERS m
JOIN MEMBERSHIP_PLANS p
  ON  (m.membership_tier = 'Basic'   AND p.plan_name = 'Basic')
   OR (m.membership_tier = 'Plus'    AND p.plan_name = 'Plus')
   OR (m.membership_tier = 'Premier' AND p.plan_name = 'Premier')
LIMIT 10;

-- Even better — just use the natural string match
SELECT m.member_id, m.membership_tier, p.monthly_cost
FROM MEMBERS m
JOIN MEMBERSHIP_PLANS p ON m.membership_tier = p.plan_name
LIMIT 10;

-- DEMO 3.5: ANTI-PATTERN — NOT IN with NULLs (logical trap)
-- NOT IN returns NO rows if any value in the subquery list is NULL.

-- Risky: if any member has NULL referral_member_id AND you mean "no referral"
SELECT COUNT(*) FROM MEMBERS
WHERE member_id NOT IN (SELECT referral_member_id FROM MEMBERS);
-- ^ Returns 0 rows if referral_member_id has NULLs! (NULL poisons NOT IN)

-- SAFE: use NOT EXISTS instead
SELECT COUNT(*) FROM MEMBERS m
WHERE NOT EXISTS (
    SELECT 1 FROM MEMBERS r
    WHERE r.referral_member_id = m.member_id
);

-- OR filter NULLs explicitly:
SELECT COUNT(*) FROM MEMBERS
WHERE member_id NOT IN (
    SELECT referral_member_id FROM MEMBERS
    WHERE referral_member_id IS NOT NULL  -- explicitly exclude NULLs
);

-- DEMO 3.6: ANTI-PATTERN — DISTINCT used to hide a broken join
-- If you need DISTINCT after a join, you probably have a duplicate-generating join.

-- Suspect query — why are there duplicates?
SELECT DISTINCT m.member_id, m.full_name
FROM MEMBERS m
JOIN ROADSIDE_ASSISTS ra ON m.member_id = ra.member_id;
-- DISTINCT here hides that members with multiple assists appear multiple times.

-- BETTER: use GROUP BY or EXISTS to express intent clearly
SELECT m.member_id, m.full_name
FROM MEMBERS m
WHERE EXISTS (
    SELECT 1 FROM ROADSIDE_ASSISTS ra
    WHERE ra.member_id = m.member_id
);

-- ============================================================
-- SECTION 4: EXPLAIN — Reading Query Plans
-- ============================================================

-- DEMO 4.1: EXPLAIN USING TABULAR shows the operator tree
EXPLAIN USING TABULAR
SELECT
    m.state,
    COUNT(DISTINCT m.member_id)      AS unique_members,
    COUNT(ra.assist_id)              AS total_assists
FROM MEMBERS m
JOIN ROADSIDE_ASSISTS ra ON m.member_id = ra.member_id
WHERE m.status = 'Active'
  AND ra.request_ts >= DATEADD(year, -1, CURRENT_DATE())
GROUP BY 1
ORDER BY 2 DESC;

-- Key columns in EXPLAIN output:
--   step_id:    execution order
--   operation:  TableScan, Filter, HashJoin, Aggregate, Sort
--   objects:    which table/view
--   expressions: what columns and expressions are used

-- DEMO 4.2: EXPLAIN vs actual execution
-- EXPLAIN is estimated — always validate with actual Query Profile for large jobs.

-- ============================================================
-- SECTION 5: Warehouse Sizing
-- ============================================================

-- DEMO 5.1: Check recent query performance by warehouse size
-- Use ACCOUNT_USAGE to see if queries are spilling (sign of undersized warehouse)
SELECT
    warehouse_name,
    warehouse_size,
    COUNT(*)                                    AS query_count,
    AVG(total_elapsed_time) / 1000.0            AS avg_elapsed_sec,
    SUM(bytes_spilled_to_local_storage)         AS total_local_spill_bytes,
    SUM(bytes_spilled_to_remote_storage)        AS total_remote_spill_bytes,
    SUM(credits_used_cloud_services)            AS cloud_service_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
  AND warehouse_name IS NOT NULL
GROUP BY 1, 2
ORDER BY avg_elapsed_sec DESC
LIMIT 20;

-- DEMO 5.2: Identify queries that would benefit from a larger warehouse
-- (queries with significant spilling)
SELECT
    query_id,
    query_text,
    warehouse_size,
    total_elapsed_time / 1000.0                 AS elapsed_sec,
    bytes_spilled_to_local_storage  / 1e9       AS local_spill_gb,
    bytes_spilled_to_remote_storage / 1e9       AS remote_spill_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
  AND bytes_spilled_to_local_storage > 0
ORDER BY bytes_spilled_to_remote_storage DESC
LIMIT 10;

-- DEMO 5.3: Rule of thumb for warehouse sizing
-- XS  → quick lookups, small aggregations (<1M rows)
-- S   → typical analyst queries, moderate aggregations
-- M   → complex joins, 10M+ row aggregations
-- L   → very large joins, data loading, complex ML feature prep
-- XL+ → extreme aggregations, rare — usually better to optimize the query first

-- DEMO 5.4: Auto-suspend to reduce idle cost
ALTER WAREHOUSE TRAINING_WH SET AUTO_SUSPEND = 60;  -- suspend after 60 seconds idle
ALTER WAREHOUSE TRAINING_WH SET AUTO_RESUME   = TRUE;

-- Check warehouse settings
SHOW WAREHOUSES LIKE 'TRAINING_WH';
