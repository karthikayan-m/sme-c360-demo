# SME Business Banking Customer 360 - Streamlit in Snowflake
# Create in Snowsight: Projects > Streamlit > + Streamlit App (DB SME_BANK_DB, schema AI, warehouse SME_WH), paste this file.
import json
import re

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

try:
    import _snowflake  # available inside Streamlit in Snowflake
except ImportError:
    _snowflake = None

DB = "SME_BANK_DB"
SEMANTIC_VIEW = f"{DB}.GOLD.SME_PORTFOLIO_SEMANTIC_VIEW"
session = get_active_session()
st.set_page_config(page_title="SME Customer 360", layout="wide")


@st.cache_data(ttl=300)
def q(sql: str) -> pd.DataFrame:
    return session.sql(sql).to_pandas()


def myr(v) -> str:
    if v is None or pd.isna(v):
        return "n/a"
    v = float(v)
    return f"RM {v/1e6:,.1f}m" if abs(v) >= 1e6 else f"RM {v:,.0f}"


st.title("SME Business Banking Customer 360")
st.caption("One governed view of SME lending, cash flow, bureau, trade finance and RM insight. "
           "Scores and AI drafts support, not replace, credit decisions.")

tab_port, tab_cust, tab_ask, tab_gov = st.tabs(["Portfolio", "Customer 360", "Ask the portfolio", "Governance"])

# ---------------- Portfolio ----------------
with tab_port:
    k = q(f"""
        SELECT SUM(TOTAL_OUTSTANDING_MYR) EXPOSURE,
               DIV0(SUM(NPL_OUTSTANDING_MYR), SUM(TOTAL_OUTSTANDING_MYR)) NPL_RATIO,
               COUNT_IF(EARLY_WARNING_FLAG) WATCHLIST,
               SUM(IFF(EARLY_WARNING_FLAG, TOTAL_OUTSTANDING_MYR, 0)) WATCHLIST_EXPOSURE
        FROM {DB}.GOLD.CUSTOMER_360_SCORED""").iloc[0]
    tat = q(f"SELECT AVG(DECISION_DAYS) D FROM {DB}.GOLD.FACT_APPLICATION WHERE STATUS <> 'Pending'").iloc[0]["D"]
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("SME exposure", myr(k["EXPOSURE"]))
    c2.metric("Gross NPL ratio", f"{float(k['NPL_RATIO'] or 0)*100:.2f}%")
    c3.metric("Early-warning watchlist", f"{int(k['WATCHLIST'])} SMEs", myr(k["WATCHLIST_EXPOSURE"]) + " at risk",
              delta_color="off")
    c4.metric("Avg loan decision time", f"{float(tat or 0):.1f} days")

    l, r = st.columns(2)
    with l:
        st.subheader("NPL ratio by industry")
        ind = q(f"""SELECT INDUSTRY, ROUND(DIV0(SUM(NPL_OUTSTANDING_MYR), SUM(TOTAL_OUTSTANDING_MYR))*100, 2) NPL_PCT
                    FROM {DB}.GOLD.CUSTOMER_360 GROUP BY 1 ORDER BY 2 DESC""")
        st.bar_chart(ind, x="INDUSTRY", y="NPL_PCT")
    with r:
        st.subheader("Customers by PD band")
        band = q(f"""SELECT RISK_BAND, COUNT(*) CUSTOMERS FROM {DB}.GOLD.CUSTOMER_360_SCORED
                     WHERE RISK_BAND IS NOT NULL GROUP BY 1 ORDER BY 1""")
        st.bar_chart(band, x="RISK_BAND", y="CUSTOMERS")

    st.subheader("Early-warning watchlist")
    st.caption("Performing customers whose score or cash flow is deteriorating. Act before they reach 90 days past due.")
    st.dataframe(q(f"SELECT * FROM {DB}.ML.V_EARLY_WARNING_WATCHLIST LIMIT 50"), use_container_width=True, hide_index=True)

    with st.expander("Model card"):
        st.dataframe(q(f"SELECT * FROM {DB}.ML.MODEL_METRICS ORDER BY TRAINED_AT DESC LIMIT 1"), hide_index=True)
        st.bar_chart(q(f"""SELECT FEATURE, IMPORTANCE FROM {DB}.ML.FEATURE_IMPORTANCE
                           WHERE MODEL_VERSION = (SELECT MAX(MODEL_VERSION) FROM {DB}.ML.FEATURE_IMPORTANCE)
                           ORDER BY IMPORTANCE DESC"""), x="FEATURE", y="IMPORTANCE")

