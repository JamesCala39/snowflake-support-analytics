"""
Client Support Operations Dashboard (Streamlit in Snowflake)

Reads the views and tables built in Steps 1-2 of the project:
  v_ticket_enriched, v_client_ticket_volume, v_at_risk_clients,
  dt_open_tickets_by_age, dataset_config, dim_clients

Paste this whole file into a Streamlit in Snowflake app
(Snowsight > Projects > Streamlit) located in SUPPORT_ANALYTICS.CORE.
"""
from datetime import date, timedelta

import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Support Operations Dashboard", layout="wide")
session = get_active_session()


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------
@st.cache_data(ttl=600, show_spinner=False)
def run(sql: str) -> pd.DataFrame:
    """Run SQL, lower-case column names, and coerce Decimal-like columns to numbers."""
    df = session.sql(sql).to_pandas()
    df.columns = [c.lower() for c in df.columns]
    for c in df.columns:
        if df[c].dtype == "object":
            try:
                df[c] = pd.to_numeric(df[c])
            except (ValueError, TypeError):
                pass  # strings and dates stay as they are
    return df


def sql_list(values) -> str:
    """Turn a list of strings into a safely quoted SQL IN-list."""
    return ", ".join("'" + str(v).replace("'", "''") + "'" for v in values)


def pct(v) -> str:
    return "n/a" if pd.isna(v) else f"{v:.1f}%"


def num(v, digits=2) -> str:
    return "n/a" if pd.isna(v) else f"{v:.{digits}f}"


# ----------------------------------------------------------------------
# Sidebar: navigation + filters
# ----------------------------------------------------------------------
as_of = pd.to_datetime(run("SELECT as_of_ts::DATE AS as_of FROM dataset_config").loc[0, "as_of"]).date()
data_start = date(2025, 11, 1)

st.sidebar.title("Support Ops")
page = st.sidebar.radio("Page", ["Overview", "SLA performance", "Backlog", "Clients & risk"])

st.sidebar.header("Filters")
date_range = st.sidebar.date_input(
    "Created between",
    value=(max(data_start, as_of - timedelta(days=89)), as_of),
    min_value=data_start,
    max_value=as_of,
)
if len(date_range) != 2:
    st.info("Pick an end date to continue.")
    st.stop()
start, end = date_range

all_tiers = run("SELECT DISTINCT plan_tier FROM dim_clients ORDER BY plan_tier")["plan_tier"].tolist()
sel_tiers = st.sidebar.multiselect("Plan tier", all_tiers, default=all_tiers)
sel_prios = st.sidebar.multiselect("Priority", ["P1", "P2", "P3", "P4"], default=["P1", "P2", "P3", "P4"])

clients = run("SELECT client_id, client_name FROM dim_clients ORDER BY client_name, client_id")
client_labels = {f"{r.client_name} (#{r.client_id})": int(r.client_id) for r in clients.itertuples()}
sel_client_label = st.sidebar.selectbox("Client", ["All clients"] + list(client_labels.keys()))
sel_client_id = client_labels.get(sel_client_label)

st.sidebar.caption(
    "Definitions: SLA clocks are wall-clock time and do not pause while waiting on the customer. "
    "Breach rates only count tickets where the response or resolution has happened. "
    f"Data is as of {as_of:%b %d, %Y}."
)

if not sel_tiers or not sel_prios:
    st.warning("Select at least one plan tier and one priority.")
    st.stop()

client_clause = f" AND client_id = {sel_client_id}" if sel_client_id else ""
where = (
    f"created_date BETWEEN '{start}' AND '{end}' "
    f"AND plan_tier IN ({sql_list(sel_tiers)}) "
    f"AND priority IN ({sql_list(sel_prios)})"
    f"{client_clause}"
)
# Same filters without the date range (used by pages that look at "right now")
where_now = (
    f"plan_tier IN ({sql_list(sel_tiers)}) AND priority IN ({sql_list(sel_prios)}){client_clause}"
)


