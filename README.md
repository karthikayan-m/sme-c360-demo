# SME Business Banking Customer 360 on Snowflake (POC)

## Problem and value
A mid-size Malaysian bank has slow SME loan growth and rising defaults. Loan origination, core banking, bureau, trade finance, CRM and payment data sit in separate systems, so risk shows up late, RMs prepare manually and credit decisions take 1 to 3 weeks.

This POC unifies those sources into one governed Customer 360. It scores every SME for 12-month default probability and puts Cortex AI on top. Target outcomes to validate in a pilot:

| Outcome | Mechanism | Pilot KPI target |
|---|---|---|
| Lower credit losses | Early-warning watchlist from cash-flow, bureau and related-party signals | 10–15% fewer new NPLs in the watchlisted cohort |
| Faster decisions | 360 profile + PD + AI draft memo | Decision time from 10+ days to under 48 hours for standard cases |
| SME wallet share | Next-best action (trade line, DuitNow QR, SJPP loan) | Trade finance cross-sell uplift |
| RM productivity | Memo, note tagging, natural-language Q&A | ~70% less RM prep time |
| Regulatory posture | Tag-based masking, row access, lineage, auditability | Evidence for BNM RMiT and PDPA 2010 reviews |

## Run order
1. Snowsight worksheet: run `scripts/setup.sql` top to bottom as a user with ACCOUNTADMIN. It takes about 10–15 minutes on an XS warehouse, mostly Cortex calls and model training.
2. Streamlit: go to Projects > Streamlit > + Streamlit App. Choose database `SME_BANK_DB`, schema `AI` and warehouse `SME_WH`, then paste `streamlit/app.py`.
3. Snowflake Intelligence: open the agent "SME Credit Copilot".
4. After the demo, run the Section 17 cost guard. Run `scripts/teardown.sql` to remove everything.

Prerequisites: an account with Cortex enabled. The script sets cross-region inference to `ANY_REGION` for regions without the model, such as ap-southeast-1. The LLM used is `mistral-large2`; change it in Sections 7 and 11 if needed.

## Architecture
See `docs/architecture.mermaid`. The layers are SRC (simulated sources), then the landing stage, then RAW (bronze), SILVER (conformed and entity-resolved), GOLD (360 and star schema), ML (registry and scores) and AI (Cortex), with GOV policies across all of them.

| Layer | Choice | Why |
|---|---|---|
| Batch ingestion | Stage + `COPY INTO` with `MATCH_BY_COLUMN_NAME` and `INCLUDE_METADATA` lineage | LOS, core EOD, SSM and bureau arrive as daily files. The reusable loader proc `RAW.INGEST_CSV` gives schema-drift tolerance and file-level lineage. In prod: S3 external stage + Snowpipe `AUTO_INGEST`. |
| Semi-structured | VARIANT landing for bureau, notes and TF docs | Bureau payloads change shape. Schema-on-read avoids brittle pipelines. |
| Near-real-time | Event table, then Stream, then 1-minute Task, then Dynamic Table `FACT_TXN_DAILY` | Cash-inflow decline is the earliest default signal. The Stream gives exactly-once incremental processing, and the DT declares freshness instead of scheduling it. In prod: payment switch to Kafka to the Snowflake Kafka connector in Snowpipe Streaming mode, or Openflow CDC, for seconds of latency. |
| Modelling | Medallion + star (DIM_CUSTOMER, DIM_DIRECTOR, FACT_LOAN, FACT_APPLICATION, FACT_TXN_DAILY) + wide `CUSTOMER_360` | Star for BI and Cortex Analyst. The wide 360 serves features and apps. |
| Entity resolution | SQL UDFs + rules in `SILVER.ENTITY_XREF` | Transparent, auditable rules (see below). A steward queue holds records that don't match. |
| ML | XGBoost in a Python stored proc, Snowflake Model Registry, scoring task | Data never leaves Snowflake. The model is versioned, metrics are logged, and scores land in a table used by the app, agent and RMs. |
| GenAI | Cortex SENTIMENT, CLASSIFY_TEXT, COMPLETE, Search, Analyst, Agent | These run in the governed perimeter with no external API keys, and RBAC and masking apply. |
| Apps | Streamlit in Snowflake + Snowflake Intelligence | There is no separate hosting, and the same policies apply. |

## Entity resolution
Four sources identify the same SME differently. Core uses a CIF and the new 12-digit SSM. The LOS uses its own ID with old `1234567-A` or dashed SSM formats, and sometimes no SSM with a misspelled name. CRM links directors by NRIC. The resolution rules run in precedence order:
1. **SSM exact.** Match on normalised new-format SSM (digits only).
2. **SSM old-to-new.** Map through the SSM registry extract.
3. **Fuzzy name within state.** Applies when there is no SSM. Names are normalised (strip `Sdn Bhd`, punctuation) and the match needs a Jaro-Winkler score of at least 92. The best candidate wins.
4. **Unresolved.** These go to `SILVER.V_ER_UNRESOLVED` for data stewards.

