-- =============================================================================
-- AAA Snowflake SQL Training — Data Setup
-- 00_setup_data.sql
--
-- Creates and populates the AAA_TRAINING database with realistic synthetic
-- data for the training modules. Run this script once before all demos.
--
-- Tables created:
--   MEMBER_SERVICES.MEMBERSHIP_PLANS   (~3 rows)
--   MEMBER_SERVICES.MEMBERS            (~10,000 rows)
--   MEMBER_SERVICES.ROADSIDE_ASSISTS   (~50,000 rows)
--   MEMBER_SERVICES.CLAIMS             (~20,000 rows)
--   MEMBER_SERVICES.CALL_CENTER_INTERACTIONS (~30,000 rows)
--
-- Run time: ~60 seconds on an XS warehouse
-- =============================================================================

-- ----------------------------------------------------------------------------
-- 1. Environment setup
-- ----------------------------------------------------------------------------
USE ROLE SYSADMIN;
CREATE WAREHOUSE IF NOT EXISTS TRAINING_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    COMMENT = 'Warehouse for AAA training demos';

USE WAREHOUSE TRAINING_WH;

CREATE DATABASE IF NOT EXISTS AAA_TRAINING
    COMMENT = 'AAA Snowflake SQL Training — synthetic demo data';

CREATE SCHEMA IF NOT EXISTS AAA_TRAINING.MEMBER_SERVICES
    COMMENT = 'Member services data for training demos';

USE DATABASE AAA_TRAINING;
USE SCHEMA MEMBER_SERVICES;

-- ----------------------------------------------------------------------------
-- 2. Lookup / reference tables
-- ----------------------------------------------------------------------------

-- Drop and recreate for clean re-runs
DROP TABLE IF EXISTS MEMBERSHIP_PLANS;
DROP TABLE IF EXISTS MEMBERS;
DROP TABLE IF EXISTS ROADSIDE_ASSISTS;
DROP TABLE IF EXISTS CLAIMS;
DROP TABLE IF EXISTS CALL_CENTER_INTERACTIONS;

CREATE OR REPLACE TABLE MEMBERSHIP_PLANS (
    plan_id         INTEGER        NOT NULL,
    plan_name       VARCHAR(50)    NOT NULL,
    monthly_cost    NUMBER(6,2)    NOT NULL,
    annual_cost     NUMBER(8,2)    NOT NULL,
    benefits        VARIANT        NOT NULL,  -- JSON array of benefit strings
    CONSTRAINT pk_plans PRIMARY KEY (plan_id)
)
COMMENT = 'AAA membership tiers — Basic, Plus, Premier';

INSERT INTO MEMBERSHIP_PLANS (plan_id, plan_name, monthly_cost, annual_cost, benefits)
SELECT 1, 'Basic', 7.00, 84.00,
    PARSE_JSON('["Roadside Towing up to 5 miles","Battery Jump-Start","Lockout Service","Fuel Delivery"]')
UNION ALL
SELECT 2, 'Plus', 11.00, 132.00,
    PARSE_JSON('["Roadside Towing up to 100 miles","Battery Jump-Start","Lockout Service","Fuel Delivery","Trip Interruption Coverage","Travel Discounts"]')
UNION ALL
SELECT 3, 'Premier', 15.00, 180.00,
    PARSE_JSON('["Roadside Towing up to 200 miles","Battery Jump-Start","Lockout Service","Fuel Delivery","Trip Interruption Coverage","Travel Discounts","Identity Theft Monitoring","Concierge Service","RV/Motorcycle Coverage"]');

-- ----------------------------------------------------------------------------
-- 3. MEMBERS — 10,000 rows
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE MEMBERS (
    member_id           INTEGER        NOT NULL,
    full_name           VARCHAR(100)   NOT NULL,
    email               VARCHAR(150)   NOT NULL,
    phone               VARCHAR(20),
    state               VARCHAR(2)     NOT NULL,
    join_date           DATE           NOT NULL,
    membership_tier     VARCHAR(20)    NOT NULL,  -- Basic | Plus | Premier
    renewal_date        DATE           NOT NULL,
    status              VARCHAR(20)    NOT NULL,  -- Active | Lapsed | Cancelled
    referral_member_id  INTEGER,                  -- FK to MEMBERS (self-referential)
    CONSTRAINT pk_members PRIMARY KEY (member_id)
)
COMMENT = 'AAA member master — 10K synthetic members across 10 states';