# ----------------------------------------------------------------------
# Page: Overview
# ----------------------------------------------------------------------
if page == "Overview":
    st.title("Support Overview")
    st.caption(f"{start:%b %d, %Y} to {end:%b %d, %Y}")

    kpi = run(f"""
        SELECT COUNT(*)                                             AS tickets,
               ROUND(100 * AVG(response_breached::INT), 1)          AS response_breach_pct,
               ROUND(100 * AVG(resolution_breached::INT), 1)        AS resolution_breach_pct,
               ROUND(AVG(csat_score), 2)                            AS avg_csat,
               ROUND(100 * AVG(IFF(resolved_at IS NOT NULL, is_reopened::INT, NULL)), 1) AS reopen_pct
        FROM v_ticket_enriched
        WHERE {where}
    """).iloc[0]

    if kpi["tickets"] == 0:
        st.info("No tickets match these filters.")
        st.stop()

    c1, c2, c3, c4, c5 = st.columns(5)
    c1.metric("Tickets", f"{int(kpi['tickets']):,}")
    c2.metric("First response breach", pct(kpi["response_breach_pct"]))
    c3.metric("Resolution breach", pct(kpi["resolution_breach_pct"]))
    c4.metric("Avg CSAT (1-5)", num(kpi["avg_csat"]))
    c5.metric("Reopen rate", pct(kpi["reopen_pct"]))

    st.subheader("Daily ticket volume")
    daily = run(f"""
        SELECT created_date, COUNT(*) AS tickets
        FROM v_ticket_enriched WHERE {where}
        GROUP BY created_date ORDER BY created_date
    """)
    daily["created_date"] = pd.to_datetime(daily["created_date"])
    daily = daily.set_index("created_date").asfreq("D", fill_value=0)
    daily["7-day avg"] = daily["tickets"].rolling(7, min_periods=1).mean().round(1)
    st.line_chart(daily[["tickets", "7-day avg"]])

    left, right = st.columns(2)

    with left:
        st.subheader("Top ticket categories")
        cats = run(f"""
            SELECT category, COUNT(*) AS tickets
            FROM v_ticket_enriched WHERE {where}
            GROUP BY category ORDER BY tickets DESC
        """)
        st.altair_chart(
            alt.Chart(cats).mark_bar().encode(
                x=alt.X("tickets:Q", title="Tickets"),
                y=alt.Y("category:N", sort="-x", title=None),
                tooltip=["category", "tickets"],
            ),
        )
        top = cats.iloc[0]
        share = 100 * top["tickets"] / cats["tickets"].sum()
        st.caption(f"{top['category']} is the largest category at {share:.0f}% of tickets in this view.")

    with right:
        st.subheader("Channel mix")
        chans = run(f"""
            SELECT channel, COUNT(*) AS tickets
            FROM v_ticket_enriched WHERE {where}
            GROUP BY channel ORDER BY tickets DESC
        """)
        st.altair_chart(
            alt.Chart(chans).mark_bar().encode(
                x=alt.X("tickets:Q", title="Tickets"),
                y=alt.Y("channel:N", sort="-x", title=None),
                tooltip=["channel", "tickets"],
            ),
        )


