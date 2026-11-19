/* =====================================================================
   Client Support Analytics, Step 4: stretch goals
   Prereq: Steps 1-2 scripts have run (tables, v_ticket_enriched, v_at_risk_clients,
           dataset_config). Run in ONE worksheet, top to bottom.

   Sections
     1. Data quality checks + audit table (run this first)
     2. Weekly client health report (the "send to an account manager" query)
     3. AI functions on ticket text (AI_SENTIMENT, AI_CLASSIFY, AI_SUMMARIZE_AGG)
     4. Findings queries for your README

   COST NOTE: Section 3 calls AI functions, which bill credits per token.
   The text here is short and the sample is ~2,000 tickets, so it's cheap, but do NOT
   run these functions over all 150,000 tickets without checking the cost first.
   ===================================================================== */

USE ROLE SYSADMIN;
USE WAREHOUSE SUPPORT_WH;
USE SCHEMA SUPPORT_ANALYTICS.CORE;


/* =====================================================================
   1. DATA QUALITY CHECKS
   ===================================================================== */

CREATE OR REPLACE TABLE dq_audit_log (
  run_id       STRING,
  run_ts       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  check_name   STRING,
  severity     STRING,          -- ERROR = must fix, WARN = investigate
  table_name   STRING,
  failed_rows  NUMBER,
  total_rows   NUMBER,
  failure_pct  NUMBER(8,4) AS (IFF(total_rows = 0, 0, 100 * failed_rows / total_rows)),
  status       STRING,          -- PASS / WARN / FAIL
  details      STRING
);

CREATE OR REPLACE PROCEDURE run_dq_checks()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
  rid STRING DEFAULT UUID_STRING();
