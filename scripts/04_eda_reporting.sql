-- =============================================================================
-- AAA Snowflake SQL Training — Module 4: EDA & Reporting
-- 04_eda_reporting.sql
--
-- Topics covered:
--   1. Ad-hoc exploratory data analysis (EDA) patterns
--   2. Data quality profiling
--   3. Building reusable views (standard and secure)
--   4. Creating reporting datasets (CTAS snapshots)
--   5. Materialized views and Dynamic Tables (intro)
--   6. Column-level masking policy (data governance intro)
-- =============================================================================

USE WAREHOUSE TRAINING_WH;
USE DATABASE AAA_TRAINING;
USE SCHEMA MEMBER_SERVICES;

-- ============================================================
-- SECTION 1: Ad-Hoc Exploratory Data Analysis
-- ============================================================

-- DEMO 1.1: Quick table profile — row counts, date ranges, distinct values
-- This is typically the first thing you run on a new table.

SELECT
    COUNT(*)                                    AS total_rows,
    COUNT(DISTINCT member_id)                   AS unique_members,
    COUNT(DISTINCT state)                       AS state_count,
    MIN(join_date)                              AS earliest_join,
    MAX(join_date)                              AS latest_join,
    COUNT_IF(status = 'Active') / COUNT(*)::FLOAT * 100  AS pct_active,
    APPROX_COUNT_DISTINCT(full_name)            AS approx_distinct_names
FROM MEMBERS;

-- DEMO 1.2: Distribution analysis with percentiles
-- PERCENTILE_CONT is an exact percentile; APPROX_PERCENTILE is faster at scale
SELECT
    issue_type,
    COUNT(*)                                                AS assists,
    ROUND(MIN(response_time_min), 0)                        AS min_response,
    ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP
          (ORDER BY response_time_min), 0)                  AS p25_response,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP
          (ORDER BY response_time_min), 0)                  AS median_response,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP
          (ORDER BY response_time_min), 0)                  AS p75_response,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP
          (ORDER BY response_time_min), 0)                  AS p90_response,
    ROUND(MAX(response_time_min), 0)                        AS max_response
FROM ROADSIDE_ASSISTS
GROUP BY 1
ORDER BY median_response DESC;

-- DEMO 1.3: APPROX_COUNT_DISTINCT — fast cardinality estimate at scale
-- Uses HyperLogLog — ~2% error but orders of magnitude faster on large tables
SELECT
    APPROX_COUNT_DISTINCT(member_id)    AS approx_unique_members,
    COUNT(DISTINCT member_id)           AS exact_unique_members
FROM ROADSIDE_ASSISTS;

-- DEMO 1.4: Frequency distribution — what's the most common pattern?
SELECT
    issue_type,
    COUNT(*)                               AS occurrences,
    ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 1)  AS pct_of_total
FROM ROADSIDE_ASSISTS
GROUP BY 1
ORDER BY occurrences DESC;

-- DEMO 1.5: Cross-tab quick analysis — tier breakdown by state
SELECT
    state,
    COUNT_IF(membership_tier = 'Basic')   AS basic_count,
    COUNT_IF(membership_tier = 'Plus')    AS plus_count,
    COUNT_IF(membership_tier = 'Premier') AS premier_count,
    COUNT(*)                              AS total
FROM MEMBERS
WHERE status = 'Active'
GROUP BY state
ORDER BY total DESC;

-- ============================================================
-- SECTION 2: Data Quality Profiling
-- ============================================================

-- DEMO 2.1: Null audit — identify completeness gaps across columns
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) - COUNT(member_id)          AS null_member_id,
    COUNT(*) - COUNT(phone)              AS null_phone,
    COUNT(*) - COUNT(referral_member_id) AS null_referral,
    COUNT(*) - COUNT(renewal_date)       AS null_renewal_date
FROM MEMBERS;

-- DEMO 2.2: Duplicate check — are primary keys truly unique?
SELECT member_id, COUNT(*) AS cnt
FROM MEMBERS
GROUP BY member_id
HAVING cnt > 1
LIMIT 10;
-- If this returns rows, there are duplicates — investigate before reporting.

