-- =============================================================================
-- AAA Snowflake SQL Training — Module 5: Snowflake AI Functions
-- 05_ai_functions.sql
--
-- HOW TO USE THIS SCRIPT:
--   Run each section one block at a time in Snowsight.
--   Each demo is labeled with ▶ RUN markers.
--
-- Topics covered:
--   1. AI_COMPLETE — general-purpose LLM inference on structured data
--   2. AI_SENTIMENT — sentiment scoring on text fields
--   3. AI_CLASSIFY — categorize text into labels
--   4. AI_EXTRACT — structured field extraction from free text
--   5. AI_SUMMARIZE — summarize text at scale
--   6. AI_TRANSLATE — multilingual support
--   7. Working with Semi-Structured Data (VARIANT + AI)
--   8. Working with Unstructured Data (documents on stage)
--
-- Prerequisites: Run 00_setup_data.sql first
-- =============================================================================

-- ▶ RUN: Set context
USE WAREHOUSE TRAINING_WH;
USE DATABASE AAA_TRAINING;
USE SCHEMA MEMBER_SERVICES;


-- ============================================================
-- SECTION 1: AI_COMPLETE — General-Purpose LLM Inference
-- ============================================================
-- ┌─────────────────────────────────────────────────────────┐
-- │ AI_COMPLETE sends a prompt to a Cortex LLM and returns  │
-- │ the response as a string. Works on any text column.     │
-- │ Think of it as "ChatGPT inside SQL."                    │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: Simple prompt — generate a description from structured fields
SELECT
    member_id,
    full_name,
    membership_tier,
    state,
    SNOWFLAKE.CORTEX.COMPLETE(
        'snowflake-arctic-instruct',
        'Write a one-sentence member profile for: ' ||
        full_name || ', ' || membership_tier || ' tier member in ' || state ||
        ' who joined on ' || join_date::VARCHAR
    ) AS ai_profile
FROM MEMBERS
WHERE status = 'Active'
LIMIT 3;

-- ▶ RUN: Analyze member behavior patterns using AI
--   Feed structured data into the LLM to get business insights.
WITH member_stats AS (
    SELECT
        m.member_id,
        m.full_name,
        m.membership_tier,
        COUNT(ra.assist_id) AS assist_count,
        ROUND(AVG(ra.response_time_min), 1) AS avg_response_min,
        ROUND(SUM(ra.cost), 2) AS total_cost
    FROM MEMBERS m
    JOIN ROADSIDE_ASSISTS ra ON m.member_id = ra.member_id
    WHERE m.status = 'Active'
    GROUP BY 1, 2, 3
    HAVING assist_count >= 8
    LIMIT 5
)
SELECT
    full_name,
    membership_tier,
    assist_count,
    total_cost,
    SNOWFLAKE.CORTEX.COMPLETE(
        'snowflake-arctic-instruct',
        'A AAA member named ' || full_name || ' (' || membership_tier || ' tier) ' ||
        'has had ' || assist_count::VARCHAR || ' roadside assists costing $' ||
        total_cost::VARCHAR || ' total with average response time of ' ||
        avg_response_min::VARCHAR || ' minutes. ' ||
        'In one sentence, suggest whether this member should be upgraded or needs outreach.'
    ) AS ai_recommendation
FROM member_stats;


-- ============================================================
-- SECTION 2: AI_SENTIMENT — Sentiment Scoring
-- ============================================================
-- ┌─────────────────────────────────────────────────────────┐
-- │ AI_SENTIMENT returns a score from -1.0 (very negative)  │
-- │ to +1.0 (very positive). Works on any text column.      │
-- │ No training needed — works out of the box.              │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: Score sentiment on call center topics
--   Some topics are inherently positive (Plan Upgrade) or negative (Complaint)
SELECT
    topic,
    channel,
    SNOWFLAKE.CORTEX.SENTIMENT(topic) AS topic_sentiment
FROM CALL_CENTER_INTERACTIONS
WHERE topic IN ('Complaint', 'Plan Upgrade', 'Membership Renewal', 'Technical Support', 'General Inquiry')
GROUP BY 1, 2
LIMIT 15;