BEGIN
  INSERT INTO dq_audit_log
    (run_id, check_name, severity, table_name, failed_rows, total_rows, status, details)
  SELECT
    :rid, check_name, severity, table_name, failed_rows, total_rows,
    IFF(failed_rows = 0, 'PASS', IFF(severity = 'ERROR', 'FAIL', 'WARN')),
    details
  FROM (
    SELECT 'resolved_before_created' AS check_name, 'ERROR' AS severity, 'FACT_TICKETS' AS table_name,
           COUNT_IF(resolved_at < created_at) AS failed_rows, COUNT(*) AS total_rows,
           'Resolved timestamp is earlier than created timestamp' AS details
    FROM fact_tickets
    UNION ALL
    SELECT 'first_response_before_created', 'ERROR', 'FACT_TICKETS',
           COUNT_IF(first_response_at < created_at), COUNT(*),
           'First response timestamp is earlier than created timestamp'
    FROM fact_tickets
    UNION ALL
    SELECT 'resolved_before_first_response', 'WARN', 'FACT_TICKETS',
           COUNT_IF(resolved_at < first_response_at), COUNT(*),
           'Ticket resolved before any first response (overlaps with the created check)'
    FROM fact_tickets
    UNION ALL
    SELECT 'missing_agent', 'WARN', 'FACT_TICKETS',
           COUNT_IF(agent_id IS NULL), COUNT(*),
           'Ticket has no assigned agent'
    FROM fact_tickets
    UNION ALL
    SELECT 'orphan_client', 'ERROR', 'FACT_TICKETS',
           COUNT_IF(c.client_id IS NULL), COUNT(*),
           'client_id has no match in DIM_CLIENTS'
    FROM fact_tickets f LEFT JOIN dim_clients c ON c.client_id = f.client_id
    UNION ALL
    SELECT 'orphan_agent', 'ERROR', 'FACT_TICKETS',
           COUNT_IF(f.agent_id IS NOT NULL AND a.agent_id IS NULL), COUNT(*),
           'agent_id is set but has no match in DIM_AGENTS'
    FROM fact_tickets f LEFT JOIN dim_agents a ON a.agent_id = f.agent_id
    UNION ALL
    SELECT 'invalid_priority', 'ERROR', 'FACT_TICKETS',
           COUNT_IF(p.priority IS NULL), COUNT(*),
           'priority has no SLA policy'
    FROM fact_tickets f LEFT JOIN dim_sla_policy p ON p.priority = f.priority
    UNION ALL
    SELECT 'duplicate_ticket_id', 'ERROR', 'FACT_TICKETS',
           COUNT(*) - COUNT(DISTINCT ticket_id), COUNT(*),
           'ticket_id appears more than once'
    FROM fact_tickets
    UNION ALL
    SELECT 'csat_out_of_range', 'ERROR', 'FACT_TICKETS',
           COUNT_IF(csat_score IS NOT NULL AND csat_score NOT BETWEEN 1 AND 5), COUNT(*),
           'CSAT score outside 1-5'
    FROM fact_tickets
    UNION ALL
    SELECT 'csat_on_unresolved_ticket', 'WARN', 'FACT_TICKETS',
           COUNT_IF(csat_score IS NOT NULL AND resolved_at IS NULL), COUNT(*),
           'Survey score recorded on a ticket that is not resolved'
    FROM fact_tickets
    UNION ALL
    SELECT 'status_inconsistent_with_resolved_at', 'ERROR', 'FACT_TICKETS',
           COUNT_IF((resolved_at IS NOT NULL AND status NOT IN ('Closed','Resolved'))
                 OR (resolved_at IS NULL     AND status IN ('Closed','Resolved'))), COUNT(*),
           'Status says closed but no resolved_at, or open status with a resolved_at'
    FROM fact_tickets
    UNION ALL
    SELECT 'future_dated_ticket', 'ERROR', 'FACT_TICKETS',
           COUNT_IF(created_at > (SELECT as_of_ts FROM dataset_config)), COUNT(*),
           'created_at is after the dataset as-of timestamp'
    FROM fact_tickets
    UNION ALL
    SELECT 'stale_open_ticket_30d', 'WARN', 'FACT_TICKETS',
           COUNT_IF(resolved_at IS NULL
                    AND created_at < DATEADD(day, -30, (SELECT as_of_ts FROM dataset_config))), COUNT(*),
           'Ticket open for more than 30 days (business check, not a data error)'
    FROM fact_tickets
    UNION ALL
    SELECT 'data_freshness', 'WARN', 'FACT_TICKETS',
           IFF(MAX(created_at) < DATEADD(day, -2, (SELECT as_of_ts FROM dataset_config)), 1, 0), 1,
           'Newest ticket is more than 2 days older than the as-of timestamp'
    FROM fact_tickets
  );

  RETURN 'run_id=' || rid;
END;
$$;

CALL run_dq_checks();

-- Latest run, worst problems first
CREATE OR REPLACE VIEW v_dq_latest_run AS
SELECT *
FROM dq_audit_log
QUALIFY run_ts = MAX(run_ts) OVER ();

SELECT check_name, severity, status, failed_rows, total_rows, failure_pct, details
FROM v_dq_latest_run
ORDER BY IFF(status = 'FAIL', 0, IFF(status = 'WARN', 1, 2)), failed_rows DESC;

-- The actual offending rows, so someone can investigate and fix them
CREATE OR REPLACE VIEW v_dq_bad_tickets AS
SELECT ticket_id, 'resolved_before_created' AS issue, created_at, resolved_at
FROM fact_tickets WHERE resolved_at < created_at
UNION ALL
SELECT ticket_id, 'first_response_before_created', created_at, first_response_at
FROM fact_tickets WHERE first_response_at < created_at
UNION ALL
SELECT ticket_id, 'missing_agent', created_at, NULL
FROM fact_tickets WHERE agent_id IS NULL;

SELECT issue, COUNT(*) AS tickets FROM v_dq_bad_tickets GROUP BY issue;

-- Expected result: resolved_before_created and missing_agent fail/warn (we planted them in Step 1);
-- everything else passes. Re-run CALL run_dq_checks(); any time and the audit log keeps history.

-- Optional: run the checks every morning (task is created suspended)
CREATE OR REPLACE TASK daily_dq_checks
  WAREHOUSE = SUPPORT_WH
  SCHEDULE  = 'USING CRON 0 5 * * * America/New_York'
AS
  CALL run_dq_checks();
