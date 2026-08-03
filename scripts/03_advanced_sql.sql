-- =============================================================================
-- AAA Snowflake SQL Training — Module 3: Advanced SQL
-- 03_advanced_sql.sql
--
-- Topics covered:
--   1. CTEs — readability, chaining, and recursive CTEs
--   2. Window Functions — ROW_NUMBER, RANK, DENSE_RANK
--   3. Window Functions — Aggregate: running totals, moving averages
--   4. Window Functions — LEAD, LAG, FIRST_VALUE, LAST_VALUE
--   5. Window Functions — NTILE, frame specifications
--   6. PIVOT and UNPIVOT
--   7. LATERAL FLATTEN on nested JSON arrays
-- =============================================================================

USE WAREHOUSE TRAINING_WH;
USE DATABASE AAA_TRAINING;
USE SCHEMA MEMBER_SERVICES;

-- ============================================================
-- SECTION 1: Common Table Expressions (CTEs)
-- ============================================================

-- DEMO 1.1: Basic CTE — named, readable building blocks
-- Without CTE (nested subqueries — harder to read)
SELECT state, total_assists, avg_cost
FROM (
    SELECT
        state,
        COUNT(*)            AS total_assists,
        ROUND(AVG(cost), 2) AS avg_cost
    FROM ROADSIDE_ASSISTS
    WHERE resolved_flag = TRUE
    GROUP BY 1
)
WHERE total_assists >= 5000
ORDER BY avg_cost DESC;

-- WITH CTE — same logic, far more readable
WITH assist_summary AS (
    SELECT
        state,
        COUNT(*)            AS total_assists,
        ROUND(AVG(cost), 2) AS avg_cost
    FROM ROADSIDE_ASSISTS
    WHERE resolved_flag = TRUE
    GROUP BY 1
)
SELECT state, total_assists, avg_cost
FROM   assist_summary
WHERE  total_assists >= 5000
ORDER BY avg_cost DESC;

-- DEMO 1.2: Chained CTEs — multi-step analysis pipeline
-- Step 1: member-level assist stats
-- Step 2: add their tier
-- Step 3: rank within tier

WITH
member_assist_stats AS (
    -- Step 1: how many assists and total cost per member
    SELECT
        member_id,
        COUNT(*)            AS assist_count,
        ROUND(SUM(cost), 2) AS total_cost,
        ROUND(AVG(response_time_min), 1) AS avg_response_min
    FROM ROADSIDE_ASSISTS
    GROUP BY 1
),
member_enriched AS (
    -- Step 2: enrich with membership info
    SELECT
        m.member_id,
        m.full_name,
        m.membership_tier,
        m.state,
        s.assist_count,
        s.total_cost,
        s.avg_response_min
    FROM MEMBERS m
    JOIN member_assist_stats s ON m.member_id = s.member_id
    WHERE m.status = 'Active'
),
ranked AS (
    -- Step 3: rank by total cost within each tier
    SELECT *,
           RANK() OVER (
               PARTITION BY membership_tier
               ORDER BY total_cost DESC
           ) AS cost_rank_in_tier
    FROM member_enriched
)
-- Final: top 3 highest-cost members per tier
SELECT
    membership_tier,
    cost_rank_in_tier,
    full_name,
    state,
    assist_count,
    total_cost,
    avg_response_min
FROM ranked
WHERE cost_rank_in_tier <= 3
ORDER BY membership_tier, cost_rank_in_tier;

-- DEMO 1.3: Recursive CTE — member referral chains
-- MEMBERS.referral_member_id points to the member who referred them.
-- Walk the tree to find the full referral chain for each member.