-- ▶ RUN: Generate synthetic feedback text and score its sentiment
--   (In production, you would use actual customer feedback text)
WITH sample_feedback AS (
    SELECT member_id, call_ts, topic, csat_score,
        CASE
            WHEN csat_score = 5 THEN 'Excellent service, the technician arrived quickly and was very professional'
            WHEN csat_score = 4 THEN 'Good experience overall, slightly longer wait than expected'
            WHEN csat_score = 3 THEN 'Average service, nothing special but got the job done'
            WHEN csat_score = 2 THEN 'Disappointed with the wait time and the technician seemed rushed'
            WHEN csat_score = 1 THEN 'Terrible experience, waited over an hour and problem was not fully resolved'
            ELSE 'No feedback provided'
        END AS feedback_text
    FROM CALL_CENTER_INTERACTIONS
    WHERE csat_score IS NOT NULL
    LIMIT 10
)
SELECT
    member_id,
    csat_score,
    feedback_text,
    ROUND(SNOWFLAKE.CORTEX.SENTIMENT(feedback_text), 3) AS sentiment_score
FROM sample_feedback
ORDER BY sentiment_score;


-- ============================================================
-- SECTION 3: AI_CLASSIFY — Categorize Text into Labels
-- ============================================================
-- ┌─────────────────────────────────────────────────────────┐
-- │ AI_CLASSIFY assigns one label from a provided list to   │
-- │ each input text. Zero-shot classification — no training │
-- │ data required.                                          │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: Classify call center topics into urgency categories
SELECT
    interaction_id,
    topic,
    channel,
    SNOWFLAKE.CORTEX.CLASSIFY_TEXT(
        topic,
        ['Urgent - Immediate Action', 'Standard - Normal Priority', 'Low - Informational Only']
    ) AS urgency_classification
FROM CALL_CENTER_INTERACTIONS
LIMIT 10;

-- ▶ RUN: Classify issue types into operational categories
SELECT
    assist_id,
    issue_type,
    weather:conditions::VARCHAR AS conditions,
    SNOWFLAKE.CORTEX.CLASSIFY_TEXT(
        issue_type || ' during ' || weather:conditions::VARCHAR || ' weather',
        ['Safety Critical', 'Mobility Impaired', 'Convenience Issue']
    ) AS operational_category
FROM ROADSIDE_ASSISTS
WHERE weather:conditions IS NOT NULL
LIMIT 10;


-- ============================================================
-- SECTION 4: AI_EXTRACT — Structured Field Extraction
-- ============================================================
-- ┌─────────────────────────────────────────────────────────┐
-- │ AI_EXTRACT pulls structured fields from free-form text. │
-- │ Returns a JSON object with the requested field names.   │
-- │ Ideal for parsing notes, emails, and descriptions.      │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: Extract structured fields from adjuster notes text
SELECT
    claim_id,
    claim_type,
    adjuster_notes:notes_text::VARCHAR AS raw_notes,
    SNOWFLAKE.CORTEX.EXTRACT_ANSWER(
        adjuster_notes:notes_text::VARCHAR,
        'Who reviewed this claim?'
    ) AS extracted_reviewer
FROM CLAIMS
WHERE adjuster_notes:notes_text IS NOT NULL
LIMIT 5;

-- ▶ RUN: Use AI_COMPLETE for more complex extraction from structured context
--   Extract insights from the combination of structured + semi-structured data
SELECT
    c.claim_id,
    c.claim_type,
    c.amount,
    c.adjuster_notes:priority::VARCHAR AS priority,
    c.adjuster_notes:documentation::VARCHAR AS docs_required,
    SNOWFLAKE.CORTEX.COMPLETE(
        'snowflake-arctic-instruct',
        'Given this insurance claim: Type=' || c.claim_type ||
        ', Amount=$' || c.amount::VARCHAR ||
        ', Priority=' || c.adjuster_notes:priority::VARCHAR ||
        ', Required Documentation=' || c.adjuster_notes:documentation::VARCHAR ||
        '. In one sentence, what is the likely next action for the adjuster?'
    ) AS ai_next_action
FROM CLAIMS c
WHERE c.status = 'Pending'
  AND c.adjuster_notes:priority::VARCHAR = 'High'
LIMIT 5;


-- ============================================================
-- SECTION 5: AI_SUMMARIZE — Summarize Text at Scale
-- ============================================================
-- ┌─────────────────────────────────────────────────────────┐
-- │ AI_SUMMARIZE condenses long text into a shorter summary.│
-- │ Great for processing notes, transcripts, or documents.  │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: Summarize a batch of member interaction descriptions
--   (Using AI_COMPLETE as a summarizer with explicit instruction)
WITH member_history AS (
    SELECT
        m.member_id,
        m.full_name,
        LISTAGG(
            cci.topic || ' via ' || cci.channel ||
            ' (CSAT: ' || COALESCE(cci.csat_score::VARCHAR, 'n/a') || ')',
            '; '
        ) WITHIN GROUP (ORDER BY cci.call_ts) AS interaction_summary
    FROM MEMBERS m
    JOIN CALL_CENTER_INTERACTIONS cci ON m.member_id = cci.member_id
    WHERE m.member_id <= 5
    GROUP BY m.member_id, m.full_name
)
SELECT
    member_id,
    full_name,
    interaction_summary,
    SNOWFLAKE.CORTEX.SUMMARIZE(interaction_summary) AS ai_summary