# ---------------- Customer 360 ----------------
with tab_cust:
    custs = q(f"""SELECT CUSTOMER_ID, COMPANY_NAME, RISK_BAND FROM {DB}.GOLD.CUSTOMER_360_SCORED
                  ORDER BY PD DESC NULLS LAST""")
    labels = [f"{r.COMPANY_NAME} · {r.CUSTOMER_ID} · band {r.RISK_BAND}" for r in custs.itertuples()]
    pick = st.selectbox("Find a customer (sorted by highest PD)", labels)
    cid = custs.iloc[labels.index(pick)]["CUSTOMER_ID"]
    if not re.fullmatch(r"SME\d{6}", cid):
        st.stop()
    c = q(f"SELECT * FROM {DB}.GOLD.CUSTOMER_360_SCORED WHERE CUSTOMER_ID = '{cid}'").iloc[0]

    st.subheader(c["COMPANY_NAME"])
    st.write(f"{c['INDUSTRY']} · {c['STATE']} · {int(c['YEARS_IN_BUSINESS'])} years · RM {c['RM_ID']} · "
             f"SSM {c['SSM_REG_NO']}")
    m = st.columns(5)
    m[0].metric("12-month PD", f"{float(c['PD'] or 0)*100:.1f}%", f"Band {c['RISK_BAND']}", delta_color="off")
    m[1].metric("Outstanding", myr(c["TOTAL_OUTSTANDING_MYR"]))
    m[2].metric("Cash inflow vs prior 90d", f"{float(c['INFLOW_TREND_PCT'] or 0):+.1f}%")
    m[3].metric("CTOS score", "hidden" if pd.isna(c["CTOS_SCORE"]) else int(c["CTOS_SCORE"]))
    m[4].metric("Related parties in NPL", int(c["RELATED_PARTY_NPL_CNT"]))

    if c["EARLY_WARNING_FLAG"]:
        st.warning(f"On watchlist. Drivers: {c['RISK_DRIVERS'] or 'n/a'}")
    else:
        st.info(f"Drivers: {c['RISK_DRIVERS'] or 'none flagged'}")
    st.success(f"Next best action: {c['NEXT_BEST_ACTION']}")

    a, b = st.columns(2)
    with a:
        st.markdown("**Daily cash inflows (180 days)**")
        st.line_chart(q(f"""SELECT TXN_DATE, SUM(AMOUNT_MYR) INFLOW_MYR FROM {DB}.GOLD.FACT_TXN_DAILY
                            WHERE CUSTOMER_ID = '{cid}' AND DIRECTION = 'CR' GROUP BY 1 ORDER BY 1"""),
                      x="TXN_DATE", y="INFLOW_MYR")
        st.markdown("**Related parties (shared directors or guarantors)**")
        st.dataframe(q(f"""SELECT r.RELATED_CUSTOMER_ID, d.COMPANY_NAME, r.SHARED_PARTY_NAME, s.NPL_FLAG, s.RISK_BAND
                           FROM {DB}.SILVER.RELATED_PARTY_LINKS r
                           JOIN {DB}.GOLD.CUSTOMER_360_SCORED s ON s.CUSTOMER_ID = r.RELATED_CUSTOMER_ID
                           JOIN {DB}.GOLD.DIM_CUSTOMER d ON d.CUSTOMER_ID = r.RELATED_CUSTOMER_ID
                           WHERE r.CUSTOMER_ID = '{cid}'"""), hide_index=True, use_container_width=True)
    with b:
        st.markdown("**Facilities**")
        st.dataframe(q(f"""SELECT LOAN_ID, PRODUCT, OUTSTANDING_MYR, CURRENT_DPD, LOAN_STATUS
                           FROM {DB}.GOLD.FACT_LOAN WHERE CUSTOMER_ID = '{cid}'"""), hide_index=True, use_container_width=True)
        st.markdown("**RM notes (AI-tagged)**")
        st.dataframe(q(f"""SELECT NOTE_DATE, RISK_CUE, ROUND(SENTIMENT, 2) SENTIMENT, NOTE_TEXT
                           FROM {DB}.AI.RM_NOTE_INSIGHTS WHERE CUSTOMER_ID = '{cid}' ORDER BY NOTE_DATE DESC"""),
                     hide_index=True, use_container_width=True)
        st.markdown("**Trade documents (AI-extracted)**")
        st.dataframe(q(f"""SELECT DOC_ID, DOC_TYPE, COUNTERPARTY, CURRENCY, AMOUNT, HAS_DISCREPANCY, DISCREPANCY_SUMMARY
                           FROM {DB}.AI.TF_EXTRACTED WHERE CUSTOMER_ID = '{cid}'"""), hide_index=True, use_container_width=True)

    if st.button("Draft credit memo", type="primary"):
        with st.spinner("Drafting memo from the 360 data, score and RM notes..."):
            memo = session.call(f"{DB}.AI.GENERATE_CREDIT_MEMO", cid)
        st.markdown(memo)
        st.caption("AI draft for credit committee review. Verify figures against source systems.")