-- DEMO 2.3: Referential integrity check — orphan records
-- Are there assists for member IDs that don't exist in MEMBERS?
SELECT COUNT(*) AS orphan_assists
FROM ROADSIDE_ASSISTS ra
WHERE NOT EXISTS (
    SELECT 1 FROM MEMBERS m WHERE m.member_id = ra.member_id
);

-- DEMO 2.4: Value distribution sanity check
SELECT
    csat_score,
    COUNT(*)  AS interactions,
    ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 1) AS pct
FROM CALL_CENTER_INTERACTIONS
GROUP BY csat_score
ORDER BY csat_score NULLS LAST;
-- NULL means "not surveyed" — confirm that's expected

-- ============================================================
-- SECTION 3: Building Reusable Views
-- ============================================================

-- DEMO 3.1: Standard view — member 360 summary
-- Encapsulate the join logic once; consumers query the view
CREATE OR REPLACE VIEW V_MEMBER_360 AS
SELECT
    m.member_id,
    m.full_name,
    m.email,
    m.state,
    m.membership_tier,
    m.status,
    m.join_date,
    m.renewal_date,
    DATEDIFF(day, m.join_date, CURRENT_DATE())          AS tenure_days,
    -- Roadside summary
    COUNT(DISTINCT ra.assist_id)                        AS total_assists,
    ROUND(SUM(ra.cost), 2)                              AS total_assist_cost,
    ROUND(AVG(ra.response_time_min), 1)                 AS avg_response_min,
    -- Claim summary
    COUNT(DISTINCT c.claim_id)                          AS total_claims,
    ROUND(SUM(c.amount), 2)                             AS total_claim_amount,
    -- Call center summary
    COUNT(DISTINCT cci.interaction_id)                  AS total_interactions,
    ROUND(AVG(cci.csat_score), 2)                       AS avg_csat_score
FROM MEMBERS m
LEFT JOIN ROADSIDE_ASSISTS ra
    ON m.member_id = ra.member_id
LEFT JOIN CLAIMS c
    ON m.member_id = c.member_id
LEFT JOIN CALL_CENTER_INTERACTIONS cci
    ON m.member_id = cci.member_id
GROUP BY
    m.member_id, m.full_name, m.email, m.state,
    m.membership_tier, m.status, m.join_date, m.renewal_date
COMMENT = 'Member 360 view — combines MEMBERS, ROADSIDE_ASSISTS, CLAIMS, CALL_CENTER_INTERACTIONS';

-- Use the view like a table
SELECT * FROM V_MEMBER_360 WHERE state = 'CA' ORDER BY total_assist_cost DESC LIMIT 10;

-- DEMO 3.2: Secure view — hides the SQL definition from non-privileged users
-- Use for sensitive business logic or when sharing with external parties
CREATE OR REPLACE SECURE VIEW V_MEMBER_SUMMARY_SECURE AS
SELECT
    member_id,
    -- Email is partially masked in the view definition
    LEFT(email, 2) || '***@' || SPLIT_PART(email, '@', 2)   AS masked_email,
    state,
    membership_tier,
    status,
    join_date
FROM MEMBERS
COMMENT = 'Secure view — hides PII and underlying SQL from non-owners';

-- A user with access sees data but cannot run SHOW CREATE VIEW to see the logic
SELECT * FROM V_MEMBER_SUMMARY_SECURE LIMIT 5;

-- Try to see the definition (owners can; others see an error)
SHOW VIEWS LIKE 'V_MEMBER_SUMMARY_SECURE';
SELECT GET_DDL('VIEW', 'AAA_TRAINING.MEMBER_SERVICES.V_MEMBER_SUMMARY_SECURE');

