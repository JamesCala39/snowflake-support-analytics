/* =====================================================================
   Client Support Analytics: synthetic data generation (Snowflake)
   Creates: DIM_SLA_POLICY, DIM_AGENTS, DIM_CLIENTS, DIM_DATE, FACT_TICKETS
   Volume : 500 clients, 40 agents, 150,000 tickets (Nov 2025 - Oct 2026)
   Cost   : XS warehouse, runs in well under a minute
   ===================================================================== */

-- ---------------------------------------------------------------------
-- 0. Setup
-- ---------------------------------------------------------------------
USE ROLE SYSADMIN; -- Create warehouse and database

CREATE WAREHOUSE IF NOT EXISTS SUPPORT_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND   = 60
  AUTO_RESUME    = TRUE
  INITIALLY_SUSPENDED = TRUE;

USE WAREHOUSE SUPPORT_WH;
CREATE DATABASE IF NOT EXISTS SUPPORT_ANALYTICS;
CREATE SCHEMA   IF NOT EXISTS SUPPORT_ANALYTICS.CORE;
USE SCHEMA SUPPORT_ANALYTICS.CORE;

-- "Today" for the dataset. Tickets that would finish after this stay open.
SET as_of_ts = '2026-10-31 23:59:59'::TIMESTAMP_NTZ;


-- ---------------------------------------------------------------------
-- 1. SLA policy (targets in minutes)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE dim_sla_policy AS
SELECT * FROM VALUES
  ('P1',  15,  240),     -- 15 min response, 4 h resolution
  ('P2',  60,  480),     -- 1 h response, 8 h resolution
  ('P3', 240, 2880),     -- 4 h response, 2 days resolution
  ('P4', 480, 7200)      -- 8 h response, 5 days resolution
AS t(priority, first_response_target_min, resolution_target_min);


-- ---------------------------------------------------------------------
-- 2. Agents (40): 24 Tier 1, 12 Tier 2, 4 Escalations
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE dim_agents AS
WITH ids AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS agent_id
  FROM TABLE(GENERATOR(ROWCOUNT => 40))
)
SELECT
  agent_id,
  GET(ARRAY_CONSTRUCT('Avery','Blake','Casey','Dana','Eli','Finn','Gray','Harper','Indy','Jordan',
                      'Kai','Logan','Morgan','Noor','Owen','Parker','Quinn','Riley','Sam','Taylor'),
      MOD(agent_id, 20))::STRING
    || ' ' || CHR(65 + MOD(agent_id * 7, 26)) || '.'              AS agent_name,
  CASE WHEN agent_id <= 24 THEN 'Tier 1'
       WHEN agent_id <= 36 THEN 'Tier 2'
       ELSE 'Escalations' END                                      AS team,
  DATEADD(day, -MOD(agent_id * 97, 2800) - 60, DATE '2026-10-31')  AS hire_date
FROM ids;


-- ---------------------------------------------------------------------
-- 3. Clients (500)
--    Random draws are staged into a temp table first so each RANDOM()
--    is evaluated exactly once per row.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE tmp_client_seed AS
SELECT
  SEQ4() + 1                              AS client_id,
  UNIFORM(0, 19, RANDOM())                AS u_prefix,
  UNIFORM(0, 9,  RANDOM())                AS u_suffix,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_tier,
  UNIFORM(0, 5,  RANDOM())                AS u_industry,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_region,
  UNIFORM(0, 729, RANDOM())               AS u_signup
FROM TABLE(GENERATOR(ROWCOUNT => 500));

CREATE OR REPLACE TABLE dim_clients AS
SELECT
  client_id,
  GET(ARRAY_CONSTRUCT('Apex','Northwind','Bluepeak','Cobalt','Evergreen','Harbor','Ironwood',
                      'Juniper','Keystone','Lumen','Meridian','Nimbus','Orchid','Pinnacle',
                      'Quartz','Redwood','Summit','Trident','Union','Vertex'), u_prefix)::STRING
    || ' ' ||
  GET(ARRAY_CONSTRUCT('Logistics','Health','Capital','Retail','Systems',
                      'Foods','Energy','Media','Labs','Group'), u_suffix)::STRING
                                                          AS client_name,
  CASE WHEN u_tier < 0.50 THEN 'Basic'
       WHEN u_tier < 0.85 THEN 'Pro'
       ELSE 'Enterprise' END                              AS plan_tier,
  GET(ARRAY_CONSTRUCT('Healthcare','Finance','Retail','Logistics','Technology','Education'),
      u_industry)::STRING                                 AS industry,
  CASE WHEN u_region < 0.50 THEN 'North America'
       WHEN u_region < 0.75 THEN 'EMEA'
       WHEN u_region < 0.90 THEN 'APAC'
       ELSE 'LATAM' END                                   AS region,
  DATEADD(day, -u_signup, DATE '2025-11-01')              AS signup_date,
  -- Fake PII on purpose for masking policies
  'Contact ' || client_id                                 AS contact_name,
  'support.contact' || client_id || '@client' || client_id || '.example.com' AS contact_email,
  '+1-555-' || LPAD(client_id::STRING, 4, '0')            AS contact_phone