-- Seed with realistic names using SEQ + array lookups
INSERT INTO MEMBERS
WITH
first_names AS (
    SELECT $1::VARCHAR AS fn FROM VALUES
    ('James'),('Mary'),('Robert'),('Patricia'),('John'),('Jennifer'),('Michael'),('Linda'),
    ('William'),('Barbara'),('David'),('Elizabeth'),('Richard'),('Susan'),('Joseph'),('Jessica'),
    ('Thomas'),('Sarah'),('Charles'),('Karen'),('Christopher'),('Lisa'),('Daniel'),('Nancy'),
    ('Matthew'),('Betty'),('Anthony'),('Margaret'),('Mark'),('Sandra'),('Donald'),('Ashley'),
    ('Steven'),('Dorothy'),('Paul'),('Kimberly'),('Andrew'),('Emily'),('Joshua'),('Donna'),
    ('Kenneth'),('Michelle'),('Kevin'),('Carol'),('Brian'),('Amanda'),('George'),('Melissa')
),
last_names AS (
    SELECT $1::VARCHAR AS ln FROM VALUES
    ('Smith'),('Johnson'),('Williams'),('Brown'),('Jones'),('Garcia'),('Miller'),('Davis'),
    ('Rodriguez'),('Martinez'),('Hernandez'),('Lopez'),('Gonzalez'),('Wilson'),('Anderson'),
    ('Thomas'),('Taylor'),('Moore'),('Jackson'),('Martin'),('Lee'),('Perez'),('Thompson'),
    ('White'),('Harris'),('Sanchez'),('Clark'),('Ramirez'),('Lewis'),('Robinson'),('Walker'),
    ('Young'),('Allen'),('King'),('Wright'),('Scott'),('Torres'),('Nguyen'),('Hill'),('Flores'),
    ('Green'),('Adams'),('Nelson'),('Baker'),('Hall'),('Rivera'),('Campbell'),('Mitchell')
),
states AS (
    SELECT $1::VARCHAR AS st FROM VALUES
    ('CA'),('TX'),('FL'),('NY'),('PA'),('OH'),('GA'),('NC'),('MI'),('AZ')
),
tiers AS (
    SELECT $1::VARCHAR AS tier, $2::FLOAT AS weight FROM VALUES
    ('Basic', 0.50), ('Plus', 0.35), ('Premier', 0.15)
),
seq AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS rn
    FROM TABLE(GENERATOR(ROWCOUNT => 10000))
),
fn_arr AS (SELECT ARRAY_AGG(fn) AS arr FROM first_names),
ln_arr AS (SELECT ARRAY_AGG(ln) AS arr FROM last_names),
st_arr AS (SELECT ARRAY_AGG(st) AS arr FROM states)
SELECT
    s.rn                                                                    AS member_id,
    fn_arr.arr[ABS(RANDOM()) % ARRAY_SIZE(fn_arr.arr)]::VARCHAR
        || ' ' ||
        ln_arr.arr[ABS(RANDOM()) % ARRAY_SIZE(ln_arr.arr)]::VARCHAR        AS full_name,
    LOWER(
        ln_arr.arr[ABS(RANDOM()) % ARRAY_SIZE(ln_arr.arr)]::VARCHAR
        || s.rn::VARCHAR
        || '@example.com'
    )                                                                       AS email,
    '(' || (UNIFORM(200,999,RANDOM()))::VARCHAR
        || ') ' || (UNIFORM(200,999,RANDOM()))::VARCHAR
        || '-' || LPAD((UNIFORM(0,9999,RANDOM()))::VARCHAR,4,'0')           AS phone,
    st_arr.arr[ABS(RANDOM()) % ARRAY_SIZE(st_arr.arr)]::VARCHAR            AS state,
    DATEADD(day, -ABS(RANDOM()) % 3650, CURRENT_DATE())                    AS join_date,
    CASE
        WHEN ABS(RANDOM()) % 100 < 50  THEN 'Basic'
        WHEN ABS(RANDOM()) % 100 < 85  THEN 'Plus'
        ELSE 'Premier'
    END                                                                     AS membership_tier,
    DATEADD(day, 365, DATEADD(day, -ABS(RANDOM()) % 3650, CURRENT_DATE())) AS renewal_date,
    CASE
        WHEN ABS(RANDOM()) % 100 < 75 THEN 'Active'
        WHEN ABS(RANDOM()) % 100 < 90 THEN 'Lapsed'
        ELSE 'Cancelled'
    END                                                                     AS status,
    -- ~30% of members have a referral — reference an earlier member_id
    CASE WHEN ABS(RANDOM()) % 10 < 3 AND s.rn > 1
         THEN (ABS(RANDOM()) % (s.rn - 1)) + 1
         ELSE NULL
    END                                                                     AS referral_member_id
FROM seq s, fn_arr, ln_arr, st_arr;

