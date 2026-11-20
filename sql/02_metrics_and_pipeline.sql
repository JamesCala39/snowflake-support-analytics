/* =====================================================================
   Client Support Analytics, Step 2: model, metrics, pipeline, security
   Prereq: 01_synthetic_data.sql has been run successfully.
   Run all in a worksheet

   Sections
     0. Setup + dataset "as of" config
     1. Star schema (keys + date key)
     2. Metric views (window functions throughout)
     3. Stream + Task pipeline (daily summary table)
     4. Dynamic Table (open tickets by age)
     5. Role-based access
     6. Optional: stage + COPY INTO round trip
   ===================================================================== */

-- ---------------------------------------------------------------------
-- 0. Setup
-- ---------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE SYSADMIN;   -- needed to run/resume tasks

USE ROLE SYSADMIN;
USE WAREHOUSE SUPPORT_WH;
USE SCHEMA SUPPORT_ANALYTICS.CORE;

-- The dataset is frozen at this timestamp. In production use CURRENT_TIMESTAMP().
CREATE OR REPLACE TABLE dataset_config AS
SELECT '2026-10-31 23:59:59'::TIMESTAMP_NTZ AS as_of_ts;


-- ---------------------------------------------------------------------
-- 1. Star schema:
-- ---------------------------------------------------------------------
ALTER TABLE dim_clients    ADD PRIMARY KEY (client_id);
ALTER TABLE dim_agents     ADD PRIMARY KEY (agent_id);
ALTER TABLE dim_sla_policy ADD PRIMARY KEY (priority);
ALTER TABLE dim_date       ADD PRIMARY KEY (date_key);
ALTER TABLE fact_tickets   ADD PRIMARY KEY (ticket_id);

-- Add a proper date key to the fact table so it joins to dim_date
ALTER TABLE fact_tickets ADD COLUMN created_date_key NUMBER;
UPDATE fact_tickets SET created_date_key = TO_NUMBER(TO_CHAR(created_at, 'YYYYMMDD'));

ALTER TABLE fact_tickets ADD FOREIGN KEY (client_id)        REFERENCES dim_clients(client_id);
ALTER TABLE fact_tickets ADD FOREIGN KEY (agent_id)         REFERENCES dim_agents(agent_id);
ALTER TABLE fact_tickets ADD FOREIGN KEY (priority)         REFERENCES dim_sla_policy(priority);
ALTER TABLE fact_tickets ADD FOREIGN KEY (created_date_key) REFERENCES dim_date(date_key);


-- ---------------------------------------------------------------------
-- 2. Metric views
-- ---------------------------------------------------------------------

-- 2a. Base view: one row per valid ticket, joined to every dimension,
--     with durations and SLA breach flags computed once.
CREATE OR REPLACE VIEW v_ticket_enriched AS
WITH j AS (
  SELECT
    f.ticket_id, f.client_id, f.agent_id,
    f.created_at, f.first_response_at, f.resolved_at,
    f.priority, f.category, f.channel, f.status,
    f.subject, f.description, f.csat_score, f.is_reopened,
    c.client_name, c.plan_tier, c.industry, c.region,
    a.agent_name, a.team,
    p.first_response_target_min AS fr_target_min,
    p.resolution_target_min     AS res_target_min,
    DATEDIFF('minute', f.created_at, f.first_response_at) AS first_response_min,
    DATEDIFF('minute', f.created_at, f.resolved_at)       AS resolution_min
  FROM fact_tickets f
  JOIN dim_clients    c ON c.client_id = f.client_id
  LEFT JOIN dim_agents a ON a.agent_id = f.agent_id
  JOIN dim_sla_policy p ON p.priority  = f.priority
  WHERE NOT COALESCE(f.resolved_at < f.created_at, FALSE)     -- drop impossible timelines
)
SELECT
  j.*,
  first_response_min > fr_target_min        AS response_breached,    -- NULL until a response exists
  resolution_min     > res_target_min       AS resolution_breached,  -- NULL until resolved
  created_at::DATE                          AS created_date,
  DATE_TRUNC('month', created_at)::DATE     AS created_month
FROM j;