FROM tmp_client_seed;


-- ---------------------------------------------------------------------
-- 4. Date dimension (Jan 2025 - Dec 2026)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE dim_date AS
WITH d AS (
  SELECT DATEADD(day, n, DATE '2025-01-01') AS date_day
  FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS n
        FROM TABLE(GENERATOR(ROWCOUNT => 730)))
)
SELECT
  TO_NUMBER(TO_CHAR(date_day, 'YYYYMMDD'))  AS date_key,
  date_day,
  DAYNAME(date_day)                         AS day_name,
  DAYOFWEEKISO(date_day) >= 6               AS is_weekend,
  DATE_TRUNC('week',    date_day)           AS week_start,
  DATE_TRUNC('month',   date_day)           AS month_start,
  QUARTER(date_day)                         AS quarter,
  YEAR(date_day)                            AS year
FROM d;


-- ---------------------------------------------------------------------
-- 5. Ticket random draws (150,000 rows)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMP TABLE tmp_ticket_seed AS
SELECT
  SEQ4() + 1                              AS ticket_id,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_client,
  UNIFORM(0, 360, RANDOM())               AS u_day,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_wkshift,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_hourmix,
  UNIFORM(8, 17, RANDOM())                AS u_hour_biz,
  UNIFORM(0, 23, RANDOM())                AS u_hour_any,
  UNIFORM(0, 59, RANDOM())                AS u_min,
  UNIFORM(0, 59, RANDOM())                AS u_sec,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_pri,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_cat,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_chan,
  UNIFORM(0, 2, RANDOM())                 AS u_text,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_tone,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_resp,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_res,
  UNIFORM(25, 40, RANDOM())               AS u_agent_hi,   -- Tier 2 / Escalations
  UNIFORM(1, 36, RANDOM())                AS u_agent_lo,   -- Tier 1 / Tier 2
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_noagent,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_backlog,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_status,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_csat_resp,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_csat_noise,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_reopen,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())   AS u_dq
FROM TABLE(GENERATOR(ROWCOUNT => 150000));