-- DEMO 3.3: View for reporting — pre-joining for analysts
-- Isolate the joining complexity; analysts just SELECT from the view
CREATE OR REPLACE VIEW V_MONTHLY_ASSIST_REPORT AS
SELECT
    DATE_TRUNC('month', ra.request_ts)::DATE  AS report_month,
    ra.state,
    ra.issue_type,
    m.membership_tier,
    COUNT(ra.assist_id)                        AS assist_count,
    ROUND(SUM(ra.cost), 2)                     AS total_cost,
    ROUND(AVG(ra.response_time_min), 1)        AS avg_response_min,
    COUNT_IF(NOT ra.resolved_flag)             AS unresolved_count
FROM ROADSIDE_ASSISTS ra
JOIN MEMBERS m ON ra.member_id = m.member_id
GROUP BY 1, 2, 3, 4
COMMENT = 'Monthly assist report pre-joined with member tier';

-- Query it simply
SELECT report_month, state, issue_type, assist_count, total_cost
FROM V_MONTHLY_ASSIST_REPORT
WHERE report_month >= DATEADD(year, -1, CURRENT_DATE())
ORDER BY report_month, total_cost DESC;

-- ============================================================
-- SECTION 4: Creating Reporting Datasets (CTAS Snapshots)
-- ============================================================

-- DEMO 4.1: CREATE TABLE AS SELECT (CTAS) — snapshot for reporting
-- Use when: you need a fixed point-in-time dataset, or query is too slow for a view

CREATE OR REPLACE TABLE RPT_MEMBER_PERFORMANCE_SNAPSHOT AS
SELECT
    CURRENT_DATE()                                  AS snapshot_date,
    m.state,
    m.membership_tier,
    COUNT(DISTINCT m.member_id)                     AS active_members,
    COUNT(DISTINCT ra.assist_id)                    AS ytd_assists,
    ROUND(SUM(ra.cost), 2)                          AS ytd_assist_cost,
    ROUND(AVG(ra.response_time_min), 1)             AS avg_response_min,
    COUNT(DISTINCT c.claim_id)                      AS ytd_claims,
    ROUND(AVG(cci.csat_score), 2)                   AS avg_csat
FROM MEMBERS m
LEFT JOIN ROADSIDE_ASSISTS ra
    ON  m.member_id = ra.member_id
    AND YEAR(ra.request_ts) = YEAR(CURRENT_DATE())
LEFT JOIN CLAIMS c
    ON  m.member_id = c.member_id
    AND YEAR(c.claim_date) = YEAR(CURRENT_DATE())
LEFT JOIN CALL_CENTER_INTERACTIONS cci
    ON  m.member_id = cci.member_id
    AND YEAR(cci.call_ts) = YEAR(CURRENT_DATE())
WHERE m.status = 'Active'
GROUP BY m.state, m.membership_tier
ORDER BY m.state, m.membership_tier;

-- Check the snapshot
SELECT * FROM RPT_MEMBER_PERFORMANCE_SNAPSHOT ORDER BY state, membership_tier;

-- DEMO 4.2: Clone the snapshot for comparison (zero-copy!)
CREATE OR REPLACE TABLE RPT_MEMBER_PERFORMANCE_PREV_WEEK
    CLONE RPT_MEMBER_PERFORMANCE_SNAPSHOT;

-- ============================================================
-- SECTION 5: Materialized Views and Dynamic Tables (Intro)
-- ============================================================

-- DEMO 5.1: Materialized View — pre-computed results, auto-refreshed by Snowflake
-- Good for: expensive aggregations queried frequently, read-heavy workloads

CREATE OR REPLACE MATERIALIZED VIEW MV_STATE_ASSIST_SUMMARY AS
SELECT
    state,
    issue_type,
    COUNT(*)                     AS total_assists,
    ROUND(AVG(cost), 2)          AS avg_cost,
    ROUND(AVG(response_time_min), 1) AS avg_response_min
FROM ROADSIDE_ASSISTS
WHERE resolved_flag = TRUE
GROUP BY state, issue_type
COMMENT = 'Materialized view — refreshed automatically when ROADSIDE_ASSISTS changes';

-- Query it — Snowflake serves pre-computed results instantly
SELECT * FROM MV_STATE_ASSIST_SUMMARY ORDER BY state, issue_type;

