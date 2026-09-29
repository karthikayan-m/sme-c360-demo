# Demo script (15 minutes)

## 0. Framing, CRO first (1 min)
"Your SME book is growing slower than peers while impairments rise. The data to see trouble early already exists in the bank, but it sits in six systems. This POC joins it into one governed view, scores every SME, and gives RMs and credit a copilot."

## 1. Portfolio tab (2 min), CRO lens
- Exposure, gross NPL ratio, watchlist count and exposure at risk, average decision time.
- NPL by industry and PD band distribution.
- Watchlist: performing customers the model flags now, with plain-language drivers (cash inflow down 40%, related party in NPL, CCRIS arrears). "These are the NPLs of next quarter. Each one has an action attached."

## 2. Customer 360 tab (3 min), RM and credit lens
- Pick the top watchlist SME. Show cash-flow line dropping, related parties with NPL status, facilities, AI-tagged RM notes, AI-extracted trade documents with discrepancies.
- Click Draft credit memo. "Preparing this took an analyst hours across systems; here it takes seconds, grounded only in bank data, and marked as a draft for committee."
- Switch to a band A customer: next best action is a trade line or DuitNow QR, which is wallet-share growth.

## 3. Ask the portfolio + Snowflake Intelligence (2 min)
- "NPL ratio by industry", "Top 10 watchlist SMEs in Selangor by PD", "Average time to decision by product".
- In Snowflake Intelligence, SME Credit Copilot: "Summarise RM concerns about cash flow stress" (Cortex Search) then "Draft a credit memo for SME000xxx" (custom tool).

## 4. Governance (2 min), both audiences
- Governance tab or Section 16 queries: same SELECT as CREDIT_ANALYST (full), RM_USER (own portfolio only, financials banded, CTOS hidden), DATA_ENGINEER (NRIC/SSM/financials masked).
- Tag inventory = data catalogue of sensitive fields. Policies travel with the data to every tool, including the agent.

## 5. Technical deep dive, Head of Data Engineering (4 min)
- Ingestion: batch file drops with COPY INTO + lineage columns (prod: Snowpipe AUTO_INGEST). Payments via Stream + Task + Dynamic Table (prod: Kafka connector in Snowpipe Streaming mode or Openflow CDC). Run `CALL RAW.SIMULATE_TXN_FEED(500)` and show FACT_TXN_DAILY refresh.
- Entity resolution: `SELECT ... FROM SILVER.ENTITY_XREF GROUP BY MATCH_RULE`; steward queue view.
- ML: registry versions, metrics table, daily task graph refresh 360 then rescore via the registered model.
- Everything is SQL/Python inside one platform: no data copies to external ML or LLM services.

## 6. Close (1 min)
Next steps: connect real LOS and core extracts for one region, backtest PD on 24 months of history, calibrate to MFRS 9 staging, pilot the watchlist with 10 RMs for one quarter, and measure NPL migration, decision time and cross-sell.
