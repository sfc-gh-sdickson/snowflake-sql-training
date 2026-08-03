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
--   8. Advanced Analytical Functions: ASOF JOIN, MATCH_RECOGNIZE,
--      RATIO_TO_REPORT, CONDITIONAL_CHANGE_EVENT, TIME_SLICE
-- =============================================================================

USE WAREHOUSE TRAINING_WH;
USE DATABASE AAA_TRAINING;
USE SCHEMA MEMBER_SERVICES;

-- ============================================================
-- SECTION 1: Common Table Expressions (CTEs)
-- ============================================================

-- DEMO 1.1: Basic CTE — named, readable building blocks
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
WITH
member_assist_stats AS (
    SELECT
        member_id,
        COUNT(*)            AS assist_count,
        ROUND(SUM(cost), 2) AS total_cost,
        ROUND(AVG(response_time_min), 1) AS avg_response_min
    FROM ROADSIDE_ASSISTS
    GROUP BY 1
),
member_enriched AS (
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
    SELECT *,
           RANK() OVER (
               PARTITION BY membership_tier
               ORDER BY total_cost DESC
           ) AS cost_rank_in_tier
    FROM member_enriched
)
SELECT
    membership_tier,
    cost_rank_in_tier,
    full_name,
    state,
    assist_count,
    total_cost
FROM ranked
WHERE cost_rank_in_tier <= 3
ORDER BY membership_tier, cost_rank_in_tier;

-- DEMO 1.3: Recursive CTE — member referral chains
WITH RECURSIVE referral_chain AS (
    SELECT
        member_id,
        full_name,
        referral_member_id,
        0                       AS depth,
        full_name               AS chain_path
    FROM MEMBERS
    WHERE referral_member_id IS NULL

    UNION ALL

    SELECT
        m.member_id,
        m.full_name,
        m.referral_member_id,
        rc.depth + 1,
        rc.chain_path || ' → ' || m.full_name
    FROM MEMBERS m
    JOIN referral_chain rc ON m.referral_member_id = rc.member_id
    WHERE rc.depth < 4
)
SELECT
    member_id,
    full_name,
    depth           AS referral_depth,
    chain_path
FROM referral_chain
WHERE depth > 0
ORDER BY depth DESC, member_id
LIMIT 20;

-- ============================================================
-- SECTION 2: Window Functions — Ranking
-- ============================================================

-- DEMO 2.1: ROW_NUMBER, RANK, DENSE_RANK differences
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

-- DEMO 2.2: NTILE — quartile bucketing by tenure
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
-- SECTION 3: Window Functions — Aggregate
-- ============================================================

-- DEMO 3.1: Running total and 3-month rolling average
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
                                               AS rolling_3mo_avg
FROM monthly
ORDER BY month;

-- DEMO 3.2: Year-over-year using LAG(12)
WITH monthly_assists AS (
    SELECT
        YEAR(request_ts) AS yr, MONTH(request_ts) AS mo,
        COUNT(*) AS assists
    FROM ROADSIDE_ASSISTS
    GROUP BY 1, 2
)
SELECT
    yr, mo, assists,
    LAG(assists, 12) OVER (ORDER BY yr, mo)   AS assists_same_mo_prior_year,
    ROUND(
        (assists - LAG(assists, 12) OVER (ORDER BY yr, mo))
        / NULLIF(LAG(assists, 12) OVER (ORDER BY yr, mo), 0) * 100, 1
    )                                         AS yoy_pct_change
FROM monthly_assists
ORDER BY yr, mo;

-- ============================================================
-- SECTION 4: Window Functions — LEAD, LAG, FIRST/LAST VALUE
-- ============================================================

-- DEMO 4.1: LAG — time between consecutive assists
WITH member_assists AS (
    SELECT
        member_id, request_ts, issue_type,
        LAG(request_ts) OVER (PARTITION BY member_id ORDER BY request_ts) AS prev_assist_ts
    FROM ROADSIDE_ASSISTS
)
SELECT
    member_id, request_ts, prev_assist_ts, issue_type,
    DATEDIFF(day, prev_assist_ts, request_ts) AS days_since_last_assist