-- 2b. SLA performance by priority (avg, median, p90, breach %)
CREATE OR REPLACE VIEW v_sla_by_priority AS
SELECT
  priority,
  COUNT(*)                                                          AS tickets,
  ROUND(AVG(first_response_min), 1)                                 AS avg_first_response_min,
  ROUND(MEDIAN(first_response_min), 1)                              AS median_first_response_min,
  ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY first_response_min), 1) AS p90_first_response_min,
  ROUND(100 * AVG(response_breached::INT), 1)                       AS response_breach_pct,
  ROUND(MEDIAN(resolution_min) / 60, 1)                             AS median_resolution_hours,
  ROUND(100 * AVG(resolution_breached::INT), 1)                     AS resolution_breach_pct
FROM v_ticket_enriched
GROUP BY priority;


-- 2c. Monthly SLA/CSAT by tier and priority (feeds Streamlit filters later)
CREATE OR REPLACE VIEW v_sla_monthly AS
SELECT
  created_month, plan_tier, priority,
  COUNT(*)                                       AS tickets,
  ROUND(100 * AVG(response_breached::INT), 1)    AS response_breach_pct,
  ROUND(100 * AVG(resolution_breached::INT), 1)  AS resolution_breach_pct,
  ROUND(AVG(csat_score), 2)                      AS avg_csat
FROM v_ticket_enriched
GROUP BY created_month, plan_tier, priority;