# ----------------------------------------------------------------------
# Page: SLA performance
# ----------------------------------------------------------------------
elif page == "SLA performance":
    st.title("SLA Performance")
    st.caption(f"{start:%b %d, %Y} to {end:%b %d, %Y}")

    by_prio = run(f"""
        SELECT priority,
               COUNT(*)                                          AS tickets,
               ROUND(MEDIAN(first_response_min), 1)              AS median_first_response_min,
               ROUND(100 * AVG(response_breached::INT), 1)       AS response_breach_pct,
               ROUND(MEDIAN(resolution_min) / 60, 1)             AS median_resolution_hours,
               ROUND(100 * AVG(resolution_breached::INT), 1)     AS resolution_breach_pct
        FROM v_ticket_enriched WHERE {where}
        GROUP BY priority ORDER BY priority
    """)
    if by_prio.empty:
        st.info("No tickets match these filters.")
        st.stop()

    st.subheader("Breach rate by priority")
    melted = by_prio.melt(
        id_vars="priority",
        value_vars=["response_breach_pct", "resolution_breach_pct"],
        var_name="metric",
        value_name="breach_pct",
    )
    melted["metric"] = melted["metric"].map(
        {"response_breach_pct": "First response", "resolution_breach_pct": "Resolution"}
    )
    st.altair_chart(
        alt.Chart(melted).mark_bar().encode(
            x=alt.X("priority:N", title="Priority"),
            xOffset="metric:N",
            y=alt.Y("breach_pct:Q", title="Breach rate (%)"),
            color=alt.Color("metric:N", title=None),
            tooltip=["priority", "metric", "breach_pct"],
        ),
    )
    st.dataframe(by_prio.set_index("priority"))

    st.subheader("First response breach % by plan tier and priority")
    tier_prio = run(f"""
        SELECT plan_tier, priority,
               ROUND(100 * AVG(response_breached::INT), 1) AS response_breach_pct
        FROM v_ticket_enriched WHERE {where}
        GROUP BY plan_tier, priority
    """)
    st.dataframe(tier_prio.pivot(index="plan_tier", columns="priority", values="response_breach_pct"))

    st.subheader("Monthly breach trend")
    monthly = run(f"""
        SELECT created_month,
               ROUND(100 * AVG(response_breached::INT), 1)   AS first_response_breach_pct,
               ROUND(100 * AVG(resolution_breached::INT), 1) AS resolution_breach_pct
        FROM v_ticket_enriched WHERE {where}
        GROUP BY created_month ORDER BY created_month
    """)
    monthly["created_month"] = pd.to_datetime(monthly["created_month"])
    st.line_chart(monthly.set_index("created_month"))

    st.subheader("Weekend vs weekday")
    wk = run(f"""
        SELECT IFF(DAYOFWEEKISO(created_date) >= 6, 'Weekend', 'Weekday') AS day_type,
               COUNT(*)                                          AS tickets,
               ROUND(100 * AVG(response_breached::INT), 1)       AS response_breach_pct,
               ROUND(100 * AVG(resolution_breached::INT), 1)     AS resolution_breach_pct
        FROM v_ticket_enriched WHERE {where}
        GROUP BY day_type
    """).set_index("day_type")
    st.dataframe(wk)
    if {"Weekend", "Weekday"} <= set(wk.index):
        we, wd = wk.loc["Weekend", "response_breach_pct"], wk.loc["Weekday", "response_breach_pct"]
        if pd.notna(we) and pd.notna(wd):
            st.info(
                f"Weekend tickets breach the first-response SLA at {we:.1f}% versus {wd:.1f}% on weekdays "
                f"in this view. If the gap is large, weekend staffing is the first thing to look at."
            )


# ----------------------------------------------------------------------
# Page: Backlog (current open tickets; ignores the date filter)
# ----------------------------------------------------------------------
elif page == "Backlog":
    st.title("Open Ticket Backlog")
    st.caption(
        f"Tickets still unresolved as of {as_of:%b %d, %Y}. Source: dynamic table dt_open_tickets_by_age. "
        "The date and client filters do not apply here."
    )

    backlog = run(f"""
        SELECT age_bucket, bucket_order, priority, SUM(open_tickets) AS open_tickets
        FROM dt_open_tickets_by_age
        WHERE plan_tier IN ({sql_list(sel_tiers)}) AND priority IN ({sql_list(sel_prios)})
        GROUP BY age_bucket, bucket_order, priority
        ORDER BY bucket_order, priority
    """)
    if backlog.empty:
        st.info("No open tickets match these filters.")
        st.stop()

    order = backlog.drop_duplicates("age_bucket").sort_values("bucket_order")["age_bucket"].tolist()
    total_open = int(backlog["open_tickets"].sum())
    old_open = int(backlog.loc[backlog["bucket_order"] >= 4, "open_tickets"].sum())

    m1, m2, m3 = st.columns(3)
    m1.metric("Open tickets", f"{total_open:,}")
    m2.metric("Older than 3 days", f"{old_open:,}")
    m3.metric("Share older than 3 days", pct(100 * old_open / total_open))

    st.subheader("Open tickets by age")
    st.altair_chart(
        alt.Chart(backlog).mark_bar().encode(
            x=alt.X("age_bucket:N", sort=order, title="Ticket age"),
            y=alt.Y("open_tickets:Q", title="Open tickets"),
            color=alt.Color("priority:N", title="Priority"),
            tooltip=["age_bucket", "priority", "open_tickets"],
        ),
    )
    st.dataframe(
        backlog.pivot_table(index=["bucket_order", "age_bucket"], columns="priority",
                            values="open_tickets", aggfunc="sum", fill_value=0)
    )