-- ----------------------------------------------------------------------------
-- 4. ROADSIDE_ASSISTS — ~50,000 rows
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE ROADSIDE_ASSISTS (
    assist_id           INTEGER     NOT NULL,
    member_id           INTEGER     NOT NULL,
    request_ts          TIMESTAMP_NTZ NOT NULL,
    issue_type          VARCHAR(30) NOT NULL,  -- flat_tire | battery | lockout | tow | fuel
    state               VARCHAR(2)  NOT NULL,
    response_time_min   INTEGER     NOT NULL,  -- minutes until technician arrival
    resolved_flag       BOOLEAN     NOT NULL,
    cost                NUMBER(8,2) NOT NULL,
    weather             VARIANT,               -- JSON: {conditions, temp_f, precip}
    CONSTRAINT pk_assists PRIMARY KEY (assist_id)
)
COMMENT = 'Roadside assistance requests — includes semi-structured weather data';

INSERT INTO ROADSIDE_ASSISTS
WITH
issue_types AS (
    SELECT $1::VARCHAR AS issue, $2::NUMBER(8,2) AS base_cost FROM VALUES
    ('flat_tire', 65.00), ('battery', 85.00), ('lockout', 55.00),
    ('tow', 120.00), ('fuel', 45.00)
),
conditions_arr AS (
    SELECT ARRAY_CONSTRUCT('Clear','Cloudy','Rain','Snow','Fog','Thunderstorm','Windy') AS arr
),
states AS (SELECT $1::VARCHAR AS st FROM VALUES ('CA'),('TX'),('FL'),('NY'),('PA'),('OH'),('GA'),('NC'),('MI'),('AZ')),
st_arr AS (SELECT ARRAY_AGG(st) AS arr FROM states),
issue_arr AS (SELECT ARRAY_AGG(issue) AS arr, ARRAY_AGG(base_cost) AS cost_arr FROM issue_types),
seq AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS rn
    FROM TABLE(GENERATOR(ROWCOUNT => 50000))
)
SELECT
    s.rn                                                AS assist_id,
    (ABS(RANDOM()) % 10000) + 1                        AS member_id,
    DATEADD(second,
        -(ABS(RANDOM()) % (3 * 365 * 86400)),
        CURRENT_TIMESTAMP())                            AS request_ts,
    issue_arr.arr[ABS(RANDOM()) % 5]::VARCHAR          AS issue_type,
    st_arr.arr[ABS(RANDOM()) % 10]::VARCHAR            AS state,
    UNIFORM(8, 90, RANDOM())                           AS response_time_min,
    (ABS(RANDOM()) % 100) < 92                         AS resolved_flag,
    issue_arr.cost_arr[ABS(RANDOM()) % 5]::NUMBER(8,2)
        * (0.80 + (ABS(RANDOM()) % 40)::FLOAT / 100.0) AS cost,
    OBJECT_CONSTRUCT(
        'conditions', conditions_arr.arr[ABS(RANDOM()) % 7]::VARCHAR,
        'temp_f',     UNIFORM(10, 105, RANDOM()),
        'precip_in',  ROUND((ABS(RANDOM()) % 200)::FLOAT / 100.0, 2),
        'wind_mph',   UNIFORM(0, 45, RANDOM())
    )                                                   AS weather
FROM seq s, issue_arr, st_arr, conditions_arr;

-- ----------------------------------------------------------------------------
-- 5. CLAIMS — ~20,000 rows
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE CLAIMS (
    claim_id        INTEGER         NOT NULL,
    member_id       INTEGER         NOT NULL,
    claim_date      DATE            NOT NULL,
    claim_type      VARCHAR(40)     NOT NULL,
    amount          NUMBER(10,2)    NOT NULL,
    status          VARCHAR(20)     NOT NULL,  -- Open | Approved | Denied | Pending
    adjuster_id     INTEGER,
    adjuster_notes  VARIANT,                   -- JSON with structured notes
    CONSTRAINT pk_claims PRIMARY KEY (claim_id)
)
COMMENT = 'Insurance and service claims with semi-structured adjuster notes';