FROM member_history;


-- ============================================================
-- SECTION 6: AI_TRANSLATE — Multilingual Support
-- ============================================================
-- ┌─────────────────────────────────────────────────────────┐
-- │ AI_TRANSLATE converts text between languages.           │
-- │ Supports 10+ languages out of the box.                  │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: Translate member communications for multilingual support
SELECT
    'Thank you for being a loyal AAA member. Your roadside assistance request has been received and a technician is on the way.'
        AS english_text,
    SNOWFLAKE.CORTEX.TRANSLATE(
        'Thank you for being a loyal AAA member. Your roadside assistance request has been received and a technician is on the way.',
        'en', 'es'
    ) AS spanish_translation,
    SNOWFLAKE.CORTEX.TRANSLATE(
        'Thank you for being a loyal AAA member. Your roadside assistance request has been received and a technician is on the way.',
        'en', 'fr'
    ) AS french_translation;

-- ▶ RUN: Translate claim types for international reporting
SELECT
    claim_type,
    SNOWFLAKE.CORTEX.TRANSLATE(claim_type, 'en', 'es') AS spanish,
    SNOWFLAKE.CORTEX.TRANSLATE(claim_type, 'en', 'de') AS german,
    SNOWFLAKE.CORTEX.TRANSLATE(claim_type, 'en', 'ja') AS japanese
FROM (SELECT DISTINCT claim_type FROM CLAIMS)
ORDER BY claim_type;


-- ============================================================
-- SECTION 7: AI on Semi-Structured Data (VARIANT + AI)
-- ============================================================
-- ┌─────────────────────────────────────────────────────────┐
-- │ Combine VARIANT/JSON data with AI functions to extract  │
-- │ insights from semi-structured payloads at scale.        │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: Analyze weather conditions with AI to assess risk level
SELECT
    assist_id,
    issue_type,
    weather:conditions::VARCHAR AS conditions,
    weather:temp_f::INTEGER AS temp_f,
    weather:wind_mph::INTEGER AS wind_mph,
    weather:precip_in::FLOAT AS precip_in,
    SNOWFLAKE.CORTEX.COMPLETE(
        'snowflake-arctic-instruct',
        'Given weather conditions: ' || weather:conditions::VARCHAR ||
        ', temperature ' || weather:temp_f::VARCHAR || 'F' ||
        ', wind ' || weather:wind_mph::VARCHAR || ' mph' ||
        ', precipitation ' || weather:precip_in::VARCHAR || ' inches. ' ||
        'Rate the driving safety risk as Low, Medium, or High in one word.'
    ) AS ai_risk_level
FROM ROADSIDE_ASSISTS
WHERE weather IS NOT NULL
LIMIT 5;

-- ▶ RUN: Extract insights from JSON adjuster notes using AI
SELECT
    c.claim_id,
    c.adjuster_notes AS raw_json,
    SNOWFLAKE.CORTEX.COMPLETE(
        'snowflake-arctic-instruct',
        'Analyze this claim metadata and provide a one-sentence risk assessment: ' ||
        c.adjuster_notes::VARCHAR
    ) AS ai_risk_assessment
FROM CLAIMS c
WHERE c.adjuster_notes:priority::VARCHAR = 'High'
  AND c.status = 'Open'
LIMIT 3;

-- ▶ RUN: Flatten benefits array + AI enrichment
--   Take each benefit text and generate a customer-friendly description
SELECT
    p.plan_name,
    f.value::VARCHAR AS benefit,
    SNOWFLAKE.CORTEX.COMPLETE(
        'snowflake-arctic-instruct',
        'Rewrite this AAA membership benefit as a brief, compelling marketing bullet point (max 15 words): ' ||
        f.value::VARCHAR
    ) AS marketing_copy
FROM MEMBERSHIP_PLANS p,
LATERAL FLATTEN(input => p.benefits) f
WHERE p.plan_name = 'Premier';