-- ALTER TASK daily_dq_checks RESUME;


/* =====================================================================
   2. WEEKLY CLIENT HEALTH REPORT
      One row per client for the 7 days ending at the as-of date, with 30-day context,
      a 0-100 health score, and a plain-English line an account manager can paste into an email.

      Health score = 100 minus penalties (each capped so one metric can't dominate):
        SLA breaches (30d)         up to 30 pts   (0.6 pts per % of tickets breaching)
        CSAT below 4.2 (30d)       up to 25 pts   (20 pts per CSAT point below 4.2)
        Ticket volume growth (WoW) up to 20 pts   (0.2 pts per % growth)
        Open tickets older than 7d up to 15 pts   (3 pts per ticket)
      The weights and the 80/60 cutoffs are judgment calls. Look at the score distribution
      and calibrate them, then be ready to explain why you chose them.
   ===================================================================== */

CREATE OR REPLACE VIEW v_client_health_weekly AS
WITH cfg AS (
  SELECT as_of_ts FROM dataset_config
),
m AS (
  SELECT
    t.client_id, t.client_name, t.plan_tier, t.region, t.industry,
    COUNT_IF(t.created_at >  DATEADD(day,  -7, cfg.as_of_ts))                                   AS tickets_this_week,
    COUNT_IF(t.created_at <= DATEADD(day,  -7, cfg.as_of_ts)
         AND t.created_at >  DATEADD(day, -14, cfg.as_of_ts))                                   AS tickets_prior_week,
    COUNT_IF(t.created_at >  DATEADD(day,  -7, cfg.as_of_ts)
         AND t.priority IN ('P1','P2'))                                                          AS high_priority_this_week,
    COUNT_IF(t.created_at >  DATEADD(day, -30, cfg.as_of_ts))                                   AS tickets_30d,
    COUNT_IF(t.created_at >  DATEADD(day, -30, cfg.as_of_ts)
         AND (t.response_breached OR t.resolution_breached))                                     AS breached_tickets_30d,
    AVG(IFF(t.created_at > DATEADD(day, -30, cfg.as_of_ts), t.csat_score, NULL))                AS avg_csat_30d,
    100 * AVG(IFF(t.created_at > DATEADD(day, -30, cfg.as_of_ts)
                  AND t.resolved_at IS NOT NULL, t.is_reopened::INT, NULL))                      AS reopen_pct_30d,
    COUNT_IF(t.resolved_at IS NULL)                                                              AS open_tickets,
    COUNT_IF(t.resolved_at IS NULL
         AND t.created_at <= DATEADD(day, -7, cfg.as_of_ts))                                     AS open_over_7d
  FROM v_ticket_enriched t CROSS JOIN cfg
  GROUP BY t.client_id, t.client_name, t.plan_tier, t.region, t.industry
),
top_cat AS (
  SELECT t.client_id, t.category AS top_category_this_week
  FROM v_ticket_enriched t CROSS JOIN cfg
  WHERE t.created_at > DATEADD(day, -7, cfg.as_of_ts)
  GROUP BY t.client_id, t.category
  QUALIFY ROW_NUMBER() OVER (PARTITION BY t.client_id ORDER BY COUNT(*) DESC, t.category) = 1
),
calc AS (
  SELECT
    m.*,
    tc.top_category_this_week,
    ROUND(100 * (tickets_this_week - tickets_prior_week) / NULLIF(tickets_prior_week, 0), 1) AS wow_change_pct,
    ROUND(100 * breached_tickets_30d / NULLIF(tickets_30d, 0), 1)                             AS sla_breach_pct_30d
  FROM m LEFT JOIN top_cat tc ON tc.client_id = m.client_id
),
scored AS (
  SELECT
    calc.*,
    GREATEST(0, ROUND(
        100
      - LEAST(30, 0.6 * COALESCE(sla_breach_pct_30d, 0))
      - LEAST(25, 20  * GREATEST(0, 4.2 - COALESCE(avg_csat_30d, 4.2)))
      - LEAST(20, 0.2 * GREATEST(0, COALESCE(wow_change_pct, 0)))
      - LEAST(15, 3   * open_over_7d)
    ))::INT AS health_score
  FROM calc
)
SELECT
  scored.*,
  CASE WHEN health_score >= 80 THEN 'Healthy'
       WHEN health_score >= 60 THEN 'Watch'
       ELSE 'At risk' END AS health_status,
  client_name || ' (' || plan_tier || '): '
    || tickets_this_week || ' tickets this week'
    || IFF(wow_change_pct IS NULL, '', ' (' || IFF(wow_change_pct >= 0, '+', '') || wow_change_pct || '% vs prior week)')
    || '; ' || open_tickets || ' open, ' || open_over_7d || ' older than 7 days'
    || '; 30-day SLA breach rate ' || COALESCE(TO_VARCHAR(sla_breach_pct_30d), 'n/a') || '%'
    || '; CSAT ' || COALESCE(TO_VARCHAR(ROUND(avg_csat_30d, 2)), 'n/a')
    || IFF(top_category_this_week IS NULL, '', '; most common issue: ' || top_category_this_week)
    AS account_summary