-- ---------------------------------------------------------------------
-- 6. Fact table. Everything below is deterministic given the seed table.
--
--    Built-in "stories":
--      * A handful of low-ID clients generate far more tickets (skewed)
--      * Weekend tickets are slower, so SLA breaches spike on weekends
--      * Basic tier is slowest, Enterprise fastest
--      * CSAT drops when SLAs are breached
--      * Most weekend volume is shifted to Mon/Tue (lower weekend volume)
--
--    Intentional dirty data:
--      * ~0.2% of resolved tickets have resolved_at BEFORE created_at
--      * ~0.5% of tickets have no assigned agent
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE fact_tickets AS
WITH t0 AS (
  SELECT s.*,
         1 + FLOOR(500 * POW(u_client, 1.8))::NUMBER(10,0)       AS client_id,
         DATEADD(day, u_day, DATE '2025-11-01')          AS d0
  FROM tmp_ticket_seed s
),
t1 AS (
  SELECT t0.*,
         IFF(DAYOFWEEKISO(d0) >= 6 AND u_wkshift < 0.65, DATEADD(day, 2, d0), d0) AS d1,
         IFF(u_hourmix < 0.80, u_hour_biz, u_hour_any)   AS hr,
         CASE WHEN u_pri < 0.05 THEN 'P1'
              WHEN u_pri < 0.25 THEN 'P2'
              WHEN u_pri < 0.70 THEN 'P3'
              ELSE 'P4' END                              AS priority,
         CASE WHEN u_cat < 0.20 THEN 'Login/Access'
              WHEN u_cat < 0.35 THEN 'Billing'
              WHEN u_cat < 0.55 THEN 'Bug/Defect'
              WHEN u_cat < 0.65 THEN 'Performance'
              WHEN u_cat < 0.78 THEN 'Integration/API'
              WHEN u_cat < 0.90 THEN 'How-To'
              WHEN u_cat < 0.95 THEN 'Feature Request'
              ELSE 'Reporting/Export' END                AS category,
         CASE WHEN u_chan < 0.45 THEN 'Email'
              WHEN u_chan < 0.75 THEN 'Chat'
              WHEN u_chan < 0.90 THEN 'Phone'
              ELSE 'Portal' END                          AS channel
  FROM t0
),
t2 AS (
  SELECT t1.*,
         DATEADD(second, hr * 3600 + u_min * 60 + u_sec, d1::TIMESTAMP_NTZ) AS created_at,
         c.plan_tier,
         p.first_response_target_min                     AS fr_t,
         p.resolution_target_min                         AS res_t
  FROM t1
  JOIN dim_clients    c ON c.client_id = t1.client_id
  JOIN dim_sla_policy p ON p.priority  = t1.priority
),
t3 AS (
  SELECT t2.*,
         (CASE plan_tier WHEN 'Enterprise' THEN 0.8 WHEN 'Pro' THEN 1.0 ELSE 1.3 END)
         * IFF(DAYOFWEEKISO(created_at) >= 6, 1.5, 1.0)  AS slow
  FROM t2
),
t4 AS (
  SELECT t3.*,
         fr_t  * slow * (0.15 + 1.6 * POW(u_resp, 3))    AS response_min,
         GREATEST(fr_t * slow * (0.15 + 1.6 * POW(u_resp, 3)) + 1,
                  res_t * slow * (0.10 + 1.4 * POW(u_res, 3))) AS resolution_min
  FROM t3
),
t5 AS (
  SELECT t4.*,
         DATEADD(second, ROUND(response_min   * 60), created_at) AS frt_ts,
         DATEADD(second, ROUND(resolution_min * 60), created_at) AS res_ts
  FROM t4
),
t6 AS (
  SELECT t5.*,
         IFF(frt_ts <= $as_of_ts, frt_ts, NULL)          AS first_response_at,
         -- ~0.5% of older tickets never get resolved (stale backlog)
         CASE WHEN res_ts <= $as_of_ts AND u_backlog >= 0.005
              THEN IFF(u_dq < 0.002, DATEADD(hour, -2, created_at), res_ts)  -- dirty rows
         END                                              AS resolved_at
  FROM t5
)
SELECT
  ticket_id,
  client_id,
  IFF(u_noagent < 0.005, NULL,
      IFF(priority IN ('P1','P2'), u_agent_hi, u_agent_lo))::NUMBER(18,0)          AS agent_id,
  created_at,
  first_response_at,
  resolved_at,
  priority,
  category,
  channel,
  CASE WHEN resolved_at IS NOT NULL THEN IFF(u_status < 0.70, 'Closed', 'Resolved')
       WHEN first_response_at IS NULL THEN 'Open'
       WHEN u_status < 0.60 THEN 'In Progress'
       ELSE 'Pending Customer' END                                   AS status,
  CASE category
    WHEN 'Login/Access' THEN GET(ARRAY_CONSTRUCT('Cannot log in after password reset',
                                                 'SSO redirect loop for our users',
                                                 'Account locked, need access restored'), u_text)::STRING
    WHEN 'Billing' THEN GET(ARRAY_CONSTRUCT('Invoice amount does not match our contract',
                                            'Charged twice this month',
                                            'Need updated billing contact on invoices'), u_text)::STRING
    WHEN 'Bug/Defect' THEN GET(ARRAY_CONSTRUCT('Dashboard widget shows an error on load',
                                               'Saved filters disappear after refresh',
                                               'Report totals are inconsistent between pages'), u_text)::STRING
    WHEN 'Performance' THEN GET(ARRAY_CONSTRUCT('Pages are loading very slowly since yesterday',
                                                'Search times out on large accounts',
                                                'Export job runs for hours without finishing'), u_text)::STRING
    WHEN 'Integration/API' THEN GET(ARRAY_CONSTRUCT('API returns 429 errors during sync',
                                                    'Webhook events are arriving out of order',
                                                    'OAuth token refresh keeps failing'), u_text)::STRING
    WHEN 'How-To' THEN GET(ARRAY_CONSTRUCT('How do we add new users in bulk',
                                           'Where can we configure notification rules',
                                           'How do we schedule a recurring report'), u_text)::STRING
    WHEN 'Feature Request' THEN GET(ARRAY_CONSTRUCT('Request: custom fields on the account page',
                                                    'Request: dark mode for the dashboard',
                                                    'Request: more granular role permissions'), u_text)::STRING
    ELSE GET(ARRAY_CONSTRUCT('Need a CSV export of all activity for audit',
                             'Scheduled report is missing the last column',
                             'Cannot export more than 10,000 rows'), u_text)::STRING
  END                                                                AS subject,
  CASE WHEN u_tone < 0.55 THEN 'Hello, we need help with this: '
       WHEN u_tone < 0.75 THEN 'URGENT - this is blocking our whole team. '
       WHEN u_tone < 0.90 THEN 'This is the third time we have hit this and we are really frustrated. '
       ELSE 'Thanks for the great service so far. Quick question: ' END
  || LOWER(CASE category
       WHEN 'Login/Access' THEN GET(ARRAY_CONSTRUCT('Cannot log in after password reset',
                                                    'SSO redirect loop for our users',
                                                    'Account locked, need access restored'), u_text)::STRING
       WHEN 'Billing' THEN GET(ARRAY_CONSTRUCT('Invoice amount does not match our contract',
                                               'Charged twice this month',
                                               'Need updated billing contact on invoices'), u_text)::STRING
       WHEN 'Bug/Defect' THEN GET(ARRAY_CONSTRUCT('Dashboard widget shows an error on load',
                                                  'Saved filters disappear after refresh',
                                                  'Report totals are inconsistent between pages'), u_text)::STRING
       WHEN 'Performance' THEN GET(ARRAY_CONSTRUCT('Pages are loading very slowly since yesterday',
                                                   'Search times out on large accounts',
                                                   'Export job runs for hours without finishing'), u_text)::STRING
       WHEN 'Integration/API' THEN GET(ARRAY_CONSTRUCT('API returns 429 errors during sync',
                                                       'Webhook events are arriving out of order',
                                                       'OAuth token refresh keeps failing'), u_text)::STRING
       WHEN 'How-To' THEN GET(ARRAY_CONSTRUCT('How do we add new users in bulk',
                                              'Where can we configure notification rules',
                                              'How do we schedule a recurring report'), u_text)::STRING
       WHEN 'Feature Request' THEN GET(ARRAY_CONSTRUCT('Request: custom fields on the account page',
                                                       'Request: dark mode for the dashboard',
                                                       'Request: more granular role permissions'), u_text)::STRING
       ELSE GET(ARRAY_CONSTRUCT('Need a CSV export of all activity for audit',
                                'Scheduled report is missing the last column',
                                'Cannot export more than 10,000 rows'), u_text)::STRING
     END)                                                            AS description,
  -- CSAT only on ~45% of resolved tickets; lower when SLAs were breached
  CASE WHEN resolved_at IS NOT NULL AND u_csat_resp < 0.45
       THEN LEAST(5, GREATEST(1, ROUND(
              4.4
              - 1.3 * IFF(resolution_min > res_t, 1, 0)
              - 0.7 * IFF(response_min   > fr_t,  1, 0)
              + (u_csat_noise - 0.5) * 2.0)))::INT
  END                                                                AS csat_score,
  (resolved_at IS NOT NULL AND u_reopen < 0.06)                      AS is_reopened