-- 2d. Daily volume with rolling 7-day average and week-over-week change
CREATE OR REPLACE VIEW v_daily_volume_trend AS
WITH days AS (                                    -- spine so zero-ticket days still appear
  SELECT d.date_day
  FROM dim_date d CROSS JOIN dataset_config c
  WHERE d.date_day BETWEEN '2025-11-01' AND c.as_of_ts::DATE
),
daily AS (
  SELECT
    days.date_day,
    COALESCE(COUNT(t.ticket_id), 0)                                AS tickets,
    COALESCE(COUNT_IF(t.priority IN ('P1','P2')), 0)               AS high_priority_tickets
  FROM days
  LEFT JOIN v_ticket_enriched t ON t.created_date = days.date_day
  GROUP BY days.date_day
),
roll AS (
  SELECT
    daily.*,
    ROUND(AVG(tickets) OVER (ORDER BY date_day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 1) AS tickets_7d_avg
  FROM daily
)
SELECT
  roll.*,
  ROUND(100 * (tickets_7d_avg - LAG(tickets_7d_avg, 7) OVER (ORDER BY date_day))
        / NULLIF(LAG(tickets_7d_avg, 7) OVER (ORDER BY date_day), 0), 1) AS wow_change_pct
FROM roll;


-- 2e. CSAT trend with month-over-month change and 3-month rolling average
--     (cohorted by ticket creation month, not survey date)
CREATE OR REPLACE VIEW v_csat_trend AS
WITH m AS (
  SELECT created_month,
         COUNT(*)           AS resolved_tickets,
         COUNT(csat_score)  AS survey_responses,
         AVG(csat_score)    AS avg_csat
  FROM v_ticket_enriched
  WHERE resolved_at IS NOT NULL
  GROUP BY created_month
)
SELECT
  created_month, resolved_tickets, survey_responses,
  ROUND(100 * survey_responses / resolved_tickets, 1)                          AS response_rate_pct,
  ROUND(avg_csat, 2)                                                           AS avg_csat,
  ROUND(avg_csat - LAG(avg_csat) OVER (ORDER BY created_month), 2)             AS mom_change,
  ROUND(AVG(avg_csat) OVER (ORDER BY created_month
                            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)      AS rolling_3m_csat
FROM m;


-- 2f. Reopen rate by month and category
CREATE OR REPLACE VIEW v_reopen_rate AS
SELECT
  created_month, category,
  COUNT(*)                                  AS resolved_tickets,
  COUNT_IF(is_reopened)                     AS reopened_tickets,
  ROUND(100 * COUNT_IF(is_reopened) / COUNT(*), 1) AS reopen_rate_pct
FROM v_ticket_enriched
WHERE resolved_at IS NOT NULL
GROUP BY created_month, category;


-- 2g. Tickets per client with ranking and a Pareto curve
--     (what share of all tickets comes from the top N clients?)
CREATE OR REPLACE VIEW v_client_ticket_volume AS
WITH per AS (
  SELECT client_id, client_name, plan_tier, industry,
         COUNT(*)                                  AS total_tickets,
         COUNT_IF(priority IN ('P1','P2'))         AS high_priority_tickets,
         ROUND(AVG(csat_score), 2)                 AS avg_csat
  FROM v_ticket_enriched
  GROUP BY client_id, client_name, plan_tier, industry
)
SELECT
  per.*,
  RANK() OVER (ORDER BY total_tickets DESC)        AS volume_rank,
  ROUND(100 * SUM(total_tickets) OVER (ORDER BY total_tickets DESC, client_id
                                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        / SUM(total_tickets) OVER (), 1)           AS cumulative_pct_of_tickets
FROM per;


-- 2h. Agent leaderboard with rank inside each team
--     Caveat: Escalations/Tier 2 get harder (P1/P2) work, so compare within a team,
--     and ideally within a priority mix, before judging anyone.
CREATE OR REPLACE VIEW v_agent_leaderboard AS
WITH a AS (
  SELECT
    agent_id, agent_name, team,
    COUNT(*)                                                    AS tickets_handled,
    COUNT_IF(resolved_at IS NOT NULL)                           AS tickets_resolved,
    ROUND(MEDIAN(resolution_min) / 60, 1)                       AS median_resolution_hours,
    ROUND(100 * AVG(response_breached::INT), 1)                 AS response_breach_pct,
    ROUND(100 * AVG(resolution_breached::INT), 1)               AS resolution_breach_pct,
    ROUND(AVG(csat_score), 2)                                   AS avg_csat,
    ROUND(100 * AVG(IFF(resolved_at IS NOT NULL, is_reopened::INT, NULL)), 1) AS reopen_pct
  FROM v_ticket_enriched
  WHERE agent_id IS NOT NULL
  GROUP BY agent_id, agent_name, team
)
SELECT
  a.*,
  RANK() OVER (PARTITION BY team ORDER BY avg_csat DESC)               AS csat_rank_in_team,
  RANK() OVER (PARTITION BY team ORDER BY resolution_breach_pct ASC)   AS sla_rank_in_team
FROM a;


-- 2i. At-risk clients: last 30 days vs the 30 days before (relative to as_of_ts)
--     Thresholds are starting points. Tune them and justify the choice.
CREATE OR REPLACE VIEW v_at_risk_clients AS
WITH w AS (
  SELECT
    t.client_id, t.client_name, t.plan_tier,
    COUNT_IF(t.created_at >  DATEADD(day, -30, c.as_of_ts)) AS tickets_last_30d,
    COUNT_IF(t.created_at <= DATEADD(day, -30, c.as_of_ts)) AS tickets_prior_30d,
    AVG(IFF(t.created_at >  DATEADD(day, -30, c.as_of_ts), t.csat_score, NULL)) AS csat_last_30d,
    AVG(IFF(t.created_at <= DATEADD(day, -30, c.as_of_ts), t.csat_score, NULL)) AS csat_prior_30d,
    COUNT_IF(t.created_at > DATEADD(day, -30, c.as_of_ts)
             AND (t.response_breached OR t.resolution_breached)) AS breaches_last_30d
  FROM v_ticket_enriched t CROSS JOIN dataset_config c
  WHERE t.created_at > DATEADD(day, -60, c.as_of_ts)
  GROUP BY t.client_id, t.client_name, t.plan_tier
),
f AS (
  SELECT
    w.*,
    ROUND(100 * (tickets_last_30d - tickets_prior_30d) / NULLIF(tickets_prior_30d, 0), 1) AS volume_change_pct,
    ROUND(csat_last_30d - csat_prior_30d, 2)                                              AS csat_change,
    ROUND(100 * breaches_last_30d / NULLIF(tickets_last_30d, 0), 1)                       AS breach_rate_pct_last_30d
  FROM w
),
g AS (
  SELECT
    f.*,
    IFF(tickets_last_30d >= 10 AND volume_change_pct >= 50, 1, 0)       AS flag_rising_volume,
    IFF(csat_change <= -0.5, 1, 0)                                      AS flag_falling_csat,
    IFF(tickets_last_30d >= 10 AND breach_rate_pct_last_30d >= 35, 1, 0) AS flag_sla_breaches
  FROM f
)
SELECT
  g.*,
  flag_rising_volume + flag_falling_csat + flag_sla_breaches AS risk_flags
FROM g;


-- Quick look at what the views return
SELECT * FROM v_sla_by_priority ORDER BY priority;
SELECT * FROM v_csat_trend ORDER BY created_month;
SELECT * FROM v_daily_volume_trend ORDER BY date_day DESC LIMIT 14;
SELECT * FROM v_client_ticket_volume ORDER BY volume_rank LIMIT 10;
SELECT * FROM v_at_risk_clients WHERE risk_flags >= 2 ORDER BY risk_flags DESC, tickets_last_30d DESC LIMIT 20;


-- ---------------------------------------------------------------------
-- 3. Pipeline: Stream + Task keep a daily summary table current
-- ---------------------------------------------------------------------

-- Calculation view: one row per day and priority
CREATE OR REPLACE VIEW v_daily_summary_calc AS
SELECT
  created_date                          AS summary_date,
  priority,
  COUNT(*)                              AS tickets_created,
  COUNT(first_response_at)              AS tickets_responded,
  ROUND(AVG(first_response_min), 1)     AS avg_first_response_min,
  COUNT_IF(response_breached)           AS response_breaches
FROM v_ticket_enriched
GROUP BY created_date, priority;

CREATE OR REPLACE TABLE daily_ticket_summary (
  summary_date           DATE,
  priority               VARCHAR,
  tickets_created        NUMBER,
  tickets_responded      NUMBER,
  avg_first_response_min FLOAT,
  response_breaches      NUMBER,
  updated_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Initial backfill
INSERT INTO daily_ticket_summary
  (summary_date, priority, tickets_created, tickets_responded, avg_first_response_min, response_breaches)
SELECT * FROM v_daily_summary_calc;

-- Create the stream AFTER the backfill so it only tracks new changes
CREATE OR REPLACE STREAM fact_tickets_stream ON TABLE fact_tickets;

-- The task only does work when the stream has changes, and only recomputes affected days
CREATE OR REPLACE TASK refresh_daily_ticket_summary
  WAREHOUSE = SUPPORT_WH
  SCHEDULE  = 'USING CRON 0 6 * * * America/New_York'
  WHEN SYSTEM$STREAM_HAS_DATA('FACT_TICKETS_STREAM')
AS
MERGE INTO daily_ticket_summary t
USING (
  SELECT *
  FROM v_daily_summary_calc
  WHERE summary_date IN (SELECT DISTINCT created_at::DATE FROM fact_tickets_stream)
) s
ON t.summary_date = s.summary_date AND t.priority = s.priority
WHEN MATCHED THEN UPDATE SET
  t.tickets_created        = s.tickets_created,
  t.tickets_responded      = s.tickets_responded,
  t.avg_first_response_min = s.avg_first_response_min,
  t.response_breaches      = s.response_breaches,
  t.updated_at             = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
  (summary_date, priority, tickets_created, tickets_responded, avg_first_response_min, response_breaches)
  VALUES (s.summary_date, s.priority, s.tickets_created, s.tickets_responded,
          s.avg_first_response_min, s.response_breaches);

-- Test it: note the "before" numbers, add 3 tickets, trigger the task, compare.
SELECT * FROM daily_ticket_summary WHERE summary_date = '2026-10-31' AND priority = 'P2';

INSERT INTO fact_tickets
  (ticket_id, client_id, agent_id, created_at, priority, category, channel, status,
   subject, description, created_date_key)
VALUES
  (150001, 1, 30, '2026-10-31 10:00:00', 'P2', 'Bug/Defect', 'Email', 'Open',
   'Test ticket A', 'Pipeline test ticket A', 20261031),
  (150002, 2, 31, '2026-10-31 10:05:00', 'P2', 'Billing',    'Chat',  'Open',
   'Test ticket B', 'Pipeline test ticket B', 20261031),
  (150003, 3, 32, '2026-10-31 10:10:00', 'P2', 'How-To',     'Phone', 'Open',
   'Test ticket C', 'Pipeline test ticket C', 20261031);

SELECT SYSTEM$STREAM_HAS_DATA('FACT_TICKETS_STREAM') AS stream_has_data;   -- TRUE

EXECUTE TASK refresh_daily_ticket_summary;      -- manual run (task stays suspended)

-- Give it a few seconds, then re-run:
SELECT * FROM daily_ticket_summary WHERE summary_date = '2026-10-31' AND priority = 'P2';
SELECT SYSTEM$STREAM_HAS_DATA('FACT_TICKETS_STREAM') AS stream_has_data;   -- FALSE now

-- Remove the test tickets (this also creates stream records; the next run will resync that day)
DELETE FROM fact_tickets WHERE ticket_id BETWEEN 150001 AND 150003;
EXECUTE TASK refresh_daily_ticket_summary;

-- Tasks are created SUSPENDED. To run on the schedule, uncomment, and suspend again when done:
-- ALTER TASK refresh_daily_ticket_summary RESUME;
-- ALTER TASK refresh_daily_ticket_summary SUSPEND;


-- ---------------------------------------------------------------------
-- 4. Dynamic Table: always-current open ticket backlog by age bucket
--    Reads base tables + config (not CURRENT_TIMESTAMP) so it stays deterministic.
-- ---------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE dt_open_tickets_by_age
  TARGET_LAG = '1 hour'
  WAREHOUSE  = SUPPORT_WH
AS
WITH open_t AS (
  SELECT
    f.priority,
    c.plan_tier,
    DATEDIFF('hour', f.created_at, cfg.as_of_ts) AS age_hours
  FROM fact_tickets f
  JOIN dim_clients c ON c.client_id = f.client_id
  CROSS JOIN dataset_config cfg
  WHERE f.resolved_at IS NULL
)
SELECT
  CASE WHEN age_hours <   4 THEN '0-4 hours'
       WHEN age_hours <  24 THEN '4-24 hours'
       WHEN age_hours <  72 THEN '1-3 days'
       WHEN age_hours < 168 THEN '3-7 days'
       WHEN age_hours < 720 THEN '7-30 days'
       ELSE '30+ days' END                   AS age_bucket,
  CASE WHEN age_hours <   4 THEN 1
       WHEN age_hours <  24 THEN 2
       WHEN age_hours <  72 THEN 3
       WHEN age_hours < 168 THEN 4
       WHEN age_hours < 720 THEN 5
       ELSE 6 END                            AS bucket_order,
  priority,
  plan_tier,
  COUNT(*)                                   AS open_tickets,
  ROUND(AVG(age_hours), 1)                   AS avg_age_hours
FROM open_t
GROUP BY 1, 2, 3, 4;

SELECT age_bucket, SUM(open_tickets) AS open_tickets
FROM dt_open_tickets_by_age
GROUP BY age_bucket, bucket_order
ORDER BY bucket_order;

-- Dynamic tables refresh on a timer and use warehouse credits.
-- Suspend it when not working on the project:
-- ALTER DYNAMIC TABLE dt_open_tickets_by_age SUSPEND;


-- ---------------------------------------------------------------------
-- 5. Role-based access + masking
-- ---------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS SUPPORT_ANALYST;

GRANT USAGE ON WAREHOUSE SUPPORT_WH                TO ROLE SUPPORT_ANALYST;
GRANT USAGE ON DATABASE  SUPPORT_ANALYTICS         TO ROLE SUPPORT_ANALYST;
GRANT USAGE ON SCHEMA    SUPPORT_ANALYTICS.CORE    TO ROLE SUPPORT_ANALYST;

GRANT SELECT ON ALL TABLES          IN SCHEMA SUPPORT_ANALYTICS.CORE TO ROLE SUPPORT_ANALYST;
GRANT SELECT ON ALL VIEWS           IN SCHEMA SUPPORT_ANALYTICS.CORE TO ROLE SUPPORT_ANALYST;
GRANT SELECT ON ALL DYNAMIC TABLES  IN SCHEMA SUPPORT_ANALYTICS.CORE TO ROLE SUPPORT_ANALYST;
GRANT SELECT ON FUTURE TABLES       IN SCHEMA SUPPORT_ANALYTICS.CORE TO ROLE SUPPORT_ANALYST;
GRANT SELECT ON FUTURE VIEWS        IN SCHEMA SUPPORT_ANALYTICS.CORE TO ROLE SUPPORT_ANALYST;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN SCHEMA SUPPORT_ANALYTICS.CORE TO ROLE SUPPORT_ANALYST;

-- Let your own user switch to the analyst role so you can test it
SET me = '"' || CURRENT_USER() || '"';
GRANT ROLE SUPPORT_ANALYST TO USER IDENTIFIER($me);

/* Masking policies (REQUIRES ENTERPRISE EDITION)
USE ROLE SYSADMIN;

CREATE OR REPLACE MASKING POLICY mask_contact_email AS (val STRING) RETURNS STRING ->
  CASE WHEN IS_ROLE_IN_SESSION('SYSADMIN') OR IS_ROLE_IN_SESSION('ACCOUNTADMIN') THEN val
       ELSE REGEXP_REPLACE(val, '.+@', '*****@') END;

CREATE OR REPLACE MASKING POLICY mask_contact_phone AS (val STRING) RETURNS STRING ->
  CASE WHEN IS_ROLE_IN_SESSION('SYSADMIN') OR IS_ROLE_IN_SESSION('ACCOUNTADMIN') THEN val
       ELSE '***-***-' || RIGHT(val, 4) END;

ALTER TABLE dim_clients MODIFY COLUMN contact_email SET MASKING POLICY mask_contact_email;
ALTER TABLE dim_clients MODIFY COLUMN contact_phone SET MASKING POLICY mask_contact_phone;

USE ROLE SUPPORT_ANALYST;
USE WAREHOUSE SUPPORT_WH;
SELECT client_id, client_name, contact_email, contact_phone FROM SUPPORT_ANALYTICS.CORE.dim_clients LIMIT 5;
SELECT * FROM SUPPORT_ANALYTICS.CORE.v_sla_by_priority ORDER BY priority; 

USE ROLE SYSADMIN;
SELECT client_id, client_name, contact_email, contact_phone FROM dim_clients LIMIT 5;
*/

-- ---------------------------------------------------------------------
-- 6. Optional: stage + COPY INTO round trip
--    The data was generated in SQL, so this unloads it to an internal stage
--    and loads it back. It's the same pattern you'd use for real CSV files.
-- ---------------------------------------------------------------------
USE ROLE SYSADMIN;
USE SCHEMA SUPPORT_ANALYTICS.CORE;

CREATE OR REPLACE FILE FORMAT ff_csv
  TYPE = CSV
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  SKIP_HEADER = 1
  NULL_IF = ('NULL')
  COMPRESSION = GZIP;

CREATE OR REPLACE STAGE support_stage FILE_FORMAT = ff_csv;

COPY INTO @support_stage/tickets/
FROM fact_tickets
FILE_FORMAT = (FORMAT_NAME = 'ff_csv')
HEADER = TRUE
OVERWRITE = TRUE;

LIST @support_stage/tickets/;

CREATE OR REPLACE TABLE fact_tickets_reload LIKE fact_tickets;

COPY INTO fact_tickets_reload
FROM @support_stage/tickets/
FILE_FORMAT = (FORMAT_NAME = 'ff_csv')
ON_ERROR = 'ABORT_STATEMENT';

-- Reconcile: both should be 0 differences
SELECT (SELECT COUNT(*) FROM fact_tickets) - (SELECT COUNT(*) FROM fact_tickets_reload) AS row_diff;
SELECT COUNT(*) AS rows_only_in_original
FROM (SELECT * FROM fact_tickets EXCEPT SELECT * FROM fact_tickets_reload);

-- Cleanup when satisfied
-- DROP TABLE fact_tickets_reload;