FROM scored;

-- The report: weakest accounts first, only those with activity this week
SELECT client_name, plan_tier, region, health_score, health_status,
       tickets_this_week, wow_change_pct, open_over_7d, sla_breach_pct_30d,
       ROUND(avg_csat_30d, 2) AS avg_csat_30d, top_category_this_week, account_summary
FROM v_client_health_weekly
WHERE tickets_this_week > 0
ORDER BY health_score ASC, tickets_this_week DESC
LIMIT 25;

-- Distribution check: use this to calibrate the 80/60 cutoffs
SELECT health_status, COUNT(*) AS clients, ROUND(AVG(health_score), 1) AS avg_score
FROM v_client_health_weekly
GROUP BY health_status;

-- Weekly snapshots build history so you can chart health over time
CREATE TABLE IF NOT EXISTS client_health_history AS
SELECT (SELECT as_of_ts::DATE FROM dataset_config) AS snapshot_date, h.*
FROM v_client_health_weekly h
WHERE 1 = 0;

INSERT INTO client_health_history
SELECT (SELECT as_of_ts::DATE FROM dataset_config), h.*
FROM v_client_health_weekly h;


/* =====================================================================
   3. CORTEX AI ON TICKET TEXT
      New accounts can't use the legacy SNOWFLAKE.CORTEX.* functions, so this section
      uses the current AI functions instead:
        AI_SENTIMENT      returns an object whose overall sentiment is a LABEL:
                          positive / negative / neutral / mixed / unknown
        AI_CLASSIFY       returns {"labels": [...]}; single-label mode returns one label
        AI_SUMMARIZE_AGG  summarizes text across many rows
      AI_SENTIMENT returns a label, not a number. The view below maps labels to a simple
      score (+1 / 0 / -1) so you can still average and correlate. Treat that score as
      ordinal, not precise.
   ===================================================================== */

-- AI functions need the SNOWFLAKE.CORTEX_USER database role (granted to PUBLIC by default)
-- or the USE AI FUNCTIONS account privilege. If you get a privilege error, run as ACCOUNTADMIN:
-- GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE SYSADMIN;

-- 3a. Build a small, cheap sample: 1,000 random recent tickets + up to 1,000 currently open ones
CREATE OR REPLACE TABLE ticket_text_sample AS
SELECT ticket_id FROM (
  SELECT ticket_id
  FROM v_ticket_enriched
  WHERE created_at > DATEADD(day, -60, (SELECT as_of_ts FROM dataset_config))
  ORDER BY RANDOM()
  LIMIT 1000
)
UNION
SELECT ticket_id FROM (
  SELECT ticket_id
  FROM v_ticket_enriched
  WHERE resolved_at IS NULL
  ORDER BY created_at DESC
  LIMIT 1000
);

SELECT COUNT(*) AS sampled_tickets FROM ticket_text_sample;

-- Quick smoke test on one row before spending credits on the whole sample
SELECT
  description,
  AI_SENTIMENT(description)                                   AS raw_sentiment,
  AI_SENTIMENT(description):categories[0]:sentiment::STRING   AS overall_sentiment
