# Interview talking points

Use this as a prompt for your own words, not a script. Fill in the bracketed numbers from your actual run so every claim is something you can defend.

## The 30-second pitch

"I built a support analytics project in Snowflake that works the way a support team's reporting does. I generated about 150,000 synthetic tickets, modeled them as a star schema, and built the metrics a support manager asks for: SLA compliance, backlog age, CSAT trends, and which clients are getting worse. I added an automated pipeline, data quality checks, role-based access with PII masking, and a Streamlit dashboard. I also used Snowflake's AI functions to score sentiment and categorize tickets, and I validated them against known labels instead of trusting them."

## The 2-minute walkthrough

1. **Problem:** a support manager needs SLA performance, client risk, backlog, and trustworthy data.
2. **Data:** synthetic, generated in SQL, with a few patterns planted on purpose so I could check the pipeline found them (say this openly).
3. **Model:** star schema, one fact table and four dimensions, with a base view that does all joins and SLA flags once.
4. **Metrics:** views with window functions. Mention one you're proud of, such as the at-risk client logic or the health score.
5. **Reliability:** stream plus task for the daily summary, dynamic table for backlog, data quality checks logged to an audit table.
6. **Governance:** an analyst role with read-only access and masked contact info.
7. **Reporting:** a four-page Streamlit app with filters.
8. **Result:** one or two findings with numbers, and one thing you'd do differently.

## Questions you should expect, and how to answer them

**Why a star schema?**
Reporting questions slice one event table (tickets) by different dimensions (client, agent, priority, date). A star schema keeps the joins simple and the metrics consistent. For a dataset this size it's mostly about clarity and how BI tools expect the data.

**How did you define the SLA metrics?**
Wall-clock time from created to first response, and from created to resolved, compared against targets by priority. The clock doesn't pause while waiting on the customer, and it ignores business hours. Say that plainly, then say what you'd change: pause states and business-hours calendars would be modeled in the enriched view. Interviewers like candidates who know the limits of their own definition.

**Why did you count breach rates only on tickets where the event happened?**
A ticket with no response yet hasn't breached or met anything that can be judged fairly. Counting it as "met" inflates compliance and counting it as "breached" is premature. A separate view of tickets currently at risk of breaching would complement it.

**Stream and task, or a dynamic table?**
I used both, on purpose. The stream and task incrementally update a summary table, only recompute the days that changed, and give explicit control over scheduling and a `MERGE`. The dynamic table is declarative: I state the query and a target lag, and Snowflake manages refresh. For simple "always current" views, dynamic tables are less code. For custom logic or side effects, tasks are more flexible.

**How did you handle bad data?**
I planted two problems (resolved before created, missing agents) and wrote 14 checks that log to an audit table with PASS, WARN, or FAIL and a severity. The metric views exclude impossible timelines, but the checks surface them, and a view lists the offending ticket IDs so someone can fix the source. Mention that silently dropping rows without reporting them is the real risk.

**How did you choose the health score weights?**
They're judgment calls. I capped each penalty so one metric can't dominate, and I looked at the score distribution to set the cutoffs. With real data I'd validate against renewals or churn and adjust. Don't claim the score is predictive.

**How do you know the AI output is any good?**
I compared AI_CLASSIFY results to the known categories on a sample and reported [X]% accuracy. I'm upfront that the ticket text is templated, so real-world accuracy would be lower. For sentiment, I mapped the labels to a simple score and checked it against the tone I'd written and against CSAT. The CSAT correlation was near zero because I generated them independently, which is exactly the kind of assumption to test before building on it.

**How did you control cost?**
XS warehouse with a 60-second auto-suspend, AI functions on a 2,000-ticket sample instead of all 150,000, tasks left suspended, and the dynamic table suspended between sessions.

**What would you do differently with real data?**
Load incrementally from the source system, add automated tests (dbt or similar), alert on failed quality checks, model SLA pauses and business hours, and validate the health score against outcomes.

**What was hard?**
Pick a real one. Candidates from this project: getting random-number generation to be evaluated once per row (staging draws in a temp table), deciding how to treat tickets with no response yet, trial-account limits on AI functions and masking policies, or deprecated AI function names. A genuine problem and how you solved it is more convincing than a polished answer.

## Be honest about these

- The data is synthetic and the patterns were planted. Frame the findings as "the pipeline recovers the patterns I built in," not as discoveries.
- Don't oversell the AI work. It's a sample on templated text.
- If you used AI assistance to build parts of it, be ready to explain any line of the SQL. Run the scripts, break something on purpose, and fix it, so you can speak to it from experience.

## Resume bullets (adjust the numbers to your run)

- Built an end-to-end support analytics project in Snowflake: star schema over 150K synthetic tickets, SQL views for SLA compliance, CSAT, backlog, and client risk using window functions.
- Automated a daily summary pipeline with Streams, Tasks, and MERGE, and a backlog table with Dynamic Tables; added role-based access and masking policies for client PII.
- Wrote 14 data quality checks logged to an audit table, and a weekly client health report with a 0-100 score and plain-English account summaries.
- Applied Snowflake AI functions (AI_SENTIMENT, AI_CLASSIFY) to ticket text and validated categorization against known labels at [X]% accuracy.
- Delivered a four-page Streamlit in Snowflake dashboard with filters for date, tier, priority, and client.

## Before you publish the repo

- Fill in the key findings and add screenshots to the README.
- Make sure nothing includes your account URL, account identifier, or email.
- Pin the repo on your GitHub profile and link it from your resume and LinkedIn.
- Suspend or drop the dynamic table and tasks in Snowflake so the trial credits last.