-- DEMO 5.2: Dynamic Table — declarative incremental pipeline
-- Define WHAT you want; Snowflake handles HOW and WHEN to refresh
-- TARGET_LAG controls how fresh the data is (trade-off: freshness vs cost)

CREATE OR REPLACE DYNAMIC TABLE DT_MEMBER_DAILY_SUMMARY
    TARGET_LAG = '1 hour'
    WAREHOUSE  = TRAINING_WH
    COMMENT    = 'Incremental daily member summary — refreshes within 1 hour of source changes'
AS
SELECT
    DATE_TRUNC('day', ra.request_ts)::DATE       AS activity_date,
    m.state,
    m.membership_tier,
    COUNT(DISTINCT m.member_id)                  AS active_members_with_assists,
    COUNT(ra.assist_id)                          AS total_assists,
    ROUND(SUM(ra.cost), 2)                       AS total_cost
FROM ROADSIDE_ASSISTS ra
JOIN MEMBERS m ON ra.member_id = m.member_id
WHERE m.status = 'Active'
GROUP BY 1, 2, 3;

-- Check the dynamic table
SELECT * FROM DT_MEMBER_DAILY_SUMMARY
ORDER BY activity_date DESC, state, membership_tier
LIMIT 30;

-- Check refresh status
SELECT *
FROM INFORMATION_SCHEMA.DYNAMIC_TABLES
WHERE TABLE_NAME = 'DT_MEMBER_DAILY_SUMMARY';

-- ============================================================
-- SECTION 6: Data Governance — Column Masking Policy
-- ============================================================

-- DEMO 6.1: Create a masking policy to protect email addresses
-- Only users with the ANALYST_ADMIN role see real emails; others see masked values

USE ROLE SYSADMIN;

CREATE OR REPLACE MASKING POLICY email_mask AS (email_val VARCHAR)
RETURNS VARCHAR ->
    CASE
        WHEN CURRENT_ROLE() IN ('SYSADMIN', 'ACCOUNTADMIN') THEN email_val
        ELSE LEFT(email_val, 2) || '****@' || SPLIT_PART(email_val, '@', 2)
    END
COMMENT = 'Masks email to partial display for non-admin roles';

-- DEMO 6.2: Apply the masking policy to the MEMBERS.email column
ALTER TABLE MEMBERS
    MODIFY COLUMN email
    SET MASKING POLICY email_mask;

-- DEMO 6.3: Query as SYSADMIN — see full email
SELECT member_id, full_name, email FROM MEMBERS LIMIT 5;
-- Full email visible: john123@example.com

-- DEMO 6.4: In a real scenario, switch to a different role to see masking
-- USE ROLE analyst_role;  -- (would show: jo****@example.com)

-- DEMO 6.5: View all masking policies applied in this schema
SELECT *
FROM INFORMATION_SCHEMA.POLICY_REFERENCES
WHERE POLICY_KIND = 'MASKING_POLICY'
  AND REF_DATABASE_NAME = 'AAA_TRAINING';

-- DEMO 6.6: Remove the masking policy (for clean demo reset)
ALTER TABLE MEMBERS
    MODIFY COLUMN email
    UNSET MASKING POLICY;

-- ============================================================
-- WRAP-UP: Full end-to-end reporting query using all views
-- ============================================================

-- A typical BI/reporting query leveraging the views we built
SELECT
    m360.state,
    m360.membership_tier,
    COUNT(DISTINCT m360.member_id)              AS member_count,
    ROUND(AVG(m360.total_assist_cost), 2)       AS avg_member_assist_cost,
    ROUND(AVG(m360.avg_csat_score), 2)          AS avg_csat,
    ROUND(AVG(m360.total_claims), 2)            AS avg_claims_per_member,
    SUM(m360.total_assists)                     AS total_assists
FROM V_MEMBER_360 m360
WHERE m360.status = 'Active'
  AND m360.tenure_days >= 365        -- members with at least 1 year tenure
GROUP BY 1, 2
ORDER BY avg_member_assist_cost DESC;