FROM fact_tickets
LIMIT 1;

-- 3b. Score sentiment and auto-categorize (this is the step that uses AI credits).
--     AI_CLASSIFY works best with plain-word labels (no slashes or abbreviations),
--     so we classify with descriptive labels and map them back to our real categories.
CREATE OR REPLACE TABLE ticket_text_enrichment AS
SELECT
  s.ticket_id,
  AI_SENTIMENT(t.description):categories[0]:sentiment::STRING  AS sentiment_label,
  AI_CLASSIFY(
    t.subject,
    ['Login and Access', 'Billing', 'Bug or Defect', 'Performance',
     'Integration and API', 'How To Question', 'Feature Request', 'Reporting and Export']
  ):labels[0]::STRING                                          AS ai_label,
  CURRENT_TIMESTAMP()                                          AS enriched_at
FROM ticket_text_sample s
JOIN fact_tickets t ON t.ticket_id = s.ticket_id;

CREATE OR REPLACE TABLE ai_category_map AS
SELECT * FROM VALUES
  ('Login and Access',     'Login/Access'),
  ('Billing',              'Billing'),
  ('Bug or Defect',        'Bug/Defect'),
  ('Performance',          'Performance'),
  ('Integration and API',  'Integration/API'),
  ('How To Question',      'How-To'),
  ('Feature Request',      'Feature Request'),
  ('Reporting and Export', 'Reporting/Export')
AS t(ai_label, category);

-- Friendly view: sentiment label + numeric score, AI label mapped back to our categories
CREATE OR REPLACE VIEW v_ticket_text_scores AS
SELECT
  e.ticket_id,
  e.sentiment_label,
  CASE e.sentiment_label
    WHEN 'positive' THEN  1
    WHEN 'neutral'  THEN  0
    WHEN 'mixed'    THEN  0
    WHEN 'negative' THEN -1
  END                      AS sentiment_score,     -- 'unknown' stays NULL
  e.ai_label,
  m.category               AS ai_category,
  e.enriched_at
FROM ticket_text_enrichment e
LEFT JOIN ai_category_map m ON m.ai_label = e.ai_label;

-- 3c. Validate the AI against the labels we already know (always check before trusting it)
SELECT
  COUNT(*)                                                    AS tickets,
  ROUND(100 * AVG(IFF(v.ai_category = t.category, 1, 0)), 1)  AS category_accuracy_pct
FROM v_ticket_text_scores v
JOIN fact_tickets t ON t.ticket_id = v.ticket_id;

SELECT t.category AS actual_category, v.ai_category AS predicted_category, COUNT(*) AS tickets
FROM v_ticket_text_scores v
JOIN fact_tickets t ON t.ticket_id = v.ticket_id
WHERE v.ai_category IS DISTINCT FROM t.category
GROUP BY 1, 2
ORDER BY tickets DESC
LIMIT 15;

-- What sentiment labels did the model produce overall?
SELECT sentiment_label, COUNT(*) AS tickets,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (), 1) AS pct
FROM v_ticket_text_scores
GROUP BY sentiment_label
ORDER BY tickets DESC;

-- Does sentiment track the tone we wrote into the descriptions in Step 1?
SELECT
  CASE WHEN t.description LIKE 'URGENT%'      THEN 'urgent'
       WHEN t.description LIKE '%frustrated%' THEN 'frustrated'
       WHEN t.description LIKE 'Thanks%'      THEN 'happy'
       ELSE 'neutral' END                                  AS written_tone,
  COUNT(*)                                                 AS tickets,
  COUNT_IF(v.sentiment_label = 'negative')                 AS negative,
  COUNT_IF(v.sentiment_label IN ('neutral','mixed'))       AS neutral_or_mixed,
  COUNT_IF(v.sentiment_label = 'positive')                 AS positive,
  ROUND(AVG(v.sentiment_score), 2)                         AS avg_score
FROM v_ticket_text_scores v
JOIN fact_tickets t ON t.ticket_id = v.ticket_id
GROUP BY written_tone
ORDER BY avg_score;