For directors and guarantors, MyKad is normalised to 12 digits. SMEs that share an NRIC form `SILVER.RELATED_PARTY_LINKS`, which is the basis of the related-party NPL contagion feature.

In production, add probabilistic matching on address and phone, survivorship rules, and a golden-record history (SCD2).

## PII inventory and controls
| Data | Tag value | CREDIT_ANALYST | RM_USER | AUDITOR | DATA_ENGINEER |
|---|---|---|---|---|---|
| MyKad / NRIC | NRIC | Clear | `********1234` | `********1234` | `********1234` |
| Director name | PERSON_NAME | Clear | Clear | Clear | Masked |
| Date of birth | DOB | Clear | Year only | Year only | Year only |
| SSM registration | SSM | Clear | Clear | Clear | Partial |
| Balances, turnover, cash flow | FINANCIAL | Clear | Banded to RM100k | Clear | NULL |
| CTOS score | CREDIT_SCORE | Clear | Hidden | Clear | NULL |
| Rows | Row access policy | All | Own RM portfolio | All | All |

The controls are tag-based masking (three policies attached to one tag, so new columns are protected by tagging alone), a row access policy driven by `GOV.RM_TERRITORY_MAP`, least-privilege persona roles, and a `DATA_SENSITIVITY` table tag. Lineage comes from `_SRC_FILE` and `_LOADED_AT` columns and Snowflake Access History. Encryption at rest and in transit is on by default.

These map to regulatory expectations as follows.
- BNM RMiT: access control, data protection and audit trail.
- PDPA 2010: purpose limitation. RMs don't see bureau scores, and engineers don't see identity data.
- CCRIS/CTOS usage restrictions: bureau data goes to credit roles only.
- BNM credit risk policy: explainable reason codes, and a human stays in the loop.

**Limitation.** The Cortex Search corpus and the Streamlit app run with owner's rights. In the demo, access to them is limited through USAGE grants. In production, use caller's-rights apps and per-RM search filters.

## ML model
- **Target:** customer has any loan 90 or more days past due (NPL) within the 12-month window.
- **Features:** years in business, turnover, employees, OD utilisation, 90-day inflow trend, merchant volume, CTOS score, CCRIS arrears, legal cases, related-party NPL count, RM sentiment, RM risk flags, and trade document discrepancies.
- **Training:** XGBoost (depth 3, class-weighted) on a 70/30 stratified split. AUC, precision and recall go to `ML.MODEL_METRICS`, and importances go to `ML.FEATURE_IMPORTANCE`.
- **Output:** PD, band A–E, early-warning flag (performing but deteriorating), rule-based reason codes and next-best action. These are written to `ML.PD_SCORES` and refreshed daily by a task graph (`REFRESH_CUSTOMER_360`, then `SCORE_PD` via the registry).
- **Caveat:** the data is synthetic and generated from a latent risk factor, so AUC will look optimistic. For a real rollout:
  - backtest on 24–36 months with a time-based split
  - calibrate PD
  - add monitoring for drift and PSI
  - document the model under the bank's model risk policy and MFRS 9 staging

## Cortex use cases and guardrails
- **RM notes:** sentiment and risk-cue classification. These feed the model and the 360.
- **Trade documents:** fields and discrepancies extracted into structured columns.
- **Credit memo UDF:** grounded only on the governed 360, the score, the notes and the trade documents. Masking still applies, so an RM's memo shows "not available" for the CTOS score. Output is labelled as a draft for committee.
- **Semantic view + Cortex Analyst:** natural-language portfolio Q&A with visible SQL.
- **Cortex Agent (SME Credit Copilot):** orchestrates Analyst, Search and the memo tool.

## Assumptions and trade-offs
- The data is synthetic: 500 SMEs, about 1.2k loans, about 220k payment events, about 750 RM notes and about 130 trade documents. `SRC` simulates the source systems and would not exist in production.
- The streaming simulator plus 1-minute tasks and DT keeps the warehouse warm, so suspend them after the demo (Section 17).
- `CUSTOMER_360` is a table refreshed by a task rather than a DT, so that tags and row policies sit on a stable serving object.
- Rule-based reason codes were chosen over SHAP for committee readability. SHAP can be added through the registry's explain function.
- The Agent and Snowflake Intelligence DDL may differ by account release. If a statement errors, create the agent in Snowsight with the same tools.

## Production roadmap
1. Replace SRC with Openflow or Kafka CDC from core and LOS, and with S3 + Snowpipe for files.
2. Deploy with dbt or Snowflake CLI and Git integration, with CI/CD, data quality (DMFs) and alerts.
3. Add the Feature Store, scheduled retraining, ML Observability, and champion/challenger models.
4. Add a Horizon catalogue, automatic classification (`SYSTEM$CLASSIFY`), and access-history reporting for audit.
5. Build a credit workflow integration that writes back the decision, memo version and override reasons.
6. Control cost with resource monitors, per-workload warehouses, and a Cortex usage budget.