FROM t6;


-- ---------------------------------------------------------------------
-- 7. Sanity checks
-- ---------------------------------------------------------------------

-- Row counts
SELECT 'fact_tickets' AS tbl, COUNT(*) AS n FROM fact_tickets UNION ALL
SELECT 'dim_clients',  COUNT(*) FROM dim_clients  UNION ALL
SELECT 'dim_agents',   COUNT(*) FROM dim_agents   UNION ALL
SELECT 'dim_date',     COUNT(*) FROM dim_date;

-- Priority and status mix
SELECT priority, COUNT(*) AS tickets, ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (), 1) AS pct
FROM fact_tickets GROUP BY priority ORDER BY priority;

SELECT status, COUNT(*) AS tickets
FROM fact_tickets GROUP BY status ORDER BY tickets DESC;

-- First-response SLA breach rate by plan tier
SELECT c.plan_tier,
       COUNT(*) AS tickets,
       ROUND(100 * AVG(IFF(DATEDIFF('minute', f.created_at, f.first_response_at)
                           > p.first_response_target_min, 1, 0)), 1) AS response_breach_pct
FROM fact_tickets f
JOIN dim_clients    c ON c.client_id = f.client_id
JOIN dim_sla_policy p ON p.priority  = f.priority
WHERE f.first_response_at IS NOT NULL
GROUP BY c.plan_tier ORDER BY response_breach_pct DESC;

-- Weekend vs weekday breach rate
SELECT d.is_weekend,
       COUNT(*) AS tickets,
       ROUND(100 * AVG(IFF(DATEDIFF('minute', f.created_at, f.first_response_at)
                           > p.first_response_target_min, 1, 0)), 1) AS response_breach_pct
FROM fact_tickets f
JOIN dim_date       d ON d.date_day = f.created_at::DATE
JOIN dim_sla_policy p ON p.priority = f.priority
WHERE f.first_response_at IS NOT NULL
GROUP BY d.is_weekend;

-- Intentional dirty data
SELECT COUNT_IF(resolved_at < created_at) AS resolved_before_created,
       COUNT_IF(agent_id IS NULL)         AS missing_agent
FROM fact_tickets;