-- ============================================================
-- SECTION 8: AI on Unstructured Data (Documents)
-- ============================================================
-- ┌─────────────────────────────────────────────────────────┐
-- │ Snowflake can process files (PDFs, images, text) stored │
-- │ on stages using AI_PARSE_DOCUMENT and AI_COMPLETE with  │
-- │ file URLs. This section demonstrates the pattern.       │
-- │                                                          │
-- │ NOTE: Requires a stage with uploaded documents. We will │
-- │ simulate unstructured data by creating text documents.  │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: Create a stage for unstructured documents
CREATE STAGE IF NOT EXISTS AAA_TRAINING.MEMBER_SERVICES.DOCUMENTS
    COMMENT = 'Stage for unstructured document demos';

-- ▶ RUN: Create a table to simulate unstructured document content
--   (In production, these would be actual files on a stage)
CREATE OR REPLACE TABLE DOCUMENT_CONTENT (
    doc_id INTEGER,
    doc_type VARCHAR(50),
    doc_name VARCHAR(200),
    content_text VARCHAR(10000),
    created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO DOCUMENT_CONTENT (doc_id, doc_type, doc_name, content_text)
SELECT 1, 'Incident Report',  'incident_2024_001.txt',
    'INCIDENT REPORT - Case #2024-001\n' ||
    'Date: January 15, 2024\n' ||
    'Location: Interstate 405, Los Angeles, CA\n' ||
    'Member: John Smith (ID: 4521)\n' ||
    'Vehicle: 2020 Toyota Camry\n' ||
    'Issue: Vehicle stalled in the fast lane during rush hour traffic.\n' ||
    'Technician arrived in 22 minutes. Diagnosed as failed alternator.\n' ||
    'Vehicle towed to nearest AAA-approved repair facility (12 miles).\n' ||
    'Resolution: Tow completed successfully. Member transported to facility.\n' ||
    'Safety Note: CHP assisted with traffic control during service.'
UNION ALL
SELECT 2, 'Claim Letter', 'claim_letter_2024_042.txt',
    'Dear Claims Department,\n\n' ||
    'I am writing to file a claim for damage to my vehicle that occurred on February 3, 2024. ' ||
    'While driving on Route 66 near Flagstaff, Arizona, I hit a large pothole that was not ' ||
    'marked or visible due to heavy rain. The impact caused damage to my front right tire, ' ||
    'wheel rim, and suspension. I had to call AAA roadside assistance (service call #RA-8834). ' ||
    'The estimated repair cost from my mechanic is $2,847.50.\n\n' ||
    'I have attached photos of the damage, the repair estimate, and the police report.\n\n' ||
    'Policy Number: AAA-AZ-2024-7891\n' ||
    'Member since: 2019\n' ||
    'Tier: Premier\n\n' ||
    'Please process this claim at your earliest convenience.\n' ||
    'Sincerely, Maria Gonzalez'
UNION ALL
SELECT 3, 'Service Note', 'service_note_tech_report.txt',
    'TECHNICIAN SERVICE REPORT\n' ||
    'Tech ID: T-0847 (Rodriguez)\n' ||
    'Date: March 22, 2024\n' ||
    'Service Call: SC-12445\n\n' ||
    'Arrived on scene at 3:47 PM. Member vehicle (2018 Honda CR-V) had flat tire on rear passenger side. ' ||
    'Tire showed significant sidewall damage, likely from curb impact. Spare tire was present but ' ||
    'member was unable to locate jack. Installed spare tire and advised member to replace both rear ' ||
    'tires due to uneven wear pattern observed on remaining rear tire. ' ||
    'Member expressed concern about cost — recommended AAA partner discount at Discount Tire. ' ||
    'Total service time: 28 minutes. Member satisfaction: appeared satisfied, thanked technician.';

-- ▶ RUN: Use AI to extract structured data from unstructured documents
SELECT
    doc_id,
    doc_type,
    doc_name,
    SNOWFLAKE.CORTEX.COMPLETE(
        'snowflake-arctic-instruct',
        'Extract the following fields from this document as JSON: ' ||
        '{member_name, date, location, issue_type, estimated_cost, resolution}. ' ||
        'If a field is not mentioned, use null. Document:\n\n' || content_text
    ) AS extracted_fields
FROM DOCUMENT_CONTENT;

-- ▶ RUN: Use AI to classify document types and urgency
SELECT
    doc_id,
    doc_name,
    SNOWFLAKE.CORTEX.CLASSIFY_TEXT(
        content_text,
        ['Emergency Incident', 'Insurance Claim', 'Routine Service', 'Complaint']
    ) AS doc_classification,
    SNOWFLAKE.CORTEX.SENTIMENT(content_text) AS doc_sentiment
FROM DOCUMENT_CONTENT;

-- ▶ RUN: Summarize each document into a one-line synopsis
SELECT
    doc_id,
    doc_type,
    SNOWFLAKE.CORTEX.SUMMARIZE(content_text) AS one_line_summary
FROM DOCUMENT_CONTENT;

-- ▶ RUN: Ask questions about documents using AI_COMPLETE (RAG-style pattern)
--   This simulates the "ask a question about a document" use case
SELECT
    doc_id,
    doc_name,
    SNOWFLAKE.CORTEX.EXTRACT_ANSWER(
        content_text,
        'What was the total cost or estimate mentioned?'
    ) AS cost_answer,
    SNOWFLAKE.CORTEX.EXTRACT_ANSWER(
        content_text,
        'What vehicle was involved?'
    ) AS vehicle_answer
FROM DOCUMENT_CONTENT;


-- ============================================================
-- SECTION 9: Putting It All Together — AI-Powered Pipeline
-- ============================================================
-- ┌─────────────────────────────────────────────────────────┐
-- │ Combine multiple AI functions in a single query to      │
-- │ build an AI-enriched analytics pipeline.                │
-- └─────────────────────────────────────────────────────────┘

-- ▶ RUN: AI-enriched member risk assessment pipeline
--   Combines structured data + semi-structured + AI inference
WITH member_profile AS (
    SELECT
        m.member_id,
        m.full_name,
        m.membership_tier,
        m.state,
        COUNT(ra.assist_id) AS assist_count,
        ROUND(AVG(ra.response_time_min), 1) AS avg_response_min,
        ROUND(SUM(ra.cost), 2) AS total_cost,
        MAX(ra.weather:conditions::VARCHAR) AS last_weather,
        MAX(cci.csat_score) AS best_csat,
        MIN(cci.csat_score) AS worst_csat
    FROM MEMBERS m
    LEFT JOIN ROADSIDE_ASSISTS ra ON m.member_id = ra.member_id
    LEFT JOIN CALL_CENTER_INTERACTIONS cci ON m.member_id = cci.member_id
    WHERE m.status = 'Active'
      AND m.member_id <= 10
    GROUP BY 1, 2, 3, 4
)
SELECT
    member_id,
    full_name,
    membership_tier,
    assist_count,
    total_cost,
    -- AI sentiment on the member's tier + cost profile
    SNOWFLAKE.CORTEX.SENTIMENT(
        full_name || ' is a ' || membership_tier || ' member who has spent $' ||
        total_cost::VARCHAR || ' on ' || assist_count::VARCHAR || ' assists'
    ) AS profile_sentiment,
    -- AI-generated recommendation
    SNOWFLAKE.CORTEX.COMPLETE(
        'snowflake-arctic-instruct',
        'AAA member ' || full_name || ' (' || membership_tier || ', ' || state || ') ' ||
        'has ' || assist_count::VARCHAR || ' assists totaling $' || total_cost::VARCHAR ||
        '. CSAT range: ' || COALESCE(worst_csat::VARCHAR,'n/a') || ' to ' ||
        COALESCE(best_csat::VARCHAR,'n/a') ||
        '. In 10 words or less, what action should AAA take?'
    ) AS ai_action
FROM member_profile
ORDER BY total_cost DESC;


-- ============================================================
-- REFERENCE: Available Snowflake Cortex AI Functions
-- ============================================================
-- ┌─────────────────────────────────────────────────────────┐
-- │ Function             │ Purpose                          │
-- │──────────────────────│──────────────────────────────────│
-- │ CORTEX.COMPLETE      │ General LLM inference (any task) │
-- │ CORTEX.SENTIMENT     │ Sentiment score (-1 to +1)       │
-- │ CORTEX.SUMMARIZE     │ Text summarization               │
-- │ CORTEX.TRANSLATE     │ Language translation              │
-- │ CORTEX.CLASSIFY_TEXT │ Zero-shot text classification    │
-- │ CORTEX.EXTRACT_ANSWER│ Question answering from text     │
-- │ CORTEX.EMBED_TEXT    │ Generate vector embeddings       │
-- │ AI_PARSE_DOCUMENT    │ Extract text from PDFs/images    │
-- │ AI_EXTRACT           │ Structured extraction from docs  │
-- │ AI_CLASSIFY          │ Document classification          │
-- └─────────────────────────────────────────────────────────┘
--
-- Models available for COMPLETE:
--   snowflake-arctic-instruct  — Snowflake's own model (fast, efficient)
--   mistral-large2             — Strong general purpose
--   llama3.1-70b              — Meta's open model
--   llama3.1-8b               — Smaller/faster variant
--
-- All functions run INSIDE Snowflake — no data leaves your account.
-- No API keys, no external services, no egress charges.