-- Does text sentiment relate to the survey score? (only tickets that have a CSAT)
SELECT ROUND(CORR(v.sentiment_score, t.csat_score), 3) AS sentiment_csat_correlation,
       COUNT(*) AS tickets_with_csat
FROM v_ticket_text_scores v
JOIN fact_tickets t ON t.ticket_id = v.ticket_id
WHERE t.csat_score IS NOT NULL AND v.sentiment_score IS NOT NULL;
-- Because the descriptions and CSAT were generated independently, expect a correlation near zero.
-- That's a useful talking point: real data would differ, and you should always test an assumption.

-- 3d. Action list: open tickets where the customer sounds unhappy
CREATE OR REPLACE VIEW v_negative_open_tickets AS
SELECT
  t.ticket_id, t.client_name, t.plan_tier, t.priority, t.category, t.status,
  t.created_at,
  DATEDIFF('hour', t.created_at, (SELECT as_of_ts FROM dataset_config)) AS age_hours,
  v.sentiment_label,
  t.description
FROM v_ticket_text_scores v
JOIN v_ticket_enriched t ON t.ticket_id = v.ticket_id
WHERE t.resolved_at IS NULL
  AND v.sentiment_label = 'negative';

SELECT * FROM v_negative_open_tickets
ORDER BY priority, age_hours DESC
LIMIT 25;

-- 3e. AI-written summaries for the five riskiest clients (last 30 days of ticket text)
CREATE OR REPLACE TABLE client_ai_summary AS
WITH top_clients AS (
  SELECT client_id
  FROM v_at_risk_clients
  ORDER BY risk_flags DESC, tickets_last_30d DESC
  LIMIT 5
)
SELECT
  t.client_id,
  t.client_name,
  COUNT(*)                         AS tickets_summarized,
  AI_SUMMARIZE_AGG(t.description)  AS ai_summary
FROM v_ticket_enriched t
JOIN top_clients tc ON tc.client_id = t.client_id
WHERE t.created_at > DATEADD(day, -30, (SELECT as_of_ts FROM dataset_config))
GROUP BY t.client_id, t.client_name;

SELECT client_name, tickets_summarized, ai_summary FROM client_ai_summary;


/* =====================================================================
   4. FINDINGS QUERIES FOR YOUR README
      Turn these results into plain-English insights ("Basic-tier clients breach the
      first-response SLA X times as often as Enterprise on weekends"). Quote the real
      numbers from your own run.
   ===================================================================== */

-- 4a. Which tier and priority breach most on weekends vs weekdays?
SELECT plan_tier, priority,
       IFF(DAYOFWEEKISO(created_date) >= 6, 'Weekend', 'Weekday') AS day_type,
       COUNT(*) AS tickets,
       ROUND(100 * AVG(response_breached::INT), 1) AS response_breach_pct
FROM v_ticket_enriched
GROUP BY plan_tier, priority, day_type
ORDER BY priority, plan_tier, day_type;

-- 4b. How much does an SLA breach cost in CSAT?
SELECT IFF(response_breached OR resolution_breached, 'Breached an SLA', 'Met SLAs') AS sla_outcome,
       COUNT(csat_score)           AS survey_responses,
       ROUND(AVG(csat_score), 2)   AS avg_csat
FROM v_ticket_enriched
WHERE csat_score IS NOT NULL
GROUP BY sla_outcome;

-- 4c. Which categories get reopened the most?
SELECT category,
       COUNT(*)                                  AS resolved_tickets,
       ROUND(100 * AVG(is_reopened::INT), 1)     AS reopen_rate_pct
FROM v_ticket_enriched
WHERE resolved_at IS NOT NULL
GROUP BY category
ORDER BY reopen_rate_pct DESC;

-- 4d. How concentrated is ticket volume? (top 10% of clients)
SELECT MAX(cumulative_pct_of_tickets) AS pct_of_tickets_from_top_10pct_clients
FROM v_client_ticket_volume
WHERE volume_rank <= (SELECT ROUND(COUNT(*) * 0.10) FROM dim_clients);