FROM member_assists
WHERE prev_assist_ts IS NOT NULL
ORDER BY days_since_last_assist
LIMIT 20;

-- DEMO 4.2: LEAD — next interaction preview
SELECT
    member_id, call_ts, topic,
    LEAD(call_ts)  OVER (PARTITION BY member_id ORDER BY call_ts) AS next_call_ts,
    LEAD(topic)    OVER (PARTITION BY member_id ORDER BY call_ts) AS next_call_topic,
    DATEDIFF(day, call_ts, LEAD(call_ts) OVER (PARTITION BY member_id ORDER BY call_ts))
                                                                  AS days_to_next_call
FROM CALL_CENTER_INTERACTIONS
QUALIFY days_to_next_call IS NOT NULL
ORDER BY member_id, call_ts
LIMIT 20;

-- DEMO 4.3: FIRST_VALUE and LAST_VALUE
SELECT
    member_id, request_ts, issue_type,
    FIRST_VALUE(issue_type) OVER (
        PARTITION BY member_id ORDER BY request_ts
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS first_ever_issue,
    LAST_VALUE(issue_type) OVER (
        PARTITION BY member_id ORDER BY request_ts
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS most_recent_issue
FROM ROADSIDE_ASSISTS
QUALIFY ROW_NUMBER() OVER (PARTITION BY member_id ORDER BY request_ts DESC) = 1
ORDER BY member_id
LIMIT 20;

-- ============================================================
-- SECTION 5: PIVOT and UNPIVOT
-- ============================================================

-- DEMO 5.1: PIVOT — issue_type rows into columns
SELECT *
FROM (
    SELECT state, issue_type, 1 AS n
    FROM ROADSIDE_ASSISTS
) src
PIVOT (
    COUNT(n)
    FOR issue_type IN ('flat_tire', 'battery', 'lockout', 'tow', 'fuel')
) AS pvt
ORDER BY state;

-- DEMO 5.2: PIVOT with average cost
SELECT *
FROM (
    SELECT state, issue_type, cost
    FROM ROADSIDE_ASSISTS WHERE resolved_flag = TRUE
) src
PIVOT (
    ROUND(AVG(cost), 2)
    FOR issue_type IN ('flat_tire', 'battery', 'lockout', 'tow', 'fuel')
) AS pvt
ORDER BY state;

-- ============================================================
-- SECTION 6: LATERAL FLATTEN on Nested JSON Arrays
-- ============================================================

-- DEMO 6.1: Explode plan benefits array into rows
SELECT
    p.plan_name,
    f.index        AS benefit_index,
    f.value::VARCHAR  AS benefit
FROM MEMBERSHIP_PLANS p,
LATERAL FLATTEN(input => p.benefits) f
ORDER BY p.plan_id, f.index;

-- DEMO 6.2: Flatten weather VARIANT from roadside assists
SELECT
    assist_id, issue_type,
    weather:conditions::VARCHAR   AS conditions,
    weather:temp_f::INTEGER       AS temp_f,
    weather:wind_mph::INTEGER     AS wind_mph
FROM ROADSIDE_ASSISTS
LIMIT 20;

-- DEMO 6.3: Average response time by weather condition
SELECT
    weather:conditions::VARCHAR      AS weather_condition,
    COUNT(*)                         AS assist_count,
    ROUND(AVG(response_time_min), 1) AS avg_response_min
FROM ROADSIDE_ASSISTS
WHERE resolved_flag = TRUE AND weather:conditions IS NOT NULL
GROUP BY 1
ORDER BY avg_response_min DESC;

-- DEMO 6.4: Flatten adjuster documentation array in CLAIMS
SELECT
    c.claim_id, c.claim_type,
    c.adjuster_notes:priority::VARCHAR  AS priority,
    f.value::VARCHAR                    AS required_document
FROM CLAIMS c,
LATERAL FLATTEN(input => c.adjuster_notes:documentation) f
WHERE c.status = 'Open'
  AND c.adjuster_notes:priority::VARCHAR = 'High'
LIMIT 20;

-- ============================================================
-- SECTION 7: Advanced Analytical Functions
-- ============================================================

-- ------------------------------------------------------------
-- DEMO 7.1: ASOF JOIN — Point-in-Time Join
-- For each roadside assist, find the MOST RECENT call center
-- interaction that occurred BEFORE the assist request.
-- This is the temporal join pattern used in finance (trade to
-- most-recent quote) and operational analytics.
-- ------------------------------------------------------------
SELECT
    ra.assist_id,
    ra.member_id,
    ra.request_ts                             AS assist_time,
    ra.issue_type,
    cci.call_ts                               AS last_call_before_assist,
    cci.topic                                 AS last_call_topic,
    cci.csat_score                            AS last_csat,
    DATEDIFF(day, cci.call_ts, ra.request_ts) AS days_since_last_call
FROM ROADSIDE_ASSISTS ra
ASOF JOIN CALL_CENTER_INTERACTIONS cci
    MATCH_CONDITION (ra.request_ts >= cci.call_ts)
ON ra.member_id = cci.member_id
WHERE ra.member_id BETWEEN 1 AND 200
ORDER BY ra.member_id, ra.request_ts
LIMIT 30;

-- ASOF JOIN business question: members who had low CSAT right before an assist
-- Does a bad service experience lead to a higher-cost assist?
SELECT
    ra.issue_type,
    CASE WHEN cci.csat_score <= 2 THEN 'Low CSAT before assist'
         WHEN cci.csat_score >= 4 THEN 'High CSAT before assist'
         ELSE 'Neutral or no prior call'
    END                                       AS prior_experience,
    COUNT(*)                                  AS assist_count,
    ROUND(AVG(ra.cost), 2)                    AS avg_cost,
    ROUND(AVG(ra.response_time_min), 1)       AS avg_response_min
FROM ROADSIDE_ASSISTS ra
ASOF JOIN CALL_CENTER_INTERACTIONS cci
    MATCH_CONDITION (ra.request_ts >= cci.call_ts)
ON ra.member_id = cci.member_id
WHERE DATEDIFF(day, cci.call_ts, ra.request_ts) <= 30  -- only consider calls within 30 days
GROUP BY 1, 2
ORDER BY 1, 2;

-- ------------------------------------------------------------
-- DEMO 7.2: MATCH_RECOGNIZE — Pattern Matching in Ordered Rows
-- Find members with an escalation pattern: a low-CSAT interaction
-- (satisfaction <= 2) followed by 2 or more additional contacts
-- within 30 days. These are potential churn risks.
-- ------------------------------------------------------------
SELECT
    member_id,
    first_low_csat_ts,
    last_followup_ts,
    followup_count,
    DATEDIFF(day, first_low_csat_ts, last_followup_ts) AS days_of_escalation
FROM CALL_CENTER_INTERACTIONS
MATCH_RECOGNIZE (
    PARTITION BY member_id
    ORDER BY call_ts
    MEASURES
        FIRST(A.call_ts)         AS first_low_csat_ts,
        COUNT(B.interaction_id)  AS followup_count,
        LAST(B.call_ts)          AS last_followup_ts
    ONE ROW PER MATCH
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B{2,})
    DEFINE
        A AS csat_score <= 2,
        B AS call_ts <= DATEADD(day, 30, FIRST(A.call_ts))
)
ORDER BY followup_count DESC
LIMIT 20;

-- MATCH_RECOGNIZE: detect complaint followed by escalation to roadside
-- Pattern: a 'Complaint' interaction followed by a roadside assist within 7 days
-- (Combines call center with assists in a CTE first)
WITH interaction_stream AS (
    SELECT
        member_id,
        call_ts           AS event_ts,
        'CALL'            AS event_type,
        topic             AS detail,
        csat_score
    FROM CALL_CENTER_INTERACTIONS
    UNION ALL
    SELECT
        member_id,
        request_ts,
        'ASSIST'          AS event_type,
        issue_type,
        NULL              AS csat_score
    FROM ROADSIDE_ASSISTS
)
SELECT *
FROM interaction_stream
MATCH_RECOGNIZE (
    PARTITION BY member_id
    ORDER BY event_ts
    MEASURES
        A.event_ts   AS complaint_ts,
        B.event_ts   AS assist_ts,
        A.detail     AS complaint_topic,
        B.detail     AS assist_issue
    ONE ROW PER MATCH
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B)
    DEFINE
        A AS event_type = 'CALL' AND detail = 'Complaint',
        B AS event_type = 'ASSIST'
            AND event_ts <= DATEADD(day, 7, A.event_ts)
)
LIMIT 20;