INSERT INTO CLAIMS
WITH
claim_types AS (
    SELECT $1::VARCHAR AS ct, $2::NUMBER(10,2) AS avg_amt FROM VALUES
    ('Auto Accident', 4500.00), ('Home Damage', 8000.00),
    ('Roadside Extended', 250.00), ('Travel Insurance', 1200.00),
    ('Identity Theft', 2000.00), ('RV Damage', 5500.00)
),
statuses AS (SELECT $1::VARCHAR AS st FROM VALUES ('Open'),('Approved'),('Denied'),('Pending')),
ct_arr AS (SELECT ARRAY_AGG(ct) AS arr, ARRAY_AGG(avg_amt) AS amt_arr FROM claim_types),
st_arr AS (SELECT ARRAY_AGG(st) AS arr FROM statuses),
seq AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS rn
    FROM TABLE(GENERATOR(ROWCOUNT => 20000))
)
SELECT
    s.rn                                                        AS claim_id,
    (ABS(RANDOM()) % 10000) + 1                                 AS member_id,
    DATEADD(day, -(ABS(RANDOM()) % 1095), CURRENT_DATE())       AS claim_date,
    ct_arr.arr[ABS(RANDOM()) % 6]::VARCHAR                      AS claim_type,
    ct_arr.amt_arr[ABS(RANDOM()) % 6]::NUMBER(10,2)
        * (0.50 + (ABS(RANDOM()) % 150)::FLOAT / 100.0)         AS amount,
    st_arr.arr[ABS(RANDOM()) % 4]::VARCHAR                      AS status,
    (ABS(RANDOM()) % 50) + 1                                    AS adjuster_id,
    OBJECT_CONSTRUCT(
        'priority',       CASE WHEN ABS(RANDOM()) % 10 < 2 THEN 'High'
                               WHEN ABS(RANDOM()) % 10 < 6 THEN 'Medium'
                               ELSE 'Low' END,
        'follow_up',      (ABS(RANDOM()) % 10) < 3,
        'documentation',  ARRAY_CONSTRUCT(
                            CASE WHEN (ABS(RANDOM()) % 2) = 0 THEN 'Police Report' ELSE 'Photos' END,
                            CASE WHEN (ABS(RANDOM()) % 2) = 0 THEN 'Receipts' ELSE 'Estimates' END
                          ),
        'notes_text',     'Reviewed by adjuster ' || ((ABS(RANDOM()) % 50) + 1)::VARCHAR
    )                                                           AS adjuster_notes
FROM seq s, ct_arr, st_arr;

-- ----------------------------------------------------------------------------
-- 6. CALL_CENTER_INTERACTIONS — ~30,000 rows
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE CALL_CENTER_INTERACTIONS (
    interaction_id  INTEGER         NOT NULL,
    member_id       INTEGER         NOT NULL,
    call_ts         TIMESTAMP_NTZ   NOT NULL,
    channel         VARCHAR(20)     NOT NULL,  -- phone | chat | app | email
    topic           VARCHAR(50)     NOT NULL,
    duration_sec    INTEGER         NOT NULL,
    csat_score      INTEGER,                   -- 1-5, NULL if not surveyed
    resolved_flag   BOOLEAN         NOT NULL,
    CONSTRAINT pk_interactions PRIMARY KEY (interaction_id)
)
COMMENT = 'Call center and digital channel interactions';

INSERT INTO CALL_CENTER_INTERACTIONS
WITH
channels AS (SELECT $1::VARCHAR AS ch FROM VALUES ('phone'),('chat'),('app'),('email')),
topics AS (
    SELECT $1::VARCHAR AS tp FROM VALUES
    ('Billing Question'), ('Roadside Request'), ('Claim Status'),
    ('Membership Renewal'), ('Plan Upgrade'), ('Account Update'),
    ('Complaint'), ('General Inquiry'), ('Technical Support')
),
ch_arr AS (SELECT ARRAY_AGG(ch) AS arr FROM channels),
tp_arr AS (SELECT ARRAY_AGG(tp) AS arr FROM topics),
seq AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS rn
    FROM TABLE(GENERATOR(ROWCOUNT => 30000))
)
SELECT
    s.rn                                                        AS interaction_id,
    (ABS(RANDOM()) % 10000) + 1                                 AS member_id,
    DATEADD(second,
        -(ABS(RANDOM()) % (2 * 365 * 86400)),
        CURRENT_TIMESTAMP())                                    AS call_ts,
    ch_arr.arr[ABS(RANDOM()) % 4]::VARCHAR                      AS channel,
    tp_arr.arr[ABS(RANDOM()) % 9]::VARCHAR                      AS topic,
    UNIFORM(30, 1800, RANDOM())                                 AS duration_sec,
    CASE WHEN (ABS(RANDOM()) % 10) < 6
         THEN UNIFORM(1, 5, RANDOM())
         ELSE NULL
    END                                                         AS csat_score,
    (ABS(RANDOM()) % 100) < 88                                  AS resolved_flag
FROM seq s, ch_arr, tp_arr;

-- ----------------------------------------------------------------------------
-- 7. Row count verification
-- ----------------------------------------------------------------------------

SELECT 'MEMBERSHIP_PLANS'          AS table_name, COUNT(*) AS row_count FROM MEMBERSHIP_PLANS
UNION ALL
SELECT 'MEMBERS',                  COUNT(*) FROM MEMBERS
UNION ALL
SELECT 'ROADSIDE_ASSISTS',         COUNT(*) FROM ROADSIDE_ASSISTS
UNION ALL
SELECT 'CLAIMS',                   COUNT(*) FROM CLAIMS
UNION ALL
SELECT 'CALL_CENTER_INTERACTIONS', COUNT(*) FROM CALL_CENTER_INTERACTIONS
ORDER BY 1;