WITH RECURSIVE referral_chain AS (
    -- Anchor: start with members who have no referrer (top of chain)
    SELECT
        member_id,
        full_name,
        referral_member_id,
        0                       AS depth,
        full_name               AS chain_path
    FROM MEMBERS
    WHERE referral_member_id IS NULL

    UNION ALL

    -- Recursive: join each referred member to their referrer
    SELECT
        m.member_id,
        m.full_name,
        m.referral_member_id,
        rc.depth + 1,
        rc.chain_path || ' → ' || m.full_name
    FROM MEMBERS m
    JOIN referral_chain rc ON m.referral_member_id = rc.member_id
    WHERE rc.depth < 4  -- safety: limit recursion depth
)
SELECT
    member_id,
    full_name,
    depth           AS referral_depth,
    chain_path
FROM referral_chain
WHERE depth > 0           -- exclude the anchor members
ORDER BY depth DESC, member_id
LIMIT 20;

-- Find top "influencers" — members who generated the most referrals (direct + indirect)
WITH RECURSIVE referral_chain AS (
    SELECT
        member_id,
        full_name,
        referral_member_id,
        member_id  AS root_id,   -- who started this chain
        0          AS depth
    FROM MEMBERS
    WHERE referral_member_id IS NULL

    UNION ALL

    SELECT
        m.member_id,
        m.full_name,
        m.referral_member_id,
        rc.root_id,
        rc.depth + 1
    FROM MEMBERS m
    JOIN referral_chain rc ON m.referral_member_id = rc.member_id
    WHERE rc.depth < 4
)
SELECT
    root_id                    AS influencer_member_id,
    MAX(full_name)             AS influencer_name,
    COUNT(*) - 1               AS total_referrals_in_tree  -- minus the root itself
FROM referral_chain
GROUP BY root_id
ORDER BY total_referrals_in_tree DESC
LIMIT 10;

-- ============================================================
-- SECTION 2: Window Functions — Ranking
-- ============================================================

-- DEMO 2.1: ROW_NUMBER, RANK, DENSE_RANK — understand the differences
SELECT
    member_id,
    issue_type,
    cost,
    ROW_NUMBER()  OVER (PARTITION BY issue_type ORDER BY cost DESC) AS row_num,
    RANK()        OVER (PARTITION BY issue_type ORDER BY cost DESC) AS rank_val,
    DENSE_RANK()  OVER (PARTITION BY issue_type ORDER BY cost DESC) AS dense_rank_val
FROM ROADSIDE_ASSISTS
QUALIFY row_num <= 5
ORDER BY issue_type, row_num;

-- Key difference:
--   ROW_NUMBER:  unique, sequential (1,2,3,4,5)
--   RANK:        ties get same rank, next rank skips (1,2,2,4,5)
--   DENSE_RANK:  ties get same rank, no gap     (1,2,2,3,4)

-- DEMO 2.2: NTILE — divide members into quartiles by tenure
SELECT
    member_id,
    full_name,
    join_date,
    DATEDIFF(day, join_date, CURRENT_DATE()) AS tenure_days,
    NTILE(4) OVER (ORDER BY join_date)       AS tenure_quartile  -- 1=newest, 4=oldest
FROM MEMBERS
WHERE status = 'Active'
ORDER BY join_date
LIMIT 30;

-- Usage: identify which tenure quartile spends the most
SELECT
    NTILE(4) OVER (ORDER BY join_date)  AS tenure_quartile,
    member_id,
    membership_tier
FROM MEMBERS WHERE status = 'Active'
QUALIFY TRUE  -- just to show QUALIFY works with any window expression
ORDER BY tenure_quartile;

-- Cleaner version using a CTE
WITH quartiled AS (
    SELECT
        member_id,
        membership_tier,
        join_date,
        NTILE(4) OVER (ORDER BY join_date) AS tenure_q
    FROM MEMBERS WHERE status = 'Active'
)
SELECT
    tenure_q,
    membership_tier,
    COUNT(*) AS member_count
FROM quartiled
GROUP BY 1, 2
ORDER BY 1, 2;

-- ============================================================
-- SECTION 3: Window Functions — Aggregate (Running Totals / Moving Averages)
-- ============================================================