-- ------------------------------------------------------------
-- DEMO 7.3: RATIO_TO_REPORT — Instant Percentage of Total
-- What share of each state's assists does each issue type represent?
-- No self-join or correlated subquery needed.
-- ------------------------------------------------------------
SELECT
    state,
    issue_type,
    COUNT(*)                                          AS assists,
    ROUND(
        RATIO_TO_REPORT(COUNT(*)) OVER (PARTITION BY state) * 100, 1
    )                                                 AS pct_of_state_total
FROM ROADSIDE_ASSISTS
GROUP BY state, issue_type
ORDER BY state, pct_of_state_total DESC;

-- RATIO_TO_REPORT: member cost share within tier
SELECT
    m.membership_tier,
    m.member_id,
    m.full_name,
    SUM(ra.cost) AS member_total_cost,
    ROUND(
        RATIO_TO_REPORT(SUM(ra.cost)) OVER (PARTITION BY m.membership_tier) * 100, 2
    )            AS pct_of_tier_cost
FROM MEMBERS m
JOIN ROADSIDE_ASSISTS ra ON m.member_id = ra.member_id
WHERE m.status = 'Active'
GROUP BY m.membership_tier, m.member_id, m.full_name
QUALIFY RANK() OVER (PARTITION BY m.membership_tier ORDER BY pct_of_tier_cost DESC) <= 5
ORDER BY m.membership_tier, pct_of_tier_cost DESC;