# ----------------------------------------------------------------------
# Page: Clients & risk
# ----------------------------------------------------------------------
else:
    st.title("Clients & Account Risk")

    st.subheader("Who generates the tickets?")
    vol = run("SELECT * FROM v_client_ticket_volume ORDER BY volume_rank, client_id")
    top_n = max(1, round(len(vol) * 0.10))
    top_share = vol.iloc[top_n - 1]["cumulative_pct_of_tickets"]
    st.info(
        f"The top {top_n} clients (10% of {len(vol)}) generate {top_share:.0f}% of all tickets. "
        "Volume is concentrated, so a small number of accounts drive most of the workload."
    )

    vol_view = vol[vol["plan_tier"].isin(sel_tiers)]
    if sel_client_id:
        vol_view = vol_view[vol_view["client_id"] == sel_client_id]
    st.altair_chart(
        alt.Chart(vol_view.head(15)).mark_bar().encode(
            x=alt.X("total_tickets:Q", title="Total tickets"),
            y=alt.Y("client_name:N", sort="-x", title=None),
            color=alt.Color("plan_tier:N", title="Plan tier"),
            tooltip=["client_name", "plan_tier", "total_tickets", "avg_csat"],
        ),
    )

    st.subheader("At-risk clients")
    st.caption(
        f"Compares the 30 days ending {as_of:%b %d, %Y} with the 30 days before. "
        "Flags: volume up 50% or more (10+ tickets), CSAT down 0.5 or more, "
        "or 35%+ of tickets breaching an SLA (10+ tickets). Date and priority filters do not apply."
    )
    risk = run(f"""
        SELECT * FROM v_at_risk_clients
        WHERE plan_tier IN ({sql_list(sel_tiers)}){client_clause}
    """)

    min_flags = st.slider("Minimum risk flags", 1, 3, 1)
    flagged = risk[risk["risk_flags"] >= min_flags].sort_values(
        ["risk_flags", "tickets_last_30d"], ascending=[False, False]
    )

    r1, r2, r3 = st.columns(3)
    r1.metric("Clients with 1+ flags", f"{int((risk['risk_flags'] >= 1).sum()):,}")
    r2.metric("Clients with 2+ flags", f"{int((risk['risk_flags'] >= 2).sum()):,}")
    r3.metric("Clients with 3 flags", f"{int((risk['risk_flags'] >= 3).sum()):,}")

    if flagged.empty:
        st.info("No clients meet this threshold.")
    else:
        table = flagged[[
            "client_name", "plan_tier", "risk_flags",
            "tickets_last_30d", "tickets_prior_30d", "volume_change_pct",
            "csat_prior_30d", "csat_last_30d", "csat_change",
            "breach_rate_pct_last_30d",
            "flag_rising_volume", "flag_falling_csat", "flag_sla_breaches",
        ]].copy()
        for c in ["csat_prior_30d", "csat_last_30d", "csat_change"]:
            table[c] = table[c].round(2)
        for c in ["flag_rising_volume", "flag_falling_csat", "flag_sla_breaches"]:
            table[c] = table[c].astype(bool)
        st.dataframe(table.set_index("client_name"))