-- DEMO 3.1: Running total of assist costs by month
WITH monthly AS (
    SELECT
        DATE_TRUNC('month', request_ts)::DATE  AS month,
        COUNT(*)                               AS assists,
        ROUND(SUM(cost), 2)                    AS monthly_cost
    FROM ROADSIDE_ASSISTS
    WHERE request_ts >= DATEADD(year, -2, CURRENT_DATE())
    GROUP BY 1
)
SELECT
    month,
    assists,
    monthly_cost,
    SUM(monthly_cost) OVER (ORDER BY month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                               AS running_total_cost,
    ROUND(AVG(monthly_cost) OVER (ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)
                                               AS rolling_3mo_avg_cost
FROM monthly
ORDER BY month;

-- DEMO 3.2: Cumulative count of member sign-ups per state
WITH daily_signups AS (
    SELECT
        state,
        join_date,
        COUNT(*) AS daily_new_members
    FROM MEMBERS
    GROUP BY 1, 2
)
SELECT
    state,
    join_date,
    daily_new_members,
    SUM(daily_new_members) OVER (
        PARTITION BY state
        ORDER BY join_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_members
FROM daily_signups
WHERE state = 'CA'
ORDER BY join_date
LIMIT 30;

-- DEMO 3.3: Year-over-year comparison using window functions
WITH monthly_assists AS (
    SELECT
        YEAR(request_ts)                      AS yr,
        MONTH(request_ts)                     AS mo,
        COUNT(*)                              AS assists
    FROM ROADSIDE_ASSISTS
    GROUP BY 1, 2
)
SELECT
    yr,
    mo,
    assists,
    LAG(assists, 12) OVER (ORDER BY yr, mo)   AS assists_same_mo_last_year,
    ROUND(
        (assists - LAG(assists, 12) OVER (ORDER BY yr, mo))
        / NULLIF(LAG(assists, 12) OVER (ORDER BY yr, mo), 0) * 100,
        1
    )                                         AS yoy_pct_change
FROM monthly_assists
ORDER BY yr, mo;

-- ============================================================
-- SECTION 4: Window Functions — LEAD, LAG, FIRST_VALUE, LAST_VALUE
-- ============================================================

-- DEMO 4.1: LAG — time between consecutive assists for a member
WITH member_assists AS (
    SELECT
        member_id,
        request_ts,
        issue_type,
        LAG(request_ts) OVER (
            PARTITION BY member_id
            ORDER BY request_ts
        ) AS prev_assist_ts
    FROM ROADSIDE_ASSISTS
)
SELECT
    member_id,
    request_ts,
    prev_assist_ts,
    issue_type,
    DATEDIFF(day, prev_assist_ts, request_ts) AS days_since_last_assist
FROM member_assists
WHERE prev_assist_ts IS NOT NULL
ORDER BY days_since_last_assist
LIMIT 20;

-- DEMO 4.2: LEAD — predict next interaction
SELECT
    member_id,
    call_ts,
    topic,
    LEAD(call_ts)   OVER (PARTITION BY member_id ORDER BY call_ts) AS next_call_ts,
    LEAD(topic)     OVER (PARTITION BY member_id ORDER BY call_ts) AS next_call_topic,
    DATEDIFF(day, call_ts,
        LEAD(call_ts) OVER (PARTITION BY member_id ORDER BY call_ts)
    )                                                               AS days_to_next_call
FROM CALL_CENTER_INTERACTIONS
QUALIFY days_to_next_call IS NOT NULL
ORDER BY member_id, call_ts
LIMIT 20;

-- DEMO 4.3: FIRST_VALUE and LAST_VALUE — first and most recent assist per member
SELECT
    member_id,
    request_ts,
    issue_type,
    FIRST_VALUE(issue_type) OVER (
        PARTITION BY member_id
        ORDER BY request_ts
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS first_ever_issue_type,
    LAST_VALUE(issue_type) OVER (
        PARTITION BY member_id
        ORDER BY request_ts
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS most_recent_issue_type
FROM ROADSIDE_ASSISTS
QUALIFY ROW_NUMBER() OVER (PARTITION BY member_id ORDER BY request_ts DESC) = 1
ORDER BY member_id
LIMIT 20;

-- ============================================================
-- SECTION 5: PIVOT and UNPIVOT
-- ============================================================

-- DEMO 5.1: PIVOT — turn issue_type rows into columns
-- Count assists per state per issue type, then pivot issue_type into columns

SELECT *
FROM (
    SELECT state, issue_type, 1 AS assist_flag
    FROM ROADSIDE_ASSISTS
) src
PIVOT (
    COUNT(assist_flag)
    FOR issue_type IN ('flat_tire', 'battery', 'lockout', 'tow', 'fuel')
) AS pvt
ORDER BY state;

-- DEMO 5.2: PIVOT with aggregation — average cost per issue type per state
SELECT *
FROM (
    SELECT state, issue_type, cost
    FROM ROADSIDE_ASSISTS
    WHERE resolved_flag = TRUE
) src
PIVOT (
    ROUND(AVG(cost), 2)
    FOR issue_type IN ('flat_tire', 'battery', 'lockout', 'tow', 'fuel')
) AS pvt
ORDER BY state;

-- DEMO 5.3: UNPIVOT — reverse a pivoted table (wide → long)
-- Suppose we have a summary table in wide format and want to normalize it

-- First create a wide summary
CREATE OR REPLACE TEMP TABLE assists_wide AS
SELECT *
FROM (
    SELECT state, issue_type, 1 AS n
    FROM ROADSIDE_ASSISTS
) src
PIVOT (COUNT(n) FOR issue_type IN ('flat_tire','battery','lockout','tow','fuel')) AS pvt;

-- Now UNPIVOT back to long format
SELECT state, issue_type, assist_count
FROM assists_wide
UNPIVOT (
    assist_count FOR issue_type
    IN ("'flat_tire'", "'battery'", "'lockout'", "'tow'", "'fuel'")
)
ORDER BY state, issue_type;

-- ============================================================
-- SECTION 6: LATERAL FLATTEN on Nested Arrays
-- ============================================================

-- DEMO 6.1: Explode the benefits VARIANT array into rows
-- We saw this briefly in Module 1 — let's go deeper here

-- Raw VARIANT: each row has a JSON array of benefits
SELECT plan_id, plan_name, benefits FROM MEMBERSHIP_PLANS;

-- FLATTEN explodes each array element into its own row
SELECT
    p.plan_id,
    p.plan_name,
    f.index              AS benefit_index,
    f.value::VARCHAR     AS benefit
FROM MEMBERSHIP_PLANS p,
LATERAL FLATTEN(input => p.benefits) f
ORDER BY p.plan_id, f.index;

-- DEMO 6.2: Aggregate flattened data — count benefits per plan
SELECT
    p.plan_name,
    COUNT(f.value)   AS benefit_count
FROM MEMBERSHIP_PLANS p,
LATERAL FLATTEN(input => p.benefits) f
GROUP BY p.plan_name
ORDER BY benefit_count DESC;

-- DEMO 6.3: Filter within flattened array — find plans with towing coverage
SELECT DISTINCT
    p.plan_name
FROM MEMBERSHIP_PLANS p,
LATERAL FLATTEN(input => p.benefits) f
WHERE f.value::VARCHAR ILIKE '%Tow%'
ORDER BY 1;

-- DEMO 6.4: FLATTEN on adjuster_notes documentation array in CLAIMS
SELECT
    c.claim_id,
    c.claim_type,
    c.adjuster_notes:priority::VARCHAR  AS priority,
    f.value::VARCHAR                    AS required_document
FROM CLAIMS c,
LATERAL FLATTEN(input => c.adjuster_notes:documentation) f
WHERE c.status = 'Open'
  AND c.adjuster_notes:priority::VARCHAR = 'High'
LIMIT 20;