-- ------------------------------------------------------------
-- DEMO 7.4: CONDITIONAL_CHANGE_EVENT — Detect State Transitions
-- Group consecutive rows where status does NOT change.
-- Each time status changes, a new group number is assigned.
-- ------------------------------------------------------------
-- Simulate a member status history view
WITH member_status_history AS (
    SELECT
        m.member_id,
        m.full_name,
        m.status,
        m.join_date,
        -- Create "change events" based on tier changes
        CONDITIONAL_CHANGE_EVENT(m.membership_tier)
            OVER (PARTITION BY m.state ORDER BY m.join_date)  AS tier_change_group
    FROM MEMBERS m
    WHERE m.state = 'CA'
    ORDER BY m.join_date
)
SELECT
    tier_change_group,
    COUNT(*)    AS members_in_group
FROM member_status_history
GROUP BY 1
ORDER BY 1
LIMIT 20;

-- ------------------------------------------------------------
-- DEMO 7.5: TIME_SLICE — Calendar-Aligned Time Bucketing
-- Aggregate assists into 4-hour operational windows.
-- Useful for staffing analysis and SLA reporting.
-- ------------------------------------------------------------
SELECT
    TIME_SLICE(request_ts, 4, 'HOUR')  AS four_hour_window,
    state,
    COUNT(*)                           AS assist_count,
    ROUND(AVG(response_time_min), 1)   AS avg_response_min
FROM ROADSIDE_ASSISTS
WHERE request_ts >= DATEADD(month, -3, CURRENT_DATE())
GROUP BY 1, 2
ORDER BY 1, assist_count DESC;

-- TIME_SLICE for daily buckets aligned to week start
SELECT
    TIME_SLICE(request_ts, 1, 'WEEK', 'START') AS week_start,
    COUNT(*)                                    AS assists,
    COUNT_IF(NOT resolved_flag)                 AS unresolved
FROM ROADSIDE_ASSISTS
WHERE request_ts >= DATEADD(year, -1, CURRENT_DATE())
GROUP BY 1
ORDER BY 1;