# ---------------- Ask the portfolio (Cortex Analyst) ----------------
with tab_ask:
    st.caption("Ask in plain English or Malay. Answers are generated as SQL over the governed semantic view. "
               "For search over RM notes and memos, use the SME Credit Copilot in Snowflake Intelligence.")
    examples = ["What is the NPL ratio by industry?",
                "Top 10 watchlist SMEs in Selangor by PD",
                "Average time to decision by product",
                "Total exposure by risk band"]
    ex = st.pills("Try", examples) if hasattr(st, "pills") else None
    if "chat" not in st.session_state:
        st.session_state.chat = []
    for msg in st.session_state.chat:
        with st.chat_message(msg["role"]):
            st.markdown(msg["text"])
            if msg.get("sql"):
                with st.expander("SQL"):
                    st.code(msg["sql"], language="sql")
                st.dataframe(msg["df"], hide_index=True)

    question = st.chat_input("Ask about the SME portfolio") or ex
    if question:
        st.session_state.chat.append({"role": "user", "text": question})
        text, sql, df = "", None, None
        if _snowflake is None:
            text = "Cortex Analyst is available when this app runs in Streamlit in Snowflake."
        else:
            body = {"messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
                    "semantic_view": SEMANTIC_VIEW}
            resp = _snowflake.send_snow_api_request("POST", "/api/v2/cortex/analyst/message", {}, {}, body, None, 50000)
            if resp["status"] >= 400:
                text = f"Cortex Analyst returned {resp['status']}: {resp['content']}"
            else:
                for part in json.loads(resp["content"])["message"]["content"]:
                    if part["type"] == "text":
                        text += part["text"] + "\n"
                    elif part["type"] == "sql":
                        sql = part["statement"]
                if sql:
                    df = session.sql(sql).to_pandas()
        st.session_state.chat.append({"role": "assistant", "text": text or "Here is the result.", "sql": sql, "df": df})
        st.rerun()

# ---------------- Governance ----------------
with tab_gov:
    st.caption("Consumers only get secure views that mask by role and filter RMs to their own portfolio, "
               "so SQL, BI, the agent and Cortex Analyst all see the same protection. "
               "Run the persona queries in Section 16 of setup.sql to see each role live.")
    role = st.radio("Simulate role", ["CREDIT_ANALYST", "RM_USER", "DATA_ENGINEER", "AUDITOR"], horizontal=True)
    sql = (f"EXECUTE USING POLICY_CONTEXT(CURRENT_ROLE => '{role}') AS "
           f"SELECT CUSTOMER_ID, RM_ID, SSM_REG_NO, CTOS_SCORE, TOTAL_OUTSTANDING_MYR "
           f"FROM {DB}.GOLD.CUSTOMER_360 ORDER BY CUSTOMER_ID LIMIT 10")
    try:
        st.dataframe(session.sql(sql).to_pandas(), hide_index=True, use_container_width=True)
    except Exception as e:  # policy simulation needs policy-owner privileges
        st.info(f"Run the persona queries in Section 16 of setup.sql to see this live. ({str(e)[:120]})")
    st.markdown("**PII inventory and controls**")
    st.dataframe(q(f"SELECT * FROM {DB}.GOV.PII_INVENTORY"), hide_index=True, use_container_width=True)
    st.markdown("**Entity resolution outcome**")
    st.dataframe(q(f"""SELECT SOURCE_SYSTEM, MATCH_RULE, COUNT(*) RECORDS FROM {DB}.SILVER.ENTITY_XREF
                       GROUP BY 1, 2 ORDER BY 1, 2"""), hide_index=True)