-- Copyright 2026. SPDX-License-Identifier: Apache-2.0
-- ============================================================
-- SME Business Banking Customer 360 - Malaysian Bank POC
-- ============================================================
-- Run top-to-bottom as a user with ACCOUNTADMIN.
-- EDITION: Standard-compatible. Governance uses secure views + role-aware masking UDFs.
--          (Enterprise version with tag-based masking / row access policies: setup_enterprise.sql)
-- Pattern follows Snowflake-Labs/sfguide-retail-banking-credit-card-and-loan-analyst.
-- Layers: SRC (simulated source systems) -> stage files -> RAW (bronze)
--         -> SILVER (clean + entity resolution) -> GOLD (C360) -> ML -> AI (Cortex)
-- LLM model used below: 'llama3.3-70b'. Alternatives: 'claude-haiku-4-5', 'claude-sonnet-4-5', 'llama3.1-70b'.

USE ROLE ACCOUNTADMIN;
ALTER SESSION SET QUERY_TAG = '{"origin":"sme_c360_poc","version":"1.0"}';
-- Allow Cortex models not hosted in the local region (e.g. AWS ap-southeast-1)
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';

-- ============================================================
-- SECTION 1: ROLES, WAREHOUSE, ACCOUNT PRIVILEGES
-- ============================================================
USE ROLE USERADMIN;
CREATE ROLE IF NOT EXISTS SME_ADMIN      COMMENT = 'POC owner: builds pipeline, sees clear data';
CREATE ROLE IF NOT EXISTS DATA_ENGINEER  COMMENT = 'Builds/operates pipelines; PII masked';
CREATE ROLE IF NOT EXISTS CREDIT_ANALYST COMMENT = 'Credit risk; full PII + bureau';
CREATE ROLE IF NOT EXISTS RM_USER        COMMENT = 'Relationship manager; own portfolio only; bureau hidden';
CREATE ROLE IF NOT EXISTS AUDITOR        COMMENT = 'Read-only audit; NRIC masked';

SET curr_user = CURRENT_USER();
GRANT ROLE SME_ADMIN      TO USER IDENTIFIER($curr_user);
GRANT ROLE DATA_ENGINEER  TO USER IDENTIFIER($curr_user);
GRANT ROLE CREDIT_ANALYST TO USER IDENTIFIER($curr_user);
GRANT ROLE RM_USER        TO USER IDENTIFIER($curr_user);
GRANT ROLE AUDITOR        TO USER IDENTIFIER($curr_user);
GRANT ROLE SME_ADMIN      TO ROLE SYSADMIN;
GRANT ROLE DATA_ENGINEER  TO ROLE SYSADMIN;
GRANT ROLE CREDIT_ANALYST TO ROLE SYSADMIN;
GRANT ROLE RM_USER        TO ROLE SYSADMIN;
GRANT ROLE AUDITOR        TO ROLE SYSADMIN;

USE ROLE ACCOUNTADMIN;
CREATE OR REPLACE WAREHOUSE SME_WH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;

GRANT CREATE DATABASE, EXECUTE TASK ON ACCOUNT TO ROLE SME_ADMIN;
GRANT CREATE SNOWFLAKE INTELLIGENCE ON ACCOUNT TO ROLE SME_ADMIN;
GRANT USAGE, OPERATE ON WAREHOUSE SME_WH TO ROLE SME_ADMIN;
GRANT USAGE ON WAREHOUSE SME_WH TO ROLE DATA_ENGINEER;
GRANT USAGE ON WAREHOUSE SME_WH TO ROLE CREDIT_ANALYST;
GRANT USAGE ON WAREHOUSE SME_WH TO ROLE RM_USER;
GRANT USAGE ON WAREHOUSE SME_WH TO ROLE AUDITOR;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE SME_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE CREDIT_ANALYST;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE RM_USER;
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE AUDITOR;

USE ROLE SME_ADMIN;
USE WAREHOUSE SME_WH;

-- ============================================================
-- SECTION 2: DATABASE, SCHEMAS, STAGE, FILE FORMATS
-- ============================================================
CREATE OR REPLACE DATABASE SME_BANK_DB COMMENT = 'SME Business Banking Customer 360 POC';
USE DATABASE SME_BANK_DB;
CREATE OR REPLACE SCHEMA SRC    COMMENT = 'Simulated source systems (core banking, LOS, CRM, CTOS, trade) - demo only';
CREATE OR REPLACE SCHEMA RAW    COMMENT = 'Bronze: as-landed data + load metadata';
CREATE OR REPLACE SCHEMA SILVER COMMENT = 'Cleansed, conformed, entity-resolved';
CREATE OR REPLACE SCHEMA GOLD   COMMENT = 'Business Banking Customer 360 + dimensional model';
CREATE OR REPLACE SCHEMA ML     COMMENT = 'Model registry, PD scores, metrics';
CREATE OR REPLACE SCHEMA AI     COMMENT = 'Cortex enrichment, memo, search, agent, app';
CREATE OR REPLACE SCHEMA GOV    COMMENT = 'Tags, masking and row access policies';

CREATE OR REPLACE FILE FORMAT RAW.CSV_FF
  TYPE = CSV PARSE_HEADER = TRUE FIELD_OPTIONALLY_ENCLOSED_BY = '"' EMPTY_FIELD_AS_NULL = TRUE COMPRESSION = AUTO
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;  -- RAW tables carry 2 extra lineage columns (_SRC_FILE, _LOADED_AT)
CREATE OR REPLACE FILE FORMAT RAW.JSON_FF TYPE = JSON STRIP_OUTER_ARRAY = TRUE COMPRESSION = AUTO;
CREATE OR REPLACE STAGE RAW.LANDING
  DIRECTORY = (ENABLE = TRUE) ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Landing zone for batch file drops (prod: external stage on S3 + Snowpipe)';

-- ============================================================
-- SECTION 3: SIMULATED SOURCE SYSTEMS (synthetic Malaysian SME data)
-- ============================================================
-- 3.1 Hidden master: latent risk drives correlated behaviour across all systems.
--     SRC.SME_MASTER is the "answer key" and is never exposed downstream.
CREATE OR REPLACE TABLE SRC.SME_MASTER AS
WITH g AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM()) AS risk,
         UNIFORM(0::FLOAT, 0.3::FLOAT, RANDOM()) AS noise
  FROM TABLE(GENERATOR(ROWCOUNT => 500))
), ref AS (
  SELECT
    ARRAY_CONSTRUCT('Maju','Jaya','Setia','Harapan','Cahaya','Bintang','Sinar','Mega','Gemilang','Permata',
                    'Timur','Nusantara','Seri','Kencana','Delima','Wawasan','Murni','Utama','Sentosa','Mutiara') AS p1,
    ARRAY_CONSTRUCT('Emas','Baru','Makmur','Indah','Perdana','Bestari','Alam','Raya','Teguh','Aman',
                    'Suria','Ria','Bakti','Sakti','Lestari','Megah','Cemerlang','Pintar','Unggul','Damai') AS p2,
    ARRAY_CONSTRUCT(
      OBJECT_CONSTRUCT('ind','Manufacturing','msic','25920','word','Engineering'),
      OBJECT_CONSTRUCT('ind','Wholesale & Retail','msic','46900','word','Trading'),
      OBJECT_CONSTRUCT('ind','Transport & Logistics','msic','49231','word','Logistics'),
      OBJECT_CONSTRUCT('ind','Food & Beverage','msic','56101','word','Foods'),
      OBJECT_CONSTRUCT('ind','Construction','msic','41002','word','Construction'),
      OBJECT_CONSTRUCT('ind','Agriculture','msic','01262','word','Agro'),
      OBJECT_CONSTRUCT('ind','Electronics','msic','26100','word','Electronics'),
      OBJECT_CONSTRUCT('ind','Hospitality','msic','55101','word','Hospitality'),
      OBJECT_CONSTRUCT('ind','Healthcare','msic','86201','word','Medical'),
      OBJECT_CONSTRUCT('ind','ICT','msic','62010','word','Technologies')) AS inds,
    ARRAY_CONSTRUCT('Selangor','WP Kuala Lumpur','Johor','Pulau Pinang','Perak','Sabah','Sarawak',
                    'Kedah','Negeri Sembilan','Melaka','Pahang','Kelantan','Terengganu') AS states
)
SELECT
  g.n, g.risk,
  (g.risk + g.noise) > 1.05                                              AS will_default,
  'CIF' || LPAD(g.n::STRING, 7, '0')                                     AS cif_no,
  'LOS' || LPAD((g.n * 3)::STRING, 6, '0')                               AS los_customer_id,
  r.inds[MOD(FLOOR(g.n / 7) + g.n, 10)]                                  AS ind_obj,
  ind_obj:ind::STRING                                                    AS industry,
  ind_obj:msic::STRING                                                   AS msic_code,
  r.p1[MOD(g.n, 20)]::STRING || ' ' || r.p2[MOD(FLOOR(g.n / 20), 20)]::STRING || ' '
    || ind_obj:word::STRING || ' Sdn Bhd'                                AS company_name,
  r.states[MOD(g.n * 11, 13)]::STRING                                    AS state,
  DATEADD(day, -UNIFORM(730, 9000, RANDOM()), CURRENT_DATE())            AS incorporation_date,
  YEAR(incorporation_date)::STRING || '01' || LPAD((100000 + g.n * 37)::STRING, 6, '0') AS ssm_new,
  LPAD((500000 + g.n * 13)::STRING, 7, '0') || '-' || CHR(65 + MOD(g.n, 26))            AS ssm_old,
  ROUND(UNIFORM(300000, 40000000, RANDOM()), -3)::NUMBER(18,0)           AS annual_turnover_myr,
  UNIFORM(5, 180, RANDOM())                                              AS employees,
  'RM' || LPAD((MOD(g.n, 12) + 1)::STRING, 2, '0')                       AS rm_id,
  GREATEST(300, LEAST(850, ROUND(820 - g.risk * 400 + UNIFORM(-60, 60, RANDOM()))))::NUMBER AS ctos_score,
  CASE WHEN g.risk > 0.8 THEN UNIFORM(1, 6, RANDOM())
       WHEN g.risk > 0.6 THEN UNIFORM(0, 2, RANDOM()) ELSE 0 END         AS ccris_arrears,
  IFF(g.risk > 0.9 AND UNIFORM(0::FLOAT, 1::FLOAT, RANDOM()) > 0.5, 1, 0) AS legal_suits,
  industry IN ('Wholesale & Retail','Food & Beverage','Hospitality','Healthcare') AS has_merchant,
  industry IN ('Manufacturing','Wholesale & Retail','Electronics','Agriculture')  AS is_trader
FROM g CROSS JOIN ref r;

-- 3.2 Core banking: customers + current accounts (with OD)
CREATE OR REPLACE TABLE SRC.CORE_CUSTOMERS AS
SELECT cif_no, company_name, ssm_new AS ssm_reg_no, industry, msic_code, state, incorporation_date,
       annual_turnover_myr, employees, rm_id
FROM SRC.SME_MASTER;

CREATE OR REPLACE TABLE SRC.CORE_ACCOUNTS AS
SELECT '8' || LPAD(n::STRING, 9, '0') AS account_no, cif_no, 'BUSINESS_CURRENT' AS product,
       ROUND(annual_turnover_myr * 0.08, -3)::NUMBER(18,0) AS od_limit_myr,
       ROUND(ROUND(annual_turnover_myr * 0.08, -3)
             * LEAST(0.99, GREATEST(0.05, 0.25 + risk * 0.6 + UNIFORM(-0.1::FLOAT, 0.1::FLOAT, RANDOM()))), 2)::NUMBER(18,2) AS od_balance_myr,
       DATEADD(day, 30, incorporation_date) AS open_date
FROM SRC.SME_MASTER;

-- 3.3 SSM (Companies Commission) registry extract: old <-> new registration numbers
CREATE OR REPLACE TABLE SRC.SSM_REGISTRY AS
SELECT ssm_new AS new_reg_no, ssm_old AS old_reg_no, UPPER(company_name) AS registered_name,
       'EXISTING' AS status, incorporation_date
FROM SRC.SME_MASTER;

-- 3.4 Loan origination system (LOS): own keys, inconsistent SSM formats and names
CREATE OR REPLACE TABLE SRC.LOS_CUSTOMERS AS
SELECT los_customer_id,
       CASE WHEN MOD(n, 10) = 3 THEN NULL
            WHEN MOD(n, 4) = 0  THEN ssm_old
            ELSE SUBSTR(ssm_new,1,4) || '-' || SUBSTR(ssm_new,5,2) || '-' || SUBSTR(ssm_new,7) END AS ssm_reg_no,
       CASE WHEN MOD(n, 10) = 3 THEN UPPER(REPLACE(REGEXP_REPLACE(company_name, 'a', '', 1, 1), 'Sdn Bhd', 'Sdn. Bhd.'))
            WHEN MOD(n, 5) = 1  THEN UPPER(company_name)
            ELSE company_name END AS company_name,
       state, annual_turnover_myr AS declared_turnover_myr, rm_id
FROM SRC.SME_MASTER
WHERE MOD(n, 25) <> 0;

CREATE OR REPLACE TABLE SRC.LOS_APPLICATIONS AS
WITH k AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS k FROM TABLE(GENERATOR(ROWCOUNT => 4)))
SELECT
  'APP' || LPAD((m.n * 10 + k.k)::STRING, 7, '0') AS application_id,
  m.los_customer_id,
  ARRAY_CONSTRUCT('Term Loan','Overdraft','Trade Line','SJPP-Guaranteed Term Loan','BNM Fund for SMEs')[MOD(m.n + k.k * 3, 5)]::STRING AS raw_product,
  IFF(raw_product = 'Trade Line' AND NOT m.is_trader, 'Term Loan', raw_product) AS product,
  ROUND(m.annual_turnover_myr * UNIFORM(0.05::FLOAT, 0.35::FLOAT, RANDOM()), -3)::NUMBER(18,0) AS amount_requested_myr,
  CASE WHEN product IN ('Overdraft','Trade Line') THEN 12
       ELSE ARRAY_CONSTRUCT(36, 60, 84)[MOD(m.n + k.k, 3)]::NUMBER END AS tenure_months,
  CASE WHEN product LIKE 'SJPP%' THEN 'SJPP Guarantee 70%'
       WHEN amount_requested_myr > 1000000 THEN 'Commercial Property'
       WHEN MOD(m.n, 3) = 0 THEN 'Fixed Deposit' ELSE 'Clean / Director Guarantee' END AS collateral_type,
  DATEADD(minute, UNIFORM(540, 1020, RANDOM()),
          DATEADD(day, -UNIFORM(20, 700, RANDOM()), CURRENT_DATE())::TIMESTAMP_NTZ) AS submitted_at,
  IFF(amount_requested_myr > 2000000, UNIFORM(12, 30, RANDOM()), UNIFORM(4, 18, RANDOM())) AS decision_days_plan,
  CASE WHEN DATEDIFF(day, submitted_at, CURRENT_TIMESTAMP()) < decision_days_plan THEN 'Pending'
       WHEN m.risk > 0.9 AND UNIFORM(0::FLOAT, 1::FLOAT, RANDOM()) < 0.7 THEN 'Declined'
       WHEN UNIFORM(0::FLOAT, 1::FLOAT, RANDOM()) < 0.08 THEN 'Declined'
       ELSE 'Approved' END AS status,
  IFF(status = 'Pending', NULL, DATEADD(day, decision_days_plan, submitted_at)) AS decision_at,
  IFF(status = 'Declined', ARRAY_CONSTRUCT('CTOS_LOW','DSCR_BELOW_1.25','INSUFFICIENT_COLLATERAL')[MOD(m.n, 3)]::STRING, NULL) AS reason_code,
  ROUND(4.5 + m.risk * 4 + UNIFORM(0::FLOAT, 0.5::FLOAT, RANDOM()), 2) AS offered_rate_pct
FROM SRC.SME_MASTER m CROSS JOIN k
WHERE k.k <= MOD(m.n * 7, 4) + 1 AND MOD(m.n, 25) <> 0;
ALTER TABLE SRC.LOS_APPLICATIONS DROP COLUMN raw_product, decision_days_plan;

CREATE OR REPLACE TABLE SRC.LOS_LOANS AS
SELECT 'LN' || SUBSTR(application_id, 4) AS loan_id, application_id, los_customer_id, product,
       DATEADD(day, 7, decision_at)::DATE AS origination_date,
       amount_requested_myr AS principal_myr, offered_rate_pct AS interest_rate_pct, tenure_months, collateral_type
FROM SRC.LOS_APPLICATIONS
WHERE status = 'Approved' AND DATEADD(day, 7, decision_at) < CURRENT_DATE();

-- 3.5 Core loan servicing: monthly repayment history (last <=12 months)
CREATE OR REPLACE TABLE SRC.CORE_REPAYMENTS AS
WITH mm AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS m FROM TABLE(GENERATOR(ROWCOUNT => 12))),
l AS (
  SELECT l.*, s.risk, s.will_default,
         LEAST(12, DATEDIFF(month, l.origination_date, CURRENT_DATE())) AS mob
  FROM SRC.LOS_LOANS l JOIN SRC.SME_MASTER s ON s.los_customer_id = l.los_customer_id
)
SELECT
  l.loan_id || '-' || LPAD(mm.m::STRING, 2, '0') AS repayment_id,
  l.loan_id,
  LAST_DAY(DATEADD(month, mm.m - l.mob - 1, CURRENT_DATE())) AS due_date,
  ROUND(l.principal_myr / l.tenure_months * (1 + l.interest_rate_pct / 100), 2)::NUMBER(18,2) AS instalment_myr,
  CASE WHEN l.will_default AND l.mob >= 4 THEN GREATEST(0, (mm.m - (l.mob - 4)) * 30)
       WHEN l.risk > 0.55 AND UNIFORM(0::FLOAT, 1::FLOAT, RANDOM()) < 0.25 THEN UNIFORM(5, 45, RANDOM())
       ELSE 0 END AS dpd,
  CASE WHEN dpd >= 30 THEN 0 WHEN dpd > 0 THEN instalment_myr * 0.5 ELSE instalment_myr END::NUMBER(18,2) AS amount_paid_myr,
  ROUND(l.principal_myr * GREATEST(0.05, 1 - mm.m / l.tenure_months), 2)::NUMBER(18,2) AS outstanding_myr
FROM l JOIN mm ON mm.m <= l.mob;

-- 3.6 CRM/KYC: directors & guarantors (shared NRICs create related-party links among riskier SMEs)
CREATE OR REPLACE TABLE SRC.DIRECTOR_MASTER AS
WITH g AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS d FROM TABLE(GENERATOR(ROWCOUNT => 1025))),
ref AS (SELECT
  ARRAY_CONSTRUCT('Ahmad','Mohd Faiz','Hafiz','Azman','Zulkifli','Kamal','Rizal','Ismail','Syed Omar','Nazri') AS mf,
  ARRAY_CONSTRUCT('Abdullah','Hassan','Ibrahim','Yusof','Rahman','Osman','Salleh','Ali','Hamid','Ismail') AS mfa,
  ARRAY_CONSTRUCT('Tan','Lim','Wong','Lee','Ng','Chan','Ong','Goh','Teh','Chong') AS cs,
  ARRAY_CONSTRUCT('Wei Ming','Mei Ling','Kah Seng','Siew Lan','Jun Hao','Pei Shan','Chee Keong','Li Ying','Boon Hock','Hui Min','Zhi Wei','Soo Fong') AS cg,
  ARRAY_CONSTRUCT('Rajesh','Suresh','Kumar','Prakash','Ganesh','Ravi','Vijay','Arun','Mogan','Siva') AS i1,
  ARRAY_CONSTRUCT('Subramaniam','Krishnan','Muthu','Raman','Nair','Pillai','Govindasamy','Maniam','Selvam','Arumugam') AS i2,
  ARRAY_CONSTRUCT('14','10','01','07','08','12','13','05') AS pb)
SELECT g.d,
  CASE MOD(g.d, 3)
    WHEN 0 THEN r.mf[MOD(g.d,10)]::STRING || ' bin ' || r.mfa[MOD(FLOOR(g.d/10),10)]::STRING
    WHEN 1 THEN r.cs[MOD(g.d,10)]::STRING || ' ' || r.cg[MOD(FLOOR(g.d/10),12)]::STRING
    ELSE r.i1[MOD(g.d,10)]::STRING || ' a/l ' || r.i2[MOD(FLOOR(g.d/10),10)]::STRING END AS full_name,
  DATEADD(day, -UNIFORM(28*365, 65*365, RANDOM()), CURRENT_DATE()) AS dob,
  TO_CHAR(dob, 'YYMMDD') || '-' || r.pb[MOD(g.d, 8)]::STRING || '-' || LPAD(MOD(g.d * 7919, 10000)::STRING, 4, '0') AS nric
FROM g CROSS JOIN ref r;

CREATE OR REPLACE TABLE SRC.CRM_DIRECTORS AS
WITH links AS (
  SELECT n, n AS d, 'Director' AS role, 60 AS pct FROM SRC.SME_MASTER
  UNION ALL
  SELECT n, IFF(risk > 0.7, 1000 + MOD(n, 25), 500 + n), IFF(risk > 0.7, 'Guarantor', 'Director'), 40 FROM SRC.SME_MASTER
)
SELECT 'KYC' || LPAD(ROW_NUMBER() OVER (ORDER BY l.n, l.d)::STRING, 7, '0') AS kyc_id,
       IFF(MOD(l.d, 2) = 0, dm.nric, REPLACE(dm.nric, '-', '')) AS nric,
       dm.full_name AS director_name, dm.dob, m.ssm_new AS ssm_reg_no, l.role, l.pct AS shareholding_pct
FROM links l
JOIN SRC.SME_MASTER m ON m.n = l.n
JOIN SRC.DIRECTOR_MASTER dm ON dm.d = l.d;

-- 3.7 Credit bureau (CTOS/CCRIS) pulls as nested JSON
CREATE OR REPLACE TABLE SRC.BUREAU_FEED AS
SELECT OBJECT_CONSTRUCT(
  'report_id', 'CTOS-' || LPAD(n::STRING, 8, '0'),
  'bureau', 'CTOS', 'subject_type', 'COMPANY', 'ssm_reg_no', ssm_new,
  'pull_date', DATEADD(day, -UNIFORM(1, 60, RANDOM()), CURRENT_DATE())::STRING,
  'score', ctos_score,
  'ccris', OBJECT_CONSTRUCT('arrears_12m', ccris_arrears,
                            'facilities_other_banks', UNIFORM(0, 5, RANDOM()),
                            'special_attention_account', ccris_arrears >= 3),
  'litigation', OBJECT_CONSTRUCT('cases', legal_suits)) AS payload
FROM SRC.SME_MASTER;

-- 3.8 CRM: RM call notes (English with Malay phrases)
CREATE OR REPLACE TABLE SRC.CRM_RM_NOTES AS
WITH k AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS k FROM TABLE(GENERATOR(ROWCOUNT => 2))),
ref AS (SELECT
  ARRAY_CONSTRUCT(
    'Visited {c}. Owner said cash flow is tight, "bisnes agak perlahan" since key buyer delayed payments 60+ days. Asked for OD limit increase. Stock piling up in warehouse.',
    'Call with director of {c}: considering restructuring of term loan, sales down about 30% YoY. Supplier has cut credit terms. Recommend close monitoring.',
    'Collection call: {c} missed instalment again, promised to settle "minggu depan". Branch reports staff salaries paid late.',
    'Met finance manager of {c}. Lost a major contract with a GLC client, planning to downsize. Director also linked to another company facing legal action.') AS neg,
  ARRAY_CONSTRUCT(
    '{c} performing well with new export orders to Singapore and Vietnam. Interested in a trade line / LC facility to support growth.',
    'Quarterly review with {c}: revenue up, strong DuitNow collections. Asked about FX hedging and a bank guarantee for a tender.',
    'Owner of {c} plans a second outlet, "permintaan tinggi". Good candidate for SJPP-guaranteed term loan and DuitNow QR terminals.',
    'Courtesy visit to {c}. Stable operations, repayments on time. Cross-sell potential: payroll and cash management.',
    'Routine call with {c}. No major issues; awaiting audited accounts for FY2025.') AS pos)
SELECT 'NOTE' || LPAD((m.n * 10 + k.k)::STRING, 7, '0') AS note_id, m.cif_no, m.rm_id,
       DATEADD(day, -UNIFORM(1, 180, RANDOM()), CURRENT_DATE()) AS note_date,
       REPLACE(IFF(m.risk + UNIFORM(-0.15::FLOAT, 0.15::FLOAT, RANDOM()) > 0.65,
                   r.neg[MOD(m.n + k.k, 4)], r.pos[MOD(m.n + k.k, 5)])::STRING, '{c}', m.company_name) AS note_text
FROM SRC.SME_MASTER m CROSS JOIN k CROSS JOIN ref r
WHERE k.k <= 1 + MOD(m.n, 2);

-- 3.9 Trade finance documents (LC / commercial invoice text)
CREATE OR REPLACE TABLE SRC.TF_DOCUMENTS AS
WITH k AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS k FROM TABLE(GENERATOR(ROWCOUNT => 2))),
ref AS (SELECT
  ARRAY_CONSTRUCT('Shenzhen Huaxin Trading Co Ltd','Singapore Tech Components Pte Ltd','PT Sumber Makmur Jakarta',
                  'Rotterdam Agri Imports BV','Osaka Precision Parts KK','Dubai Gulf Distributors LLC') AS cps,
  ARRAY_CONSTRUCT('USD','SGD','CNY','USD','JPY','USD') AS ccys,
  ARRAY_CONSTRUCT('FOB','CIF','CFR','EXW') AS incs)
SELECT
  'TF' || LPAD((m.n * 10 + k.k)::STRING, 7, '0') AS doc_id,
  m.ssm_new AS applicant_ssm,
  IFF(MOD(m.n + k.k, 2) = 0, 'LETTER_OF_CREDIT', 'COMMERCIAL_INVOICE') AS doc_type,
  DATEADD(day, -UNIFORM(5, 300, RANDOM()), CURRENT_DATE()) AS doc_date,
  r.cps[MOD(m.n + k.k, 6)]::STRING AS cp,
  r.ccys[MOD(m.n + k.k, 6)]::STRING AS ccy,
  ROUND(m.annual_turnover_myr * UNIFORM(0.01::FLOAT, 0.05::FLOAT, RANDOM()) / 4.4, 2) AS amt,
  CASE m.industry WHEN 'Electronics' THEN 'Printed circuit board assemblies, 12,000 units'
                  WHEN 'Agriculture' THEN 'Crude palm kernel oil, 500 MT'
                  WHEN 'Manufacturing' THEN 'Precision stamped metal parts, 40 pallets'
                  ELSE 'Household consumer goods, 2 x 40ft containers' END AS goods,
  (m.risk > 0.6 AND UNIFORM(0::FLOAT, 1::FLOAT, RANDOM()) < 0.6) AS disc,
  IFF(doc_type = 'LETTER_OF_CREDIT',
    'IRREVOCABLE DOCUMENTARY CREDIT No. ' || doc_id || '. Issuing bank: Demo Bank Malaysia Berhad. Applicant: '
      || m.company_name || ', ' || m.state || ', Malaysia. Beneficiary: ' || cp || '. Currency and amount: ' || ccy || ' '
      || TRIM(TO_CHAR(amt, '999,999,990.00')) || '. Incoterm: ' || r.incs[MOD(m.n, 4)]::STRING || ' Port Klang. Latest shipment date: '
      || TO_CHAR(DATEADD(day, 30, doc_date), 'DD-MON-YYYY') || '. Expiry date: ' || TO_CHAR(DATEADD(day, 45, doc_date), 'DD-MON-YYYY')
      || '. Goods: ' || goods || '. Documents required: commercial invoice, packing list, full set clean on board bills of lading, certificate of origin.'
      || IFF(disc, ' EXAMINER REMARKS: invoice value exceeds credit amount by 6%; bill of lading dated 5 days after latest shipment date. Documents discrepant.', ''),
    'COMMERCIAL INVOICE No. INV-' || doc_id || '. Seller: ' || m.company_name || ', ' || m.state || ', Malaysia. Buyer: ' || cp
      || '. Total: ' || ccy || ' ' || TRIM(TO_CHAR(amt, '999,999,990.00')) || '. Terms: ' || r.incs[MOD(m.n, 4)]::STRING
      || ' Port Klang, payment 60 days from B/L date. Goods: ' || goods || '.'
      || IFF(disc, ' NOTE: buyer requested extension of payment terms to 150 days; two prior invoices remain overdue.', '')
  ) AS doc_text
FROM SRC.SME_MASTER m CROSS JOIN k CROSS JOIN ref r
WHERE m.is_trader AND MOD(m.n, 3) = 0;
ALTER TABLE SRC.TF_DOCUMENTS DROP COLUMN cp, ccy, amt, goods, disc;

-- ============================================================
-- SECTION 4: BATCH INGESTION (files -> stage -> COPY INTO RAW)
-- ============================================================
-- Why batch: LOS, core EOD extracts, SSM and bureau pulls arrive as daily files.
-- Prod: source drops to S3 -> external stage -> Snowpipe AUTO_INGEST (event-driven, serverless).
-- 4.1 Simulate source file drops (unload each source to the landing stage)
COPY INTO @RAW.LANDING/core/customers/     FROM SRC.CORE_CUSTOMERS   FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' COMPRESSION = GZIP) HEADER = TRUE OVERWRITE = TRUE;
COPY INTO @RAW.LANDING/core/accounts/      FROM SRC.CORE_ACCOUNTS    FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' COMPRESSION = GZIP) HEADER = TRUE OVERWRITE = TRUE;
COPY INTO @RAW.LANDING/core/repayments/    FROM SRC.CORE_REPAYMENTS  FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' COMPRESSION = GZIP) HEADER = TRUE OVERWRITE = TRUE;
COPY INTO @RAW.LANDING/los/customers/      FROM SRC.LOS_CUSTOMERS    FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' COMPRESSION = GZIP) HEADER = TRUE OVERWRITE = TRUE;
COPY INTO @RAW.LANDING/los/applications/   FROM SRC.LOS_APPLICATIONS FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' COMPRESSION = GZIP) HEADER = TRUE OVERWRITE = TRUE;
COPY INTO @RAW.LANDING/los/loans/          FROM SRC.LOS_LOANS        FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' COMPRESSION = GZIP) HEADER = TRUE OVERWRITE = TRUE;
COPY INTO @RAW.LANDING/ssm/registry/       FROM SRC.SSM_REGISTRY     FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' COMPRESSION = GZIP) HEADER = TRUE OVERWRITE = TRUE;
COPY INTO @RAW.LANDING/crm/directors/      FROM SRC.CRM_DIRECTORS    FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' COMPRESSION = GZIP) HEADER = TRUE OVERWRITE = TRUE;
COPY INTO @RAW.LANDING/bureau/             FROM (SELECT payload FROM SRC.BUREAU_FEED)                 FILE_FORMAT = (TYPE = JSON COMPRESSION = GZIP) OVERWRITE = TRUE;
COPY INTO @RAW.LANDING/crm/rm_notes/       FROM (SELECT OBJECT_CONSTRUCT(*) FROM SRC.CRM_RM_NOTES)    FILE_FORMAT = (TYPE = JSON COMPRESSION = GZIP) OVERWRITE = TRUE;
COPY INTO @RAW.LANDING/trade/documents/    FROM (SELECT OBJECT_CONSTRUCT(*) FROM SRC.TF_DOCUMENTS)    FILE_FORMAT = (TYPE = JSON COMPRESSION = GZIP) OVERWRITE = TRUE;

-- 4.2 Reusable batch loader: schema from source contract + load lineage columns
CREATE OR REPLACE PROCEDURE RAW.INGEST_CSV(TBL STRING, PATH STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  LET s1 STRING := 'CREATE OR REPLACE TABLE SME_BANK_DB.RAW.' || TBL || ' LIKE SME_BANK_DB.SRC.' || TBL;
  EXECUTE IMMEDIATE :s1;
  LET s2 STRING := 'ALTER TABLE SME_BANK_DB.RAW.' || TBL || ' ADD COLUMN _SRC_FILE STRING, _LOADED_AT TIMESTAMP_LTZ';
  EXECUTE IMMEDIATE :s2;
  LET s3 STRING := 'COPY INTO SME_BANK_DB.RAW.' || TBL || ' FROM @SME_BANK_DB.RAW.LANDING/' || PATH ||
                   ' FILE_FORMAT = (FORMAT_NAME = SME_BANK_DB.RAW.CSV_FF) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE' ||
                   ' INCLUDE_METADATA = (_SRC_FILE = METADATA$FILENAME, _LOADED_AT = METADATA$START_SCAN_TIME)' ||
                   ' ON_ERROR = CONTINUE';
  EXECUTE IMMEDIATE :s3;
  RETURN TBL || ' loaded';
END;
$$;

CALL RAW.INGEST_CSV('CORE_CUSTOMERS',   'core/customers/');
CALL RAW.INGEST_CSV('CORE_ACCOUNTS',    'core/accounts/');
CALL RAW.INGEST_CSV('CORE_REPAYMENTS',  'core/repayments/');
CALL RAW.INGEST_CSV('LOS_CUSTOMERS',    'los/customers/');
CALL RAW.INGEST_CSV('LOS_APPLICATIONS', 'los/applications/');
CALL RAW.INGEST_CSV('LOS_LOANS',        'los/loans/');
CALL RAW.INGEST_CSV('SSM_REGISTRY',     'ssm/registry/');
CALL RAW.INGEST_CSV('CRM_DIRECTORS',    'crm/directors/');

-- 4.3 Semi-structured sources land as VARIANT (schema-on-read)
CREATE OR REPLACE TABLE RAW.BUREAU_RAW   (PAYLOAD VARIANT, _SRC_FILE STRING, _LOADED_AT TIMESTAMP_LTZ);
CREATE OR REPLACE TABLE RAW.RM_NOTES_RAW (PAYLOAD VARIANT, _SRC_FILE STRING, _LOADED_AT TIMESTAMP_LTZ);
CREATE OR REPLACE TABLE RAW.TF_DOCS_RAW  (PAYLOAD VARIANT, _SRC_FILE STRING, _LOADED_AT TIMESTAMP_LTZ);
COPY INTO RAW.BUREAU_RAW   FROM (SELECT $1, METADATA$FILENAME, CURRENT_TIMESTAMP() FROM @RAW.LANDING/bureau/)          FILE_FORMAT = (FORMAT_NAME = RAW.JSON_FF) ON_ERROR = CONTINUE;
COPY INTO RAW.RM_NOTES_RAW FROM (SELECT $1, METADATA$FILENAME, CURRENT_TIMESTAMP() FROM @RAW.LANDING/crm/rm_notes/)    FILE_FORMAT = (FORMAT_NAME = RAW.JSON_FF) ON_ERROR = CONTINUE;
COPY INTO RAW.TF_DOCS_RAW  FROM (SELECT $1, METADATA$FILENAME, CURRENT_TIMESTAMP() FROM @RAW.LANDING/trade/documents/) FILE_FORMAT = (FORMAT_NAME = RAW.JSON_FF) ON_ERROR = CONTINUE;

-- 4.4 Production pattern (reference only):
-- CREATE STAGE RAW.S3_LANDING URL='s3://bank-landing/sme/' STORAGE_INTEGRATION = S3_INT FILE_FORMAT = RAW.CSV_FF;
-- CREATE PIPE RAW.PIPE_LOS_APPLICATIONS AUTO_INGEST = TRUE AS
--   COPY INTO RAW.LOS_APPLICATIONS FROM @RAW.S3_LANDING/los/applications/
--   MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
--   INCLUDE_METADATA = (_SRC_FILE = METADATA$FILENAME, _LOADED_AT = METADATA$START_SCAN_TIME);

-- ============================================================
-- SECTION 5: NEAR-REAL-TIME INGESTION (transaction banking + merchant acquiring)
-- ============================================================
-- Why streaming: payment events (DuitNow, IBG, RENTAS, JomPAY, QR/card acquiring) are continuous and
-- power early-warning signals (inflow drop). Demo: simulator proc + Stream + Task + Dynamic Table.
-- Prod: payment switch -> Kafka -> Snowflake Kafka Connector (Snowpipe Streaming) or Openflow; seconds latency.
CREATE OR REPLACE TABLE RAW.TXN_EVENTS_RAW (
  PAYLOAD VARIANT, _INGESTED_AT TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(), _CHANNEL STRING);
CREATE OR REPLACE STREAM RAW.TXN_EVENTS_STREAM ON TABLE RAW.TXN_EVENTS_RAW APPEND_ONLY = TRUE;

CREATE OR REPLACE TABLE SILVER.TXN_EVENTS (
  EVENT_ID STRING, EVENT_TS TIMESTAMP_NTZ, ACCOUNT_NO STRING, CHANNEL STRING, DIRECTION STRING,
  AMOUNT_MYR NUMBER(18,2), COUNTERPARTY STRING, SOURCE_SYSTEM STRING, INGESTED_AT TIMESTAMP_LTZ);

-- 5.1 Backfill 180 days of history (as if replayed from the event log)
CREATE OR REPLACE TEMPORARY TABLE SRC.TMP_TXN_BASE AS
SELECT m.n, m.has_merchant, a.account_no, d.days_ago,
       m.annual_turnover_myr / 365 *
       CASE WHEN m.will_default AND d.days_ago <= 90 THEN 0.45 + 0.55 * d.days_ago / 90
            WHEN m.risk > 0.6 AND d.days_ago <= 90 THEN 0.85 ELSE 1 END AS base_amt
FROM SRC.SME_MASTER m
JOIN SRC.CORE_ACCOUNTS a ON a.cif_no = m.cif_no
CROSS JOIN (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS days_ago FROM TABLE(GENERATOR(ROWCOUNT => 180))) d;

INSERT INTO RAW.TXN_EVENTS_RAW (PAYLOAD, _CHANNEL)
SELECT OBJECT_CONSTRUCT('event_id', UUID_STRING(),
         'event_ts', DATEADD(minute, UNIFORM(480, 1080, RANDOM()), DATEADD(day, -days_ago, CURRENT_DATE())::TIMESTAMP_NTZ)::STRING,
         'account_no', account_no,
         'channel', ARRAY_CONSTRUCT('DUITNOW','IBG','RENTAS','JOMPAY')[UNIFORM(0, 3, RANDOM())]::STRING,
         'direction', 'CR', 'amount_myr', ROUND(base_amt * UNIFORM(0.6::FLOAT, 1.4::FLOAT, RANDOM()), 2),
         'counterparty', 'BUYER-' || UNIFORM(1, 300, RANDOM())::STRING, 'source_system', 'PAYMENT_SWITCH'), 'BACKFILL'
FROM SRC.TMP_TXN_BASE
UNION ALL
SELECT OBJECT_CONSTRUCT('event_id', UUID_STRING(),
         'event_ts', DATEADD(minute, UNIFORM(480, 1080, RANDOM()), DATEADD(day, -days_ago, CURRENT_DATE())::TIMESTAMP_NTZ)::STRING,
         'account_no', account_no,
         'channel', ARRAY_CONSTRUCT('IBG','RENTAS','FPX')[UNIFORM(0, 2, RANDOM())]::STRING,
         'direction', 'DR', 'amount_myr', ROUND(base_amt * 0.92 * UNIFORM(0.6::FLOAT, 1.4::FLOAT, RANDOM()), 2),
         'counterparty', 'SUPPLIER-' || UNIFORM(1, 300, RANDOM())::STRING, 'source_system', 'PAYMENT_SWITCH'), 'BACKFILL'
FROM SRC.TMP_TXN_BASE
UNION ALL
SELECT OBJECT_CONSTRUCT('event_id', UUID_STRING(),
         'event_ts', DATEADD(minute, UNIFORM(600, 1320, RANDOM()), DATEADD(day, -days_ago, CURRENT_DATE())::TIMESTAMP_NTZ)::STRING,
         'account_no', account_no,
         'channel', IFF(UNIFORM(0, 1, RANDOM()) = 0, 'DUITNOW_QR', 'CARD_ACQUIRING'),
         'direction', 'CR', 'amount_myr', ROUND(base_amt * 0.4 * UNIFORM(0.5::FLOAT, 1.5::FLOAT, RANDOM()), 2),
         'counterparty', 'RETAIL_CUSTOMERS', 'source_system', 'MERCHANT_ACQUIRING'), 'BACKFILL'
FROM SRC.TMP_TXN_BASE WHERE has_merchant;

-- 5.2 Live event simulator (stands in for Snowpipe Streaming producer)
CREATE OR REPLACE PROCEDURE RAW.SIMULATE_TXN_FEED(N_EVENTS NUMBER)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  INSERT INTO SME_BANK_DB.RAW.TXN_EVENTS_RAW (PAYLOAD, _CHANNEL)
  SELECT OBJECT_CONSTRUCT(
           'event_id', UUID_STRING(),
           'event_ts', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ::STRING,
           'account_no', a.ACCOUNT_NO,
           'channel', IFF(m.HAS_MERCHANT AND g.u < 0.4, 'DUITNOW_QR',
                          ARRAY_CONSTRUCT('DUITNOW','IBG','RENTAS','JOMPAY','FPX')[UNIFORM(0, 4, RANDOM())]::STRING),
           'direction', IFF(g.u < 0.6, 'CR', 'DR'),
           'amount_myr', ROUND(m.ANNUAL_TURNOVER_MYR / 365 * UNIFORM(0.1::FLOAT, 0.8::FLOAT, RANDOM()) * IFF(m.WILL_DEFAULT, 0.5, 1), 2),
           'counterparty', 'CP-' || UNIFORM(1, 500, RANDOM())::STRING,
           'source_system', IFF(m.HAS_MERCHANT AND g.u < 0.4, 'MERCHANT_ACQUIRING', 'PAYMENT_SWITCH')),
         'SNOWPIPE_STREAMING_SIM'
  FROM (SELECT UNIFORM(1, 500, RANDOM()) AS pick, UNIFORM(0::FLOAT, 1::FLOAT, RANDOM()) AS u
        FROM TABLE(GENERATOR(ROWCOUNT => 5000))) g
  JOIN SME_BANK_DB.SRC.SME_MASTER m ON m.N = g.pick
  JOIN SME_BANK_DB.SRC.CORE_ACCOUNTS a ON a.CIF_NO = m.CIF_NO
  QUALIFY ROW_NUMBER() OVER (ORDER BY g.u) <= :N_EVENTS;
  RETURN 'Simulated ' || N_EVENTS || ' payment events';
END;
$$;

-- 5.3 Incremental CDC: stream -> SILVER (only new rows processed)
CREATE OR REPLACE PROCEDURE SILVER.LOAD_TXN_EVENTS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  INSERT INTO SME_BANK_DB.SILVER.TXN_EVENTS
  SELECT PAYLOAD:event_id::STRING, TRY_TO_TIMESTAMP_NTZ(PAYLOAD:event_ts::STRING), PAYLOAD:account_no::STRING,
         PAYLOAD:channel::STRING, PAYLOAD:direction::STRING, PAYLOAD:amount_myr::NUMBER(18,2),
         PAYLOAD:counterparty::STRING, PAYLOAD:source_system::STRING, _INGESTED_AT
  FROM SME_BANK_DB.RAW.TXN_EVENTS_STREAM
  WHERE METADATA$ACTION = 'INSERT';
  RETURN 'Loaded ' || SQLROWCOUNT || ' events';
END;
$$;
CALL SILVER.LOAD_TXN_EVENTS();

CREATE OR REPLACE TASK RAW.TASK_SIMULATE_TXN_FEED
  WAREHOUSE = SME_WH SCHEDULE = '1 MINUTE'
  AS CALL SME_BANK_DB.RAW.SIMULATE_TXN_FEED(200);
CREATE OR REPLACE TASK SILVER.TASK_TXN_STREAM_TO_SILVER
  WAREHOUSE = SME_WH SCHEDULE = '1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('SME_BANK_DB.RAW.TXN_EVENTS_STREAM')
  AS CALL SME_BANK_DB.SILVER.LOAD_TXN_EVENTS();

-- ============================================================
-- SECTION 6: SILVER - CLEANSING + ENTITY RESOLUTION
-- ============================================================
-- 6.1 Normalisation UDFs
CREATE OR REPLACE FUNCTION SILVER.NORM_NAME(S STRING) RETURNS STRING AS
$$ TRIM(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(UPPER(S), 'SDN[.]? *BHD[.]?|BERHAD|[(]M[)]', ''), '[^A-Z0-9 ]', ''), ' +', ' ')) $$;
CREATE OR REPLACE FUNCTION SILVER.NORM_SSM(S STRING) RETURNS STRING AS
$$ CASE WHEN S IS NULL OR TRIM(S) = '' THEN NULL
        WHEN LENGTH(REGEXP_REPLACE(S, '[^0-9]', '')) = 12 THEN REGEXP_REPLACE(S, '[^0-9]', '')
        ELSE UPPER(REGEXP_REPLACE(S, '[^0-9A-Za-z]', '')) END $$;
CREATE OR REPLACE FUNCTION SILVER.NORM_NRIC(S STRING) RETURNS STRING AS
$$ REGEXP_REPLACE(S, '[^0-9]', '') $$;

-- 6.2 Conformed source tables (latest record per key)
CREATE OR REPLACE TABLE SILVER.CORE_CUSTOMERS AS
SELECT CIF_NO, TRIM(COMPANY_NAME) AS COMPANY_NAME, SILVER.NORM_NAME(COMPANY_NAME) AS NAME_NORM,
       SILVER.NORM_SSM(SSM_REG_NO) AS SSM_NORM, INDUSTRY, MSIC_CODE, STATE, INCORPORATION_DATE,
       ANNUAL_TURNOVER_MYR, EMPLOYEES, RM_ID
FROM RAW.CORE_CUSTOMERS
QUALIFY ROW_NUMBER() OVER (PARTITION BY CIF_NO ORDER BY _LOADED_AT DESC) = 1;

CREATE OR REPLACE TABLE SILVER.LOS_CUSTOMERS AS
SELECT LOS_CUSTOMER_ID, SILVER.NORM_SSM(SSM_REG_NO) AS SSM_NORM, SILVER.NORM_NAME(COMPANY_NAME) AS NAME_NORM,
       COMPANY_NAME AS COMPANY_NAME_RAW, STATE, DECLARED_TURNOVER_MYR, RM_ID
FROM RAW.LOS_CUSTOMERS
QUALIFY ROW_NUMBER() OVER (PARTITION BY LOS_CUSTOMER_ID ORDER BY _LOADED_AT DESC) = 1;

CREATE OR REPLACE TABLE SILVER.SSM_REGISTRY AS
SELECT SILVER.NORM_SSM(NEW_REG_NO) AS NEW_SSM_NORM, SILVER.NORM_SSM(OLD_REG_NO) AS OLD_SSM_NORM, REGISTERED_NAME, STATUS
FROM RAW.SSM_REGISTRY;

-- 6.3 Entity resolution -> golden CUSTOMER_ID
--   Rule 1 SSM exact (new format)  Rule 2 old SSM -> new via SSM registry  Rule 3 fuzzy name (Jaro-Winkler >= 92) within same state
CREATE OR REPLACE TABLE SILVER.ENTITY_XREF AS
WITH golden AS (
  SELECT CIF_NO, SSM_NORM, NAME_NORM, STATE,
         'SME' || LPAD(ROW_NUMBER() OVER (ORDER BY SSM_NORM)::STRING, 6, '0') AS CUSTOMER_ID
  FROM SILVER.CORE_CUSTOMERS
), los_exact AS (
  SELECT l.LOS_CUSTOMER_ID, g.CUSTOMER_ID, 'SSM_EXACT' AS MATCH_RULE, 100 AS MATCH_SCORE
  FROM SILVER.LOS_CUSTOMERS l JOIN golden g ON g.SSM_NORM = l.SSM_NORM
), los_old AS (
  SELECT l.LOS_CUSTOMER_ID, g.CUSTOMER_ID, 'SSM_OLD_TO_NEW' AS MATCH_RULE, 100 AS MATCH_SCORE
  FROM SILVER.LOS_CUSTOMERS l
  JOIN SILVER.SSM_REGISTRY r ON r.OLD_SSM_NORM = l.SSM_NORM
  JOIN golden g ON g.SSM_NORM = r.NEW_SSM_NORM
), los_fuzzy AS (
  SELECT l.LOS_CUSTOMER_ID, g.CUSTOMER_ID, 'FUZZY_NAME_STATE' AS MATCH_RULE,
         JAROWINKLER_SIMILARITY(l.NAME_NORM, g.NAME_NORM) AS MATCH_SCORE
  FROM SILVER.LOS_CUSTOMERS l JOIN golden g ON g.STATE = l.STATE
  WHERE l.SSM_NORM IS NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY l.LOS_CUSTOMER_ID ORDER BY MATCH_SCORE DESC) = 1 AND MATCH_SCORE >= 92
)
SELECT 'CORE' AS SOURCE_SYSTEM, CIF_NO AS SOURCE_ID, CUSTOMER_ID, 'GOLDEN_SOURCE' AS MATCH_RULE, 100 AS MATCH_SCORE FROM golden
UNION ALL SELECT 'LOS', LOS_CUSTOMER_ID, CUSTOMER_ID, MATCH_RULE, MATCH_SCORE FROM los_exact
UNION ALL SELECT 'LOS', LOS_CUSTOMER_ID, CUSTOMER_ID, MATCH_RULE, MATCH_SCORE FROM los_old
UNION ALL SELECT 'LOS', LOS_CUSTOMER_ID, CUSTOMER_ID, MATCH_RULE, MATCH_SCORE FROM los_fuzzy;

-- Data-steward queue: records that could not be resolved automatically
CREATE OR REPLACE VIEW SILVER.V_ER_UNRESOLVED AS
SELECT l.* FROM SILVER.LOS_CUSTOMERS l
LEFT JOIN SILVER.ENTITY_XREF x ON x.SOURCE_SYSTEM = 'LOS' AND x.SOURCE_ID = l.LOS_CUSTOMER_ID
WHERE x.CUSTOMER_ID IS NULL;

-- 6.4 Directors/guarantors (MyKad normalised) + related-party graph
CREATE OR REPLACE TABLE SILVER.DIRECTORS AS
SELECT d.KYC_ID, SILVER.NORM_NRIC(d.NRIC) AS NRIC, d.DIRECTOR_NAME, d.DOB, x.CUSTOMER_ID, d.ROLE, d.SHAREHOLDING_PCT
FROM RAW.CRM_DIRECTORS d
JOIN SILVER.CORE_CUSTOMERS c ON c.SSM_NORM = SILVER.NORM_SSM(d.SSM_REG_NO)
JOIN SILVER.ENTITY_XREF x ON x.SOURCE_SYSTEM = 'CORE' AND x.SOURCE_ID = c.CIF_NO;

CREATE OR REPLACE TABLE SILVER.RELATED_PARTY_LINKS AS
SELECT a.CUSTOMER_ID, b.CUSTOMER_ID AS RELATED_CUSTOMER_ID, a.NRIC AS SHARED_NRIC,
       a.DIRECTOR_NAME AS SHARED_PARTY_NAME, 'SHARED_DIRECTOR_OR_GUARANTOR' AS LINK_TYPE
FROM SILVER.DIRECTORS a
JOIN SILVER.DIRECTORS b ON a.NRIC = b.NRIC AND a.CUSTOMER_ID <> b.CUSTOMER_ID;

-- 6.5 Accounts, lending, bureau, notes, trade docs
CREATE OR REPLACE TABLE SILVER.ACCOUNTS AS
SELECT a.ACCOUNT_NO, x.CUSTOMER_ID, a.PRODUCT, a.OD_LIMIT_MYR, a.OD_BALANCE_MYR, a.OPEN_DATE
FROM RAW.CORE_ACCOUNTS a
JOIN SILVER.ENTITY_XREF x ON x.SOURCE_SYSTEM = 'CORE' AND x.SOURCE_ID = a.CIF_NO;

CREATE OR REPLACE TABLE SILVER.LOAN_APPLICATIONS AS
SELECT a.APPLICATION_ID, x.CUSTOMER_ID, a.PRODUCT, a.AMOUNT_REQUESTED_MYR, a.TENURE_MONTHS, a.COLLATERAL_TYPE,
       a.SUBMITTED_AT, a.DECISION_AT, a.STATUS, a.REASON_CODE, a.OFFERED_RATE_PCT,
       DATEDIFF(day, a.SUBMITTED_AT, a.DECISION_AT) AS DECISION_DAYS
FROM RAW.LOS_APPLICATIONS a
JOIN SILVER.ENTITY_XREF x ON x.SOURCE_SYSTEM = 'LOS' AND x.SOURCE_ID = a.LOS_CUSTOMER_ID;

CREATE OR REPLACE TABLE SILVER.LOANS AS
SELECT l.LOAN_ID, x.CUSTOMER_ID, l.APPLICATION_ID, l.PRODUCT, l.ORIGINATION_DATE, l.PRINCIPAL_MYR,
       l.INTEREST_RATE_PCT, l.TENURE_MONTHS, l.COLLATERAL_TYPE
FROM RAW.LOS_LOANS l
JOIN SILVER.ENTITY_XREF x ON x.SOURCE_SYSTEM = 'LOS' AND x.SOURCE_ID = l.LOS_CUSTOMER_ID;

CREATE OR REPLACE TABLE SILVER.REPAYMENTS AS
SELECT REPAYMENT_ID, LOAN_ID, DUE_DATE, INSTALMENT_MYR, AMOUNT_PAID_MYR, DPD, OUTSTANDING_MYR
FROM RAW.CORE_REPAYMENTS;

CREATE OR REPLACE TABLE SILVER.BUREAU AS
SELECT x.CUSTOMER_ID, b.PAYLOAD:report_id::STRING AS REPORT_ID, b.PAYLOAD:pull_date::DATE AS PULL_DATE,
       b.PAYLOAD:score::NUMBER AS CTOS_SCORE,
       b.PAYLOAD:ccris.arrears_12m::NUMBER AS CCRIS_ARREARS_12M,
       b.PAYLOAD:ccris.facilities_other_banks::NUMBER AS FACILITIES_OTHER_BANKS,
       b.PAYLOAD:ccris.special_attention_account::BOOLEAN AS CCRIS_SPECIAL_ATTENTION,
       b.PAYLOAD:litigation.cases::NUMBER AS LEGAL_CASES
FROM RAW.BUREAU_RAW b
JOIN SILVER.CORE_CUSTOMERS c ON c.SSM_NORM = SILVER.NORM_SSM(b.PAYLOAD:ssm_reg_no::STRING)
JOIN SILVER.ENTITY_XREF x ON x.SOURCE_SYSTEM = 'CORE' AND x.SOURCE_ID = c.CIF_NO
QUALIFY ROW_NUMBER() OVER (PARTITION BY x.CUSTOMER_ID ORDER BY PULL_DATE DESC) = 1;

CREATE OR REPLACE TABLE SILVER.RM_NOTES AS
SELECT n.PAYLOAD:NOTE_ID::STRING AS NOTE_ID, x.CUSTOMER_ID, n.PAYLOAD:RM_ID::STRING AS RM_ID,
       n.PAYLOAD:NOTE_DATE::DATE AS NOTE_DATE, n.PAYLOAD:NOTE_TEXT::STRING AS NOTE_TEXT
FROM RAW.RM_NOTES_RAW n
JOIN SILVER.ENTITY_XREF x ON x.SOURCE_SYSTEM = 'CORE' AND x.SOURCE_ID = n.PAYLOAD:CIF_NO::STRING;

CREATE OR REPLACE TABLE SILVER.TF_DOCS AS
SELECT t.PAYLOAD:DOC_ID::STRING AS DOC_ID, x.CUSTOMER_ID, t.PAYLOAD:DOC_TYPE::STRING AS DOC_TYPE,
       t.PAYLOAD:DOC_DATE::DATE AS DOC_DATE, t.PAYLOAD:DOC_TEXT::STRING AS DOC_TEXT
FROM RAW.TF_DOCS_RAW t
JOIN SILVER.CORE_CUSTOMERS c ON c.SSM_NORM = SILVER.NORM_SSM(t.PAYLOAD:APPLICANT_SSM::STRING)
JOIN SILVER.ENTITY_XREF x ON x.SOURCE_SYSTEM = 'CORE' AND x.SOURCE_ID = c.CIF_NO;

-- ============================================================
-- SECTION 7: CORTEX ENRICHMENT OF UNSTRUCTURED DATA
-- ============================================================
-- 7.1 RM notes -> sentiment + risk cue
--     Cortex SENTIMENT / CLASSIFY_TEXT are not available on trial accounts, so one COMPLETE call returns both as JSON.
--     A keyword rule fills in any value the LLM does not return (and is the full fallback if COMPLETE is blocked:
--     replace the SNOWFLAKE.CORTEX.COMPLETE(...) expression below with NULL::STRING).
CREATE OR REPLACE TABLE AI.RM_NOTE_INSIGHTS AS
WITH r AS (
  SELECT NOTE_ID, CUSTOMER_ID, RM_ID, NOTE_DATE, NOTE_TEXT,
         SNOWFLAKE.CORTEX.COMPLETE('llama3.3-70b',
           'Classify this bank relationship-manager note about an SME borrower. Return ONLY minified JSON with keys: '
           || 'sentiment (number from -1 = very negative for credit risk to 1 = very positive), '
           || 'risk_cue (exactly one of: Cash flow stress, Repayment delay, Business growth, Cross-sell opportunity, '
           || 'Legal or governance concern, Routine update). Note: ' || NOTE_TEXT) AS RESP
  FROM SILVER.RM_NOTES
), p AS (
  SELECT r.*, TRY_PARSE_JSON(REGEXP_SUBSTR(RESP, '[{].*[}]', 1, 1, 's')) AS J,
         CASE WHEN NOTE_TEXT ILIKE ANY ('%legal action%', '%lost a major contract%') THEN 'Legal or governance concern'
              WHEN NOTE_TEXT ILIKE ANY ('%missed instalment%', '%restructur%', '%minggu depan%', '%paid late%') THEN 'Repayment delay'
              WHEN NOTE_TEXT ILIKE ANY ('%cash flow%', '%perlahan%', '%stock piling%', '%cut credit terms%') THEN 'Cash flow stress'
              WHEN NOTE_TEXT ILIKE ANY ('%trade line%', '%cross-sell%', '%SJPP%', '%hedging%', '%bank guarantee%') THEN 'Cross-sell opportunity'
              WHEN NOTE_TEXT ILIKE ANY ('%revenue up%', '%export orders%', '%second outlet%', '%permintaan tinggi%') THEN 'Business growth'
              ELSE 'Routine update' END AS RULE_CUE
  FROM r
)
SELECT NOTE_ID, CUSTOMER_ID, RM_ID, NOTE_DATE, NOTE_TEXT,
       COALESCE(TRY_TO_DOUBLE(J:sentiment::STRING),
                CASE WHEN RULE_CUE IN ('Cash flow stress','Repayment delay','Legal or governance concern') THEN -0.6
                     WHEN RULE_CUE IN ('Business growth','Cross-sell opportunity') THEN 0.6 ELSE 0.1 END) AS SENTIMENT,
       IFF(J:risk_cue::STRING IN ('Cash flow stress','Repayment delay','Business growth','Cross-sell opportunity',
                                  'Legal or governance concern','Routine update'),
           J:risk_cue::STRING, RULE_CUE) AS RISK_CUE,
       IFF(J IS NULL, 'RULES', 'CORTEX_COMPLETE') AS ENRICHMENT_METHOD
FROM p;

-- 7.2 Trade finance documents -> structured fields + discrepancy detection
CREATE OR REPLACE TABLE AI.TF_EXTRACTED AS
WITH r AS (
  SELECT DOC_ID, CUSTOMER_ID, DOC_TYPE, DOC_DATE, DOC_TEXT,
         SNOWFLAKE.CORTEX.COMPLETE('llama3.3-70b',
           'Extract fields from this trade finance document. Return ONLY minified JSON with keys: '
           || 'applicant, counterparty, currency, amount (number), incoterm, latest_shipment_date (YYYY-MM-DD or null), '
           || 'expiry_date (YYYY-MM-DD or null), goods, has_discrepancy (boolean), discrepancy_summary (string or null). '
           || 'Document: ' || DOC_TEXT) AS RESP
  FROM SILVER.TF_DOCS
)
SELECT DOC_ID, CUSTOMER_ID, DOC_TYPE, DOC_DATE, DOC_TEXT,
       TRY_PARSE_JSON(REGEXP_SUBSTR(RESP, '[{].*[}]', 1, 1, 's')) AS J,
       J:applicant::STRING AS APPLICANT, J:counterparty::STRING AS COUNTERPARTY, J:currency::STRING AS CURRENCY,
       TRY_TO_NUMBER(J:amount::STRING, 18, 2) AS AMOUNT, J:incoterm::STRING AS INCOTERM,
       TRY_TO_DATE(J:latest_shipment_date::STRING) AS LATEST_SHIPMENT_DATE, TRY_TO_DATE(J:expiry_date::STRING) AS EXPIRY_DATE,
       J:goods::STRING AS GOODS, COALESCE(TRY_TO_BOOLEAN(J:has_discrepancy::STRING), FALSE) AS HAS_DISCREPANCY,
       J:discrepancy_summary::STRING AS DISCREPANCY_SUMMARY
FROM r;

-- ============================================================
-- SECTION 8: GOLD - BUSINESS BANKING CUSTOMER 360
-- ============================================================
CREATE OR REPLACE TABLE GOLD.DIM_CUSTOMER AS
WITH src AS (SELECT CUSTOMER_ID, COUNT(DISTINCT SOURCE_SYSTEM) AS SOURCE_SYSTEMS, COUNT(*) AS SOURCE_RECORDS
             FROM SILVER.ENTITY_XREF GROUP BY 1)
SELECT x.CUSTOMER_ID, c.CIF_NO, c.SSM_NORM AS SSM_REG_NO, c.COMPANY_NAME, c.INDUSTRY, c.MSIC_CODE, c.STATE,
       c.INCORPORATION_DATE, DATEDIFF(year, c.INCORPORATION_DATE, CURRENT_DATE()) AS YEARS_IN_BUSINESS,
       c.ANNUAL_TURNOVER_MYR::NUMBER(18,0) AS ANNUAL_TURNOVER_MYR, c.EMPLOYEES, c.RM_ID,
       s.SOURCE_SYSTEMS, s.SOURCE_RECORDS
FROM SILVER.CORE_CUSTOMERS c
JOIN SILVER.ENTITY_XREF x ON x.SOURCE_SYSTEM = 'CORE' AND x.SOURCE_ID = c.CIF_NO
JOIN src s ON s.CUSTOMER_ID = x.CUSTOMER_ID;

CREATE OR REPLACE TABLE GOLD.DIM_DIRECTOR AS
SELECT NRIC, DIRECTOR_NAME, DOB, CUSTOMER_ID, ROLE, SHAREHOLDING_PCT FROM SILVER.DIRECTORS;

CREATE OR REPLACE TABLE GOLD.FACT_APPLICATION AS
SELECT APPLICATION_ID, CUSTOMER_ID, PRODUCT, AMOUNT_REQUESTED_MYR::NUMBER(18,0) AS AMOUNT_REQUESTED_MYR,
       SUBMITTED_AT, DECISION_AT, STATUS, REASON_CODE, DECISION_DAYS
FROM SILVER.LOAN_APPLICATIONS;

CREATE OR REPLACE TABLE GOLD.FACT_LOAN AS
WITH rp AS (
  SELECT LOAN_ID, MAX(DPD) AS MAX_DPD_12M, MAX_BY(DPD, DUE_DATE) AS CURRENT_DPD, MAX_BY(OUTSTANDING_MYR, DUE_DATE) AS OUTSTANDING_MYR
  FROM SILVER.REPAYMENTS GROUP BY LOAN_ID
)
SELECT l.LOAN_ID, l.CUSTOMER_ID, l.APPLICATION_ID, l.PRODUCT, l.ORIGINATION_DATE,
       l.PRINCIPAL_MYR::NUMBER(18,0) AS PRINCIPAL_MYR, COALESCE(rp.OUTSTANDING_MYR, l.PRINCIPAL_MYR)::NUMBER(18,0) AS OUTSTANDING_MYR,
       l.INTEREST_RATE_PCT, l.TENURE_MONTHS, l.COLLATERAL_TYPE,
       COALESCE(rp.MAX_DPD_12M, 0) AS MAX_DPD_12M, COALESCE(rp.CURRENT_DPD, 0) AS CURRENT_DPD,
       COALESCE(rp.CURRENT_DPD, 0) >= 90 AS IS_NPL,
       CASE WHEN COALESCE(rp.CURRENT_DPD, 0) >= 90 THEN 'NPL (impaired)'
            WHEN COALESCE(rp.CURRENT_DPD, 0) >= 30 THEN 'Special mention'
            ELSE 'Performing' END AS LOAN_STATUS
FROM SILVER.LOANS l LEFT JOIN rp ON rp.LOAN_ID = l.LOAN_ID;

-- Near-real-time cash-flow fact (auto-refreshed incremental pipeline)
CREATE OR REPLACE DYNAMIC TABLE GOLD.FACT_TXN_DAILY
  TARGET_LAG = '1 minute' WAREHOUSE = SME_WH
AS
SELECT a.CUSTOMER_ID, e.EVENT_TS::DATE AS TXN_DATE, e.CHANNEL, e.DIRECTION, e.SOURCE_SYSTEM,
       COUNT(*) AS TXN_CNT, SUM(e.AMOUNT_MYR) AS AMOUNT_MYR
FROM SILVER.TXN_EVENTS e
JOIN SILVER.ACCOUNTS a ON a.ACCOUNT_NO = e.ACCOUNT_NO
GROUP BY ALL;

-- Build logic for the 360 (owner-only); CUSTOMER_360 is the governed serving table
CREATE OR REPLACE VIEW GOLD.V_CUSTOMER_360_BUILD AS
WITH ln AS (
  SELECT CUSTOMER_ID, COUNT(*) AS N_LOANS, SUM(PRINCIPAL_MYR) AS TOTAL_PRINCIPAL_MYR, SUM(OUTSTANDING_MYR) AS TOTAL_OUTSTANDING_MYR,
         SUM(IFF(IS_NPL, OUTSTANDING_MYR, 0)) AS NPL_OUTSTANDING_MYR, MAX(MAX_DPD_12M) AS MAX_DPD_12M, BOOLOR_AGG(IS_NPL) AS NPL_FLAG
  FROM GOLD.FACT_LOAN GROUP BY 1),
ap AS (
  SELECT CUSTOMER_ID, COUNT(*) AS N_APPLICATIONS, COUNT_IF(STATUS = 'Pending') AS PENDING_APPLICATIONS, AVG(DECISION_DAYS) AS AVG_DECISION_DAYS
  FROM GOLD.FACT_APPLICATION GROUP BY 1),
tx AS (
  SELECT CUSTOMER_ID,
         SUM(IFF(DIRECTION = 'CR' AND TXN_DATE >= CURRENT_DATE() - 90, AMOUNT_MYR, 0)) AS INFLOW_90D,
         SUM(IFF(DIRECTION = 'CR' AND TXN_DATE < CURRENT_DATE() - 90 AND TXN_DATE >= CURRENT_DATE() - 180, AMOUNT_MYR, 0)) AS INFLOW_PREV_90D,
         SUM(IFF(SOURCE_SYSTEM = 'MERCHANT_ACQUIRING' AND TXN_DATE >= CURRENT_DATE() - 90, AMOUNT_MYR, 0)) AS MERCHANT_VOL_90D
  FROM GOLD.FACT_TXN_DAILY GROUP BY 1),
acc AS (SELECT CUSTOMER_ID, SUM(OD_LIMIT_MYR) AS OD_LIMIT, SUM(OD_BALANCE_MYR) AS OD_BAL FROM SILVER.ACCOUNTS GROUP BY 1),
rp AS (
  SELECT r.CUSTOMER_ID, COUNT(DISTINCT r.RELATED_CUSTOMER_ID) AS RELATED_PARTY_CNT,
         COUNT(DISTINCT IFF(l.NPL_FLAG, r.RELATED_CUSTOMER_ID, NULL)) AS RELATED_PARTY_NPL_CNT
  FROM SILVER.RELATED_PARTY_LINKS r LEFT JOIN ln l ON l.CUSTOMER_ID = r.RELATED_CUSTOMER_ID GROUP BY 1),
rm AS (
  SELECT CUSTOMER_ID, AVG(SENTIMENT) AS AVG_RM_SENTIMENT, MAX(NOTE_DATE) AS LAST_RM_CONTACT_DATE,
         COUNT_IF(RISK_CUE IN ('Cash flow stress','Repayment delay','Legal or governance concern')) AS RM_RISK_FLAGS,
         COUNT_IF(RISK_CUE IN ('Cross-sell opportunity','Business growth')) AS RM_XSELL_FLAGS
  FROM AI.RM_NOTE_INSIGHTS GROUP BY 1),
tf AS (SELECT CUSTOMER_ID, COUNT(*) AS TF_DOCS_CNT, COUNT_IF(HAS_DISCREPANCY) AS TF_DISCREPANCY_CNT FROM AI.TF_EXTRACTED GROUP BY 1)
SELECT d.CUSTOMER_ID, d.COMPANY_NAME, d.SSM_REG_NO, d.INDUSTRY, d.STATE, d.RM_ID, d.YEARS_IN_BUSINESS,
       d.ANNUAL_TURNOVER_MYR, d.EMPLOYEES,
       COALESCE(ln.N_LOANS, 0) AS N_LOANS,
       COALESCE(ln.TOTAL_PRINCIPAL_MYR, 0)::NUMBER(18,0)   AS TOTAL_PRINCIPAL_MYR,
       COALESCE(ln.TOTAL_OUTSTANDING_MYR, 0)::NUMBER(18,0) AS TOTAL_OUTSTANDING_MYR,
       COALESCE(ln.NPL_OUTSTANDING_MYR, 0)::NUMBER(18,0)   AS NPL_OUTSTANDING_MYR,
       COALESCE(ln.MAX_DPD_12M, 0) AS MAX_DPD_12M, COALESCE(ln.NPL_FLAG, FALSE) AS NPL_FLAG,
       COALESCE(ap.N_APPLICATIONS, 0) AS N_APPLICATIONS, COALESCE(ap.PENDING_APPLICATIONS, 0) AS PENDING_APPLICATIONS,
       ROUND(ap.AVG_DECISION_DAYS, 1) AS AVG_DECISION_DAYS,
       ROUND(DIV0(acc.OD_BAL, acc.OD_LIMIT), 3) AS OD_UTILISATION,
       COALESCE(tx.INFLOW_90D, 0)::NUMBER(18,0) AS INFLOW_90D_MYR,
       COALESCE(tx.INFLOW_PREV_90D, 0)::NUMBER(18,0) AS INFLOW_PREV_90D_MYR,
       ROUND(DIV0(tx.INFLOW_90D - tx.INFLOW_PREV_90D, tx.INFLOW_PREV_90D) * 100, 1) AS INFLOW_TREND_PCT,
       COALESCE(tx.MERCHANT_VOL_90D, 0)::NUMBER(18,0) AS MERCHANT_VOL_90D_MYR,
       b.CTOS_SCORE::NUMBER(18,0) AS CTOS_SCORE, b.CCRIS_ARREARS_12M, b.CCRIS_SPECIAL_ATTENTION, b.LEGAL_CASES,
       COALESCE(rp.RELATED_PARTY_CNT, 0) AS RELATED_PARTY_CNT, COALESCE(rp.RELATED_PARTY_NPL_CNT, 0) AS RELATED_PARTY_NPL_CNT,
       ROUND(rm.AVG_RM_SENTIMENT, 3) AS AVG_RM_SENTIMENT, rm.LAST_RM_CONTACT_DATE,
       COALESCE(rm.RM_RISK_FLAGS, 0) AS RM_RISK_FLAGS, COALESCE(rm.RM_XSELL_FLAGS, 0) AS RM_XSELL_FLAGS,
       COALESCE(tf.TF_DOCS_CNT, 0) AS TF_DOCS_CNT, COALESCE(tf.TF_DISCREPANCY_CNT, 0) AS TF_DISCREPANCY_CNT,
       CURRENT_TIMESTAMP() AS REFRESHED_AT
FROM GOLD.DIM_CUSTOMER d
LEFT JOIN ln  ON ln.CUSTOMER_ID  = d.CUSTOMER_ID
LEFT JOIN ap  ON ap.CUSTOMER_ID  = d.CUSTOMER_ID
LEFT JOIN tx  ON tx.CUSTOMER_ID  = d.CUSTOMER_ID
LEFT JOIN acc ON acc.CUSTOMER_ID = d.CUSTOMER_ID
LEFT JOIN SILVER.BUREAU b ON b.CUSTOMER_ID = d.CUSTOMER_ID
LEFT JOIN rp  ON rp.CUSTOMER_ID  = d.CUSTOMER_ID
LEFT JOIN rm  ON rm.CUSTOMER_ID  = d.CUSTOMER_ID
LEFT JOIN tf  ON tf.CUSTOMER_ID  = d.CUSTOMER_ID;

CREATE OR REPLACE TABLE GOLD.CUSTOMER_360 AS SELECT * FROM GOLD.V_CUSTOMER_360_BUILD;

CREATE OR REPLACE PROCEDURE GOLD.REFRESH_CUSTOMER_360()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  INSERT OVERWRITE INTO SME_BANK_DB.GOLD.CUSTOMER_360 SELECT * FROM SME_BANK_DB.GOLD.V_CUSTOMER_360_BUILD;
  RETURN 'CUSTOMER_360 refreshed';
END;
$$;

-- ============================================================
-- SECTION 9: GOVERNANCE - SECURE VIEWS + ROLE-AWARE MASKING (BNM RMiT / PDPA 2010)
-- ============================================================
-- Standard edition has no masking/row access policies or tags. Equivalent controls:
--   * masking UDFs evaluated against CURRENT_ROLE()
--   * secure views apply masking + RM portfolio row filter
--   * consumers are granted secure views only, never base tables
CREATE OR REPLACE TABLE GOV.RM_TERRITORY_MAP (USER_NAME STRING, RM_ID STRING);
INSERT INTO GOV.RM_TERRITORY_MAP SELECT CURRENT_USER(), 'RM01' UNION ALL SELECT CURRENT_USER(), 'RM02';

CREATE OR REPLACE FUNCTION GOV.M_NRIC(V STRING) RETURNS STRING AS
$$ CASE WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN','SME_ADMIN','CREDIT_ANALYST') THEN V
        WHEN V IS NULL THEN NULL ELSE '********' || RIGHT(REGEXP_REPLACE(V,'[^0-9]',''),4) END $$;
CREATE OR REPLACE FUNCTION GOV.M_SSM(V STRING) RETURNS STRING AS
$$ CASE WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN','SME_ADMIN','CREDIT_ANALYST','RM_USER','AUDITOR') THEN V
        WHEN V IS NULL THEN NULL ELSE LEFT(V,4) || '********' END $$;
CREATE OR REPLACE FUNCTION GOV.M_NAME(V STRING) RETURNS STRING AS
$$ IFF(CURRENT_ROLE() = 'DATA_ENGINEER', '*** MASKED ***', V) $$;
CREATE OR REPLACE FUNCTION GOV.M_DOB(V DATE) RETURNS DATE AS
$$ IFF(CURRENT_ROLE() IN ('ACCOUNTADMIN','SME_ADMIN','CREDIT_ANALYST'), V, DATE_TRUNC('year', V)) $$;
CREATE OR REPLACE FUNCTION GOV.M_FIN(V NUMBER) RETURNS NUMBER AS
$$ CASE WHEN CURRENT_ROLE() IN ('ACCOUNTADMIN','SME_ADMIN','CREDIT_ANALYST','AUDITOR') THEN V
        WHEN CURRENT_ROLE() = 'RM_USER' THEN ROUND(V, -5) ELSE NULL END $$;
CREATE OR REPLACE FUNCTION GOV.M_SCORE(V NUMBER) RETURNS NUMBER AS
$$ IFF(CURRENT_ROLE() IN ('ACCOUNTADMIN','SME_ADMIN','CREDIT_ANALYST','AUDITOR'), V, NULL) $$;

-- Row filter reused by every secure view (RMs see only their portfolio)
CREATE OR REPLACE SECURE VIEW GOV.V_VISIBLE_CUSTOMERS AS
SELECT CUSTOMER_ID FROM GOLD.DIM_CUSTOMER
WHERE CURRENT_ROLE() IN ('ACCOUNTADMIN','SME_ADMIN','CREDIT_ANALYST','AUDITOR','DATA_ENGINEER')
   OR (CURRENT_ROLE() = 'RM_USER'
       AND RM_ID IN (SELECT RM_ID FROM GOV.RM_TERRITORY_MAP WHERE USER_NAME = CURRENT_USER()));

CREATE OR REPLACE SECURE VIEW GOLD.V_DIM_DIRECTOR_SECURE AS
SELECT GOV.M_NRIC(NRIC) AS NRIC, GOV.M_NAME(DIRECTOR_NAME) AS DIRECTOR_NAME, GOV.M_DOB(DOB) AS DOB,
       CUSTOMER_ID, ROLE, SHAREHOLDING_PCT
FROM GOLD.DIM_DIRECTOR WHERE CUSTOMER_ID IN (SELECT CUSTOMER_ID FROM GOV.V_VISIBLE_CUSTOMERS);

CREATE OR REPLACE SECURE VIEW GOLD.V_FACT_LOAN_SECURE AS
SELECT * EXCLUDE (PRINCIPAL_MYR, OUTSTANDING_MYR),
       GOV.M_FIN(PRINCIPAL_MYR) AS PRINCIPAL_MYR, GOV.M_FIN(OUTSTANDING_MYR) AS OUTSTANDING_MYR
FROM GOLD.FACT_LOAN WHERE CUSTOMER_ID IN (SELECT CUSTOMER_ID FROM GOV.V_VISIBLE_CUSTOMERS);

CREATE OR REPLACE SECURE VIEW GOLD.V_FACT_APPLICATION_SECURE AS
SELECT * EXCLUDE (AMOUNT_REQUESTED_MYR), GOV.M_FIN(AMOUNT_REQUESTED_MYR) AS AMOUNT_REQUESTED_MYR
FROM GOLD.FACT_APPLICATION WHERE CUSTOMER_ID IN (SELECT CUSTOMER_ID FROM GOV.V_VISIBLE_CUSTOMERS);

-- Engineer-safe view of raw KYC data
CREATE OR REPLACE SECURE VIEW RAW.V_CRM_DIRECTORS_SECURE AS
SELECT KYC_ID, GOV.M_NRIC(NRIC) AS NRIC, GOV.M_NAME(DIRECTOR_NAME) AS DIRECTOR_NAME, GOV.M_DOB(DOB) AS DOB,
       GOV.M_SSM(SSM_REG_NO) AS SSM_REG_NO, ROLE, SHAREHOLDING_PCT, _SRC_FILE, _LOADED_AT
FROM RAW.CRM_DIRECTORS;

-- PII inventory (catalogue substitute for object tags)
CREATE OR REPLACE TABLE GOV.PII_INVENTORY (OBJECT_NAME STRING, COLUMN_NAME STRING, PII_TYPE STRING, CONTROL STRING);
INSERT INTO GOV.PII_INVENTORY VALUES
  ('RAW.CRM_DIRECTORS','NRIC','NRIC','No consumer grant; DE via RAW.V_CRM_DIRECTORS_SECURE'),
  ('RAW.CRM_DIRECTORS','DIRECTOR_NAME','PERSON_NAME','No consumer grant; masked for DE'),
  ('RAW.CRM_DIRECTORS','DOB','DOB','Year only outside credit'),
  ('SILVER.DIRECTORS','NRIC','NRIC','Owner only'),
  ('SILVER.BUREAU','CTOS_SCORE','CREDIT_SCORE','Owner only'),
  ('GOLD.DIM_DIRECTOR','NRIC','NRIC','V_DIM_DIRECTOR_SECURE: GOV.M_NRIC'),
  ('GOLD.CUSTOMER_360','SSM_REG_NO','SSM','CUSTOMER_360_SCORED: GOV.M_SSM'),
  ('GOLD.CUSTOMER_360','TOTAL_OUTSTANDING_MYR','FINANCIAL','CUSTOMER_360_SCORED: GOV.M_FIN'),
  ('GOLD.CUSTOMER_360','CTOS_SCORE','CREDIT_SCORE','CUSTOMER_360_SCORED: GOV.M_SCORE'),
  ('GOLD.FACT_LOAN','OUTSTANDING_MYR','FINANCIAL','V_FACT_LOAN_SECURE: GOV.M_FIN'),
  ('GOLD.*','RM_ID','ROW_FILTER','GOV.V_VISIBLE_CUSTOMERS via RM_TERRITORY_MAP');

-- ============================================================
-- SECTION 10: ML - SME 12-MONTH DEFAULT PROBABILITY (XGBoost + Model Registry)
-- ============================================================
CREATE OR REPLACE TRANSIENT TABLE ML.PD_SCORES_STAGE (CUSTOMER_ID STRING, PD FLOAT, MODEL_VERSION STRING);
CREATE OR REPLACE TABLE ML.PD_SCORES (
  CUSTOMER_ID STRING, PD FLOAT, RISK_BAND STRING, EARLY_WARNING_FLAG BOOLEAN,
  RISK_DRIVERS STRING, NEXT_BEST_ACTION STRING, MODEL_VERSION STRING, SCORED_AT TIMESTAMP_LTZ);
CREATE OR REPLACE TABLE ML.MODEL_METRICS (
  MODEL_VERSION STRING, AUC FLOAT, PRECISION_AT_50 FLOAT, RECALL_AT_50 FLOAT,
  N_TRAIN NUMBER, N_TEST NUMBER, DEFAULT_RATE FLOAT, TRAINED_AT TIMESTAMP_LTZ);
CREATE OR REPLACE TABLE ML.FEATURE_IMPORTANCE (MODEL_VERSION STRING, FEATURE STRING, IMPORTANCE FLOAT);

-- Band, early-warning flag, reason codes and next-best action (explainable for credit committee)
CREATE OR REPLACE VIEW ML.V_PD_SCORES_BUILD AS
SELECT s.CUSTOMER_ID, s.PD,
  CASE WHEN s.PD < 0.05 THEN 'A' WHEN s.PD < 0.10 THEN 'B' WHEN s.PD < 0.20 THEN 'C'
       WHEN s.PD < 0.40 THEN 'D' ELSE 'E' END AS RISK_BAND,
  (NOT c.NPL_FLAG) AND (RISK_BAND IN ('D','E') OR c.INFLOW_TREND_PCT < -30
                        OR (c.RELATED_PARTY_NPL_CNT > 0 AND RISK_BAND = 'C')) AS EARLY_WARNING_FLAG,
  ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
    IFF(c.CTOS_SCORE < 600, 'Weak CTOS score', NULL),
    IFF(c.CCRIS_ARREARS_12M >= 2, 'CCRIS arrears in last 12m', NULL),
    IFF(c.OD_UTILISATION > 0.85, 'OD utilisation above 85%', NULL),
    IFF(c.INFLOW_TREND_PCT < -20, 'Cash inflow down ' || ABS(c.INFLOW_TREND_PCT) || '% vs prior 90d', NULL),
    IFF(c.RELATED_PARTY_NPL_CNT > 0, 'Related party in NPL', NULL),
    IFF(c.RM_RISK_FLAGS > 0, 'RM notes flag stress', NULL),
    IFF(c.TF_DISCREPANCY_CNT > 0, 'Trade document discrepancies', NULL)), '; ') AS RISK_DRIVERS,
  CASE WHEN c.NPL_FLAG THEN 'Recovery / rehabilitation review'
       WHEN RISK_BAND IN ('A','B') AND c.TF_DOCS_CNT > 0 THEN 'Trade line / LC facility'
       WHEN RISK_BAND IN ('A','B') AND c.MERCHANT_VOL_90D_MYR > 0 THEN 'DuitNow QR merchant + working capital'
       WHEN RISK_BAND IN ('A','B','C') THEN 'SJPP-guaranteed term loan'
       WHEN RISK_BAND = 'D' THEN 'Watchlist: tighten covenants, monthly cash-flow review'
       ELSE 'Watchlist: proactive restructuring (R&R) discussion' END AS NEXT_BEST_ACTION,
  s.MODEL_VERSION, CURRENT_TIMESTAMP() AS SCORED_AT
FROM ML.PD_SCORES_STAGE s
JOIN GOLD.CUSTOMER_360 c ON c.CUSTOMER_ID = s.CUSTOMER_ID;

CREATE OR REPLACE PROCEDURE ML.TRAIN_PD_MODEL()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python','snowflake-ml-python','xgboost','scikit-learn','pandas')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
import datetime
import xgboost as xgb
from sklearn.model_selection import train_test_split
from sklearn.metrics import roc_auc_score, precision_score, recall_score
from snowflake.ml.registry import Registry

FEATURES = ["YEARS_IN_BUSINESS", "ANNUAL_TURNOVER_MYR", "EMPLOYEES", "OD_UTILISATION", "INFLOW_TREND_PCT",
            "MERCHANT_VOL_90D_MYR", "CTOS_SCORE", "CCRIS_ARREARS_12M", "LEGAL_CASES", "RELATED_PARTY_NPL_CNT",
            "AVG_RM_SENTIMENT", "RM_RISK_FLAGS", "TF_DISCREPANCY_CNT"]

def run(session):
    q = ("SELECT CUSTOMER_ID, N_LOANS, NPL_FLAG, "
         + ", ".join(f"COALESCE({f}, 0)::FLOAT AS {f}" for f in FEATURES)
         + " FROM SME_BANK_DB.GOLD.CUSTOMER_360")
    df = session.sql(q).to_pandas()
    train = df[df.N_LOANS > 0]
    X, y = train[FEATURES], train.NPL_FLAG.astype(int)
    Xtr, Xte, ytr, yte = train_test_split(X, y, test_size=0.3, random_state=42, stratify=y)
    spw = float((ytr == 0).sum()) / max(1.0, float((ytr == 1).sum()))
    model = xgb.XGBClassifier(n_estimators=200, max_depth=3, learning_rate=0.05, subsample=0.9,
                              colsample_bytree=0.9, scale_pos_weight=spw, eval_metric="auc", random_state=42)
    model.fit(Xtr, ytr)
    p = model.predict_proba(Xte)[:, 1]
    auc = float(roc_auc_score(yte, p))
    prec = float(precision_score(yte, (p >= 0.5).astype(int), zero_division=0))
    rec = float(recall_score(yte, (p >= 0.5).astype(int), zero_division=0))

    version = "V_" + datetime.datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    registry_note = "registered"
    try:
        reg = Registry(session=session, database_name="SME_BANK_DB", schema_name="ML")
        mv = reg.log_model(model, model_name="SME_PD_MODEL", version_name=version,
                           sample_input_data=Xtr.head(20), target_platforms=["WAREHOUSE"],
                           conda_dependencies=["xgboost", "scikit-learn"],
                           options={"embed_local_ml_library": True, "relax_version": True},
                           comment="SME 12-month default probability (XGBoost)")
        mv.set_metric(metric_name="auc", value=auc)
        reg.get_model("SME_PD_MODEL").default = version
    except Exception as e:
        # Keep the pipeline running; scores are still produced from the in-memory model
        registry_note = "registry skipped: " + str(e)[:150]

    session.sql("INSERT INTO SME_BANK_DB.ML.MODEL_METRICS SELECT ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP()",
                params=[version, auc, prec, rec, int(len(Xtr)), int(len(Xte)), float(y.mean())]).collect()
    session.create_dataframe([[version, f, float(v)] for f, v in zip(FEATURES, model.feature_importances_)],
                             schema=["MODEL_VERSION", "FEATURE", "IMPORTANCE"]
                             ).write.mode("append").save_as_table("SME_BANK_DB.ML.FEATURE_IMPORTANCE")

    out = df[["CUSTOMER_ID"]].copy()
    out["PD"] = model.predict_proba(df[FEATURES])[:, 1].astype(float)
    out["MODEL_VERSION"] = version
    session.create_dataframe(out).create_or_replace_temp_view("TMP_PD")
    session.sql("INSERT OVERWRITE INTO SME_BANK_DB.ML.PD_SCORES_STAGE SELECT CUSTOMER_ID, PD, MODEL_VERSION FROM TMP_PD").collect()
    session.sql("INSERT OVERWRITE INTO SME_BANK_DB.ML.PD_SCORES SELECT * FROM SME_BANK_DB.ML.V_PD_SCORES_BUILD").collect()
    return f"{version}: AUC={auc:.3f} precision={prec:.2f} recall={rec:.2f} scored={len(out)} | {registry_note}"
$$;

-- Daily batch scoring through the registered model (no retraining)
CREATE OR REPLACE PROCEDURE ML.SCORE_PD()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python','snowflake-ml-python','xgboost','scikit-learn','pandas')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
from snowflake.snowpark.functions import col
from snowflake.ml.registry import Registry

FEATURES = ["YEARS_IN_BUSINESS", "ANNUAL_TURNOVER_MYR", "EMPLOYEES", "OD_UTILISATION", "INFLOW_TREND_PCT",
            "MERCHANT_VOL_90D_MYR", "CTOS_SCORE", "CCRIS_ARREARS_12M", "LEGAL_CASES", "RELATED_PARTY_NPL_CNT",
            "AVG_RM_SENTIMENT", "RM_RISK_FLAGS", "TF_DISCREPANCY_CNT"]

def run(session):
    try:
        reg = Registry(session=session, database_name="SME_BANK_DB", schema_name="ML")
        mv = reg.get_model("SME_PD_MODEL").default
    except Exception:
        # No registered model available: retrain and score instead
        return session.call("SME_BANK_DB.ML.TRAIN_PD_MODEL")
    sdf = session.sql("SELECT CUSTOMER_ID, " + ", ".join(f"COALESCE({f}, 0)::FLOAT AS {f}" for f in FEATURES)
                      + " FROM SME_BANK_DB.GOLD.CUSTOMER_360")
    out = mv.run(sdf, function_name="predict_proba")
    cands = [c for c in out.columns if c.strip('"').lower().endswith("output_feature_1")]
    pcol = cands[0] if cands else out.columns[-1]
    out.select(col("CUSTOMER_ID"), col(pcol).alias("PD")).create_or_replace_temp_view("TMP_PD")
    session.sql(f"INSERT OVERWRITE INTO SME_BANK_DB.ML.PD_SCORES_STAGE SELECT CUSTOMER_ID, PD, '{mv.version_name}' FROM TMP_PD").collect()
    session.sql("INSERT OVERWRITE INTO SME_BANK_DB.ML.PD_SCORES SELECT * FROM SME_BANK_DB.ML.V_PD_SCORES_BUILD").collect()
    return f"Scored with {mv.version_name}"
$$;

CALL ML.TRAIN_PD_MODEL();

-- Scored 360 for apps, agent and RMs
CREATE OR REPLACE SECURE VIEW GOLD.CUSTOMER_360_SCORED AS
SELECT c.* EXCLUDE (SSM_REG_NO, ANNUAL_TURNOVER_MYR, TOTAL_PRINCIPAL_MYR, TOTAL_OUTSTANDING_MYR, NPL_OUTSTANDING_MYR,
                    INFLOW_90D_MYR, INFLOW_PREV_90D_MYR, MERCHANT_VOL_90D_MYR, CTOS_SCORE),
       GOV.M_SSM(c.SSM_REG_NO) AS SSM_REG_NO,
       GOV.M_FIN(c.ANNUAL_TURNOVER_MYR) AS ANNUAL_TURNOVER_MYR,
       GOV.M_FIN(c.TOTAL_PRINCIPAL_MYR) AS TOTAL_PRINCIPAL_MYR,
       GOV.M_FIN(c.TOTAL_OUTSTANDING_MYR) AS TOTAL_OUTSTANDING_MYR,
       GOV.M_FIN(c.NPL_OUTSTANDING_MYR) AS NPL_OUTSTANDING_MYR,
       GOV.M_FIN(c.INFLOW_90D_MYR) AS INFLOW_90D_MYR,
       GOV.M_FIN(c.INFLOW_PREV_90D_MYR) AS INFLOW_PREV_90D_MYR,
       GOV.M_FIN(c.MERCHANT_VOL_90D_MYR) AS MERCHANT_VOL_90D_MYR,
       GOV.M_SCORE(c.CTOS_SCORE) AS CTOS_SCORE,
       p.PD, p.RISK_BAND, p.EARLY_WARNING_FLAG, p.RISK_DRIVERS, p.NEXT_BEST_ACTION, p.MODEL_VERSION, p.SCORED_AT
FROM GOLD.CUSTOMER_360 c
LEFT JOIN ML.PD_SCORES p ON p.CUSTOMER_ID = c.CUSTOMER_ID
WHERE c.CUSTOMER_ID IN (SELECT CUSTOMER_ID FROM GOV.V_VISIBLE_CUSTOMERS);

CREATE OR REPLACE SECURE VIEW ML.V_PD_SCORES_SECURE AS
SELECT * FROM ML.PD_SCORES WHERE CUSTOMER_ID IN (SELECT CUSTOMER_ID FROM GOV.V_VISIBLE_CUSTOMERS);

CREATE OR REPLACE VIEW ML.V_EARLY_WARNING_WATCHLIST AS
SELECT CUSTOMER_ID, COMPANY_NAME, INDUSTRY, STATE, RM_ID, TOTAL_OUTSTANDING_MYR, PD, RISK_BAND, RISK_DRIVERS, NEXT_BEST_ACTION
FROM GOLD.CUSTOMER_360_SCORED WHERE EARLY_WARNING_FLAG ORDER BY PD DESC;

-- Daily orchestration: refresh 360 -> rescore (task graph)
CREATE OR REPLACE TASK GOLD.TASK_REFRESH_360
  WAREHOUSE = SME_WH SCHEDULE = 'USING CRON 0 7 * * * Asia/Kuala_Lumpur'
  AS CALL SME_BANK_DB.GOLD.REFRESH_CUSTOMER_360();
-- Child task must live in the same schema as its predecessor
CREATE OR REPLACE TASK GOLD.TASK_SCORE_PD
  WAREHOUSE = SME_WH AFTER SME_BANK_DB.GOLD.TASK_REFRESH_360
  AS CALL SME_BANK_DB.ML.SCORE_PD();

-- ============================================================
-- SECTION 11: CORTEX - CREDIT MEMO + SEARCH
-- ============================================================
CREATE OR REPLACE VIEW AI.V_CREDIT_MEMO_CONTEXT AS
SELECT s.CUSTOMER_ID,
  OBJECT_CONSTRUCT('company', s.COMPANY_NAME, 'industry', s.INDUSTRY, 'state', s.STATE,
    'years_in_business', s.YEARS_IN_BUSINESS, 'annual_turnover_myr', s.ANNUAL_TURNOVER_MYR,
    'loans', s.N_LOANS, 'outstanding_myr', s.TOTAL_OUTSTANDING_MYR, 'max_dpd_12m', s.MAX_DPD_12M,
    'currently_npl', s.NPL_FLAG, 'od_utilisation', s.OD_UTILISATION, 'inflow_trend_pct_90d', s.INFLOW_TREND_PCT,
    'merchant_volume_90d_myr', s.MERCHANT_VOL_90D_MYR, 'ctos_score', s.CTOS_SCORE,
    'ccris_arrears_12m', s.CCRIS_ARREARS_12M, 'legal_cases', s.LEGAL_CASES,
    'related_parties', s.RELATED_PARTY_CNT, 'related_parties_in_npl', s.RELATED_PARTY_NPL_CNT,
    'pd_12m', ROUND(s.PD, 4), 'risk_band', s.RISK_BAND, 'risk_drivers', s.RISK_DRIVERS,
    'next_best_action', s.NEXT_BEST_ACTION, 'pending_applications', s.PENDING_APPLICATIONS) AS PROFILE,
  n.NOTES, t.TF
FROM GOLD.CUSTOMER_360_SCORED s
LEFT JOIN (SELECT CUSTOMER_ID,
                  LISTAGG(NOTE_DATE || ' [' || COALESCE(RISK_CUE, 'n/a') || '] ' || NOTE_TEXT, ' | ')
                    WITHIN GROUP (ORDER BY NOTE_DATE DESC) AS NOTES
           FROM AI.RM_NOTE_INSIGHTS GROUP BY 1) n ON n.CUSTOMER_ID = s.CUSTOMER_ID
LEFT JOIN (SELECT CUSTOMER_ID,
                  LISTAGG(DOC_TYPE || ' with ' || COALESCE(COUNTERPARTY, 'n/a') || ' ' || COALESCE(CURRENCY, '') || ' '
                          || COALESCE(AMOUNT::STRING, '') || IFF(HAS_DISCREPANCY, ' DISCREPANCY: ' || COALESCE(DISCREPANCY_SUMMARY, ''), ''), ' | ') AS TF
           FROM AI.TF_EXTRACTED GROUP BY 1) t ON t.CUSTOMER_ID = s.CUSTOMER_ID;

-- Prompt per customer (lets you batch memos with plain SQL: SELECT COMPLETE(model, PROMPT) FROM view WHERE ...)
CREATE OR REPLACE VIEW AI.V_CREDIT_MEMO_PROMPT AS
SELECT c.CUSTOMER_ID,
  'You are a senior credit analyst at a Malaysian bank writing an internal SME credit memo aligned with '
  || 'Bank Negara Malaysia credit risk expectations. Use ONLY the data provided. If a field is null or missing, write "not available". '
  || 'Amounts are in MYR. Use these sections: 1) Business profile 2) Exposure and repayment conduct 3) Key risk drivers '
  || '4) Related-party and trade finance alerts 5) RM relationship insights 6) Recommendation (Approve / Approve with conditions / '
  || 'Decline / Watchlist) with specific conditions 7) Next-best product with a one-line rationale. Max 350 words. '
  || 'End with: "Draft for credit committee review." '
  || 'DATA: ' || c.PROFILE::STRING
  || ' RM_NOTES: ' || COALESCE(c.NOTES, 'none')
  || ' TRADE_DOCUMENTS: ' || COALESCE(c.TF, 'none') AS PROMPT
FROM AI.V_CREDIT_MEMO_CONTEXT c;

-- Credit memo as a procedure (a SQL UDF cannot run a table subquery per row)
DROP FUNCTION IF EXISTS AI.GENERATE_CREDIT_MEMO(STRING);
CREATE OR REPLACE PROCEDURE AI.GENERATE_CREDIT_MEMO(CUSTOMER_ID_IN STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
--COMMENT = 'AI-drafted SME credit memo. Decision support only; credit committee decides.'
AS
$$
DECLARE
  p STRING;
  memo STRING;
BEGIN
  SELECT MAX(PROMPT) INTO :p FROM SME_BANK_DB.AI.V_CREDIT_MEMO_PROMPT WHERE CUSTOMER_ID = :CUSTOMER_ID_IN;
  IF (p IS NULL) THEN
    RETURN 'Customer ' || CUSTOMER_ID_IN || ' not found or not visible to your role.';
  END IF;
  SELECT SNOWFLAKE.CORTEX.COMPLETE('llama3.3-70b', :p) INTO :memo;
  RETURN memo;
END;
$$;

-- Search corpus is materialised (no policies on it); access controlled by service USAGE grants
CREATE OR REPLACE TABLE AI.SEARCH_CORPUS AS
WITH cust AS (
  SELECT x.CUSTOMER_ID, c.COMPANY_NAME, c.RM_ID
  FROM SILVER.ENTITY_XREF x JOIN SILVER.CORE_CUSTOMERS c ON c.CIF_NO = x.SOURCE_ID
  WHERE x.SOURCE_SYSTEM = 'CORE')
SELECT n.NOTE_ID AS DOC_ID, 'RM_NOTE' AS DOC_TYPE, n.CUSTOMER_ID, k.COMPANY_NAME, k.RM_ID, n.NOTE_DATE AS DOC_DATE, n.NOTE_TEXT AS CONTENT
FROM AI.RM_NOTE_INSIGHTS n JOIN cust k ON k.CUSTOMER_ID = n.CUSTOMER_ID
UNION ALL
SELECT t.DOC_ID, t.DOC_TYPE, t.CUSTOMER_ID, k.COMPANY_NAME, k.RM_ID, t.DOC_DATE, t.DOC_TEXT
FROM SILVER.TF_DOCS t JOIN cust k ON k.CUSTOMER_ID = t.CUSTOMER_ID;

CREATE OR REPLACE CORTEX SEARCH SERVICE AI.RM_TF_SEARCH
  ON CONTENT
  ATTRIBUTES DOC_TYPE, CUSTOMER_ID, COMPANY_NAME, RM_ID
  WAREHOUSE = SME_WH
  TARGET_LAG = '1 day'
  AS (SELECT DOC_ID, DOC_TYPE, CUSTOMER_ID, COMPANY_NAME, RM_ID, DOC_DATE, CONTENT FROM SME_BANK_DB.AI.SEARCH_CORPUS);

-- ============================================================
-- SECTION 12: SEMANTIC VIEW (Cortex Analyst natural-language Q&A)
-- ============================================================
CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML(
'SME_BANK_DB.GOLD',
$$
name: SME_PORTFOLIO_SEMANTIC_VIEW
description: SME business banking portfolio for a Malaysian bank - exposure, NPL, PD scores, applications and cash-flow signals. Amounts in MYR.
tables:
  - name: CUSTOMERS
    description: One row per SME business customer (golden record after entity resolution).
    base_table:
      database: SME_BANK_DB
      schema: GOLD
      table: CUSTOMER_360_SCORED
    primary_key:
      columns:
        - CUSTOMER_ID
    dimensions:
      - name: CUSTOMER_ID
        expr: CUSTOMER_ID
        data_type: VARCHAR
        description: Golden SME customer identifier.
        synonyms: [customer, client id, pelanggan]
      - name: COMPANY_NAME
        expr: COMPANY_NAME
        data_type: VARCHAR
        description: Registered company name.
        synonyms: [company, business name, syarikat, SME name]
      - name: INDUSTRY
        expr: INDUSTRY
        data_type: VARCHAR
        description: Industry sector.
        synonyms: [sector, industri]
        sample_values: [Manufacturing, Wholesale & Retail, Food & Beverage, Construction, Electronics, Agriculture]
      - name: STATE
        expr: STATE
        data_type: VARCHAR
        description: Malaysian state of the business.
        synonyms: [negeri, location, region]
        sample_values: [Selangor, WP Kuala Lumpur, Johor, Pulau Pinang, Sabah]
      - name: RM_ID
        expr: RM_ID
        data_type: VARCHAR
        description: Relationship manager responsible for the customer.
        synonyms: [relationship manager, RM]
      - name: NPL_FLAG
        expr: NPL_FLAG
        data_type: BOOLEAN
        description: TRUE if any loan of the customer is 90+ days past due (non-performing).
        synonyms: [non performing, defaulted, impaired, pinjaman tidak berbayar]
    time_dimensions:
      - name: LAST_RM_CONTACT_DATE
        expr: LAST_RM_CONTACT_DATE
        data_type: DATE
        description: Date of the most recent RM call or visit.
    facts:
      - name: YEARS_IN_BUSINESS
        expr: YEARS_IN_BUSINESS
        data_type: NUMBER
        description: Years since incorporation.
      - name: ANNUAL_TURNOVER_MYR
        expr: ANNUAL_TURNOVER_MYR
        data_type: NUMBER
        description: Annual turnover in MYR.
        synonyms: [revenue, sales, jualan]
      - name: TOTAL_OUTSTANDING_MYR
        expr: TOTAL_OUTSTANDING_MYR
        data_type: NUMBER
        description: Total outstanding loan balance in MYR.
        synonyms: [exposure, balance, outstanding]
      - name: NPL_OUTSTANDING_MYR
        expr: NPL_OUTSTANDING_MYR
        data_type: NUMBER
        description: Outstanding balance on non-performing loans in MYR.
      - name: OD_UTILISATION
        expr: OD_UTILISATION
        data_type: NUMBER
        description: Overdraft utilisation ratio (0-1).
      - name: INFLOW_TREND_PCT
        expr: INFLOW_TREND_PCT
        data_type: NUMBER
        description: Percent change of cash inflows in last 90 days vs prior 90 days.
        synonyms: [cash flow trend, inflow change]
      - name: MERCHANT_VOL_90D_MYR
        expr: MERCHANT_VOL_90D_MYR
        data_type: NUMBER
        description: Merchant acquiring (DuitNow QR / card) volume in last 90 days, MYR.
      - name: CTOS_SCORE
        expr: CTOS_SCORE
        data_type: NUMBER
        description: CTOS credit bureau score (300-850).
        synonyms: [bureau score, credit score]
      - name: RELATED_PARTY_NPL_CNT
        expr: RELATED_PARTY_NPL_CNT
        data_type: NUMBER
        description: Number of related companies (shared directors/guarantors) that are NPL.
      - name: AVG_DECISION_DAYS
        expr: AVG_DECISION_DAYS
        data_type: NUMBER
        description: Average loan decision turnaround in days.
    metrics:
      - name: TOTAL_EXPOSURE_MYR
        expr: SUM(TOTAL_OUTSTANDING_MYR)
        description: Total SME loan exposure in MYR.
      - name: NPL_RATIO
        expr: SUM(NPL_OUTSTANDING_MYR) / NULLIF(SUM(TOTAL_OUTSTANDING_MYR), 0)
        description: Gross NPL ratio = NPL outstanding / total outstanding.
        synonyms: [gross impaired loan ratio, GIL ratio]
      - name: SME_COUNT
        expr: COUNT(DISTINCT CUSTOMER_ID)
        description: Number of SME customers.
  - name: LOANS
    description: One row per disbursed SME loan facility.
    base_table:
      database: SME_BANK_DB
      schema: GOLD
      table: V_FACT_LOAN_SECURE
    primary_key:
      columns:
        - LOAN_ID
    dimensions:
      - name: LOAN_ID
        expr: LOAN_ID
        data_type: VARCHAR
        description: Loan identifier.
      - name: CUSTOMER_ID
        expr: CUSTOMER_ID
        data_type: VARCHAR
        description: Borrower customer id.
      - name: PRODUCT
        expr: PRODUCT
        data_type: VARCHAR
        description: Facility type.
        synonyms: [facility, loan type, produk]
        sample_values: [Term Loan, Overdraft, Trade Line, SJPP-Guaranteed Term Loan, BNM Fund for SMEs]
      - name: LOAN_STATUS
        expr: LOAN_STATUS
        data_type: VARCHAR
        description: Performing, Special mention (30-89 dpd) or NPL (impaired, 90+ dpd).
        sample_values: [Performing, Special mention, NPL (impaired)]
      - name: IS_NPL
        expr: IS_NPL
        data_type: BOOLEAN
        description: TRUE when current days past due is 90 or more.
      - name: COLLATERAL_TYPE
        expr: COLLATERAL_TYPE
        data_type: VARCHAR
        description: Security type.
    time_dimensions:
      - name: ORIGINATION_DATE
        expr: ORIGINATION_DATE
        data_type: DATE
        description: Disbursement date.
    facts:
      - name: PRINCIPAL_MYR
        expr: PRINCIPAL_MYR
        data_type: NUMBER
        description: Original principal in MYR.
      - name: OUTSTANDING_MYR
        expr: OUTSTANDING_MYR
        data_type: NUMBER
        description: Current outstanding balance in MYR.
      - name: CURRENT_DPD
        expr: CURRENT_DPD
        data_type: NUMBER
        description: Current days past due.
        synonyms: [days past due, tunggakan]
      - name: INTEREST_RATE_PCT
        expr: INTEREST_RATE_PCT
        data_type: NUMBER
        description: Interest rate percent per annum.
    metrics:
      - name: LOAN_COUNT
        expr: COUNT(LOAN_ID)
        description: Number of loans.
  - name: APPLICATIONS
    description: Loan applications from the loan origination system.
    base_table:
      database: SME_BANK_DB
      schema: GOLD
      table: V_FACT_APPLICATION_SECURE
    primary_key:
      columns:
        - APPLICATION_ID
    dimensions:
      - name: APPLICATION_ID
        expr: APPLICATION_ID
        data_type: VARCHAR
        description: Application identifier.
      - name: CUSTOMER_ID
        expr: CUSTOMER_ID
        data_type: VARCHAR
        description: Applicant customer id.
      - name: PRODUCT
        expr: PRODUCT
        data_type: VARCHAR
        description: Product applied for.
      - name: STATUS
        expr: STATUS
        data_type: VARCHAR
        description: Application status.
        sample_values: [Approved, Declined, Pending]
      - name: REASON_CODE
        expr: REASON_CODE
        data_type: VARCHAR
        description: Decline reason.
    time_dimensions:
      - name: SUBMITTED_AT
        expr: SUBMITTED_AT
        data_type: TIMESTAMP_NTZ
        description: Submission timestamp.
    facts:
      - name: AMOUNT_REQUESTED_MYR
        expr: AMOUNT_REQUESTED_MYR
        data_type: NUMBER
        description: Amount requested in MYR.
      - name: DECISION_DAYS
        expr: DECISION_DAYS
        data_type: NUMBER
        description: Days from submission to credit decision.
        synonyms: [turnaround time, TAT, time to decision]
    metrics:
      - name: AVG_TIME_TO_DECISION_DAYS
        expr: AVG(DECISION_DAYS)
        description: Average loan approval turnaround in days.
      - name: APPROVAL_RATE
        expr: COUNT_IF(STATUS = 'Approved') / NULLIF(COUNT_IF(STATUS IN ('Approved','Declined')), 0)
        description: Approved / decided applications.
  - name: PD_SCORES
    description: Machine-learning 12-month probability of default per SME, with bands and early-warning flags.
    base_table:
      database: SME_BANK_DB
      schema: ML
      table: V_PD_SCORES_SECURE
    primary_key:
      columns:
        - CUSTOMER_ID
    dimensions:
      - name: CUSTOMER_ID
        expr: CUSTOMER_ID
        data_type: VARCHAR
        description: Scored customer id.
      - name: RISK_BAND
        expr: RISK_BAND
        data_type: VARCHAR
        description: PD band A (lowest risk) to E (highest).
        sample_values: [A, B, C, D, E]
      - name: EARLY_WARNING_FLAG
        expr: EARLY_WARNING_FLAG
        data_type: BOOLEAN
        description: TRUE if a performing customer shows deterioration and should be on the watchlist.
        synonyms: [watchlist, early warning, EWS]
      - name: NEXT_BEST_ACTION
        expr: NEXT_BEST_ACTION
        data_type: VARCHAR
        description: Recommended product or risk action.
      - name: RISK_DRIVERS
        expr: RISK_DRIVERS
        data_type: VARCHAR
        description: Reason codes behind the score.
    facts:
      - name: PD
        expr: PD
        data_type: FLOAT
        description: 12-month probability of default (0-1).
        synonyms: [probability of default, default risk]
    metrics:
      - name: AVG_PD
        expr: AVG(PD)
        description: Average probability of default.
relationships:
  - name: LOANS_TO_CUSTOMERS
    left_table: LOANS
    right_table: CUSTOMERS
    relationship_columns:
      - left_column: CUSTOMER_ID
        right_column: CUSTOMER_ID
    join_type: inner
    relationship_type: many_to_one
  - name: APPLICATIONS_TO_CUSTOMERS
    left_table: APPLICATIONS
    right_table: CUSTOMERS
    relationship_columns:
      - left_column: CUSTOMER_ID
        right_column: CUSTOMER_ID
    join_type: inner
    relationship_type: many_to_one
  - name: PD_TO_CUSTOMERS
    left_table: PD_SCORES
    right_table: CUSTOMERS
    relationship_columns:
      - left_column: CUSTOMER_ID
        right_column: CUSTOMER_ID
    join_type: inner
    relationship_type: many_to_one
$$
);

-- ============================================================
-- SECTION 13: CORTEX AGENT + SNOWFLAKE INTELLIGENCE
-- ============================================================
-- If agent DDL differs in your account version, create the same agent in Snowsight: AI & ML > Agents.
CREATE OR REPLACE AGENT AI.SME_CREDIT_AGENT
  COMMENT = 'SME Credit Copilot for CRO, credit analysts and RMs'
  PROFILE = '{"display_name": "SME Credit Copilot"}'
  FROM SPECIFICATION
$$
models:
  orchestration: auto
instructions:
  response: "Answer concisely for bank credit and relationship staff. Amounts in MYR. Show tables for lists. State that AI output is decision support; credit decisions follow the bank credit policy."
  orchestration: "Use portfolio_analyst for numbers, ratios, rankings and lists. Use rm_tf_search for what RMs said or what trade documents contain. Use credit_memo when asked to draft a credit memo or relationship summary for a specific CUSTOMER_ID (e.g. SME000123); look up the CUSTOMER_ID first if only a company name is given."
  sample_questions:
    - question: "Top 10 watchlist SMEs in Selangor by PD"
    - question: "What is the NPL ratio by industry?"
    - question: "Summarise RM concerns about cash flow stress this quarter"
    - question: "Which trade finance documents have discrepancies?"
    - question: "Draft a credit memo for the highest-PD customer with a pending application"
tools:
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "portfolio_analyst"
      description: "SME portfolio metrics: exposure, NPL, PD bands, early warning, applications and turnaround time."
  - tool_spec:
      type: "cortex_search"
      name: "rm_tf_search"
      description: "Search RM call notes and trade finance documents (LCs, invoices)."
  - tool_spec:
      type: "generic"
      name: "credit_memo"
      description: "Generates a draft SME credit memo for one CUSTOMER_ID."
      input_schema:
        type: "object"
        properties:
          CUSTOMER_ID_IN:
            type: "string"
            description: "Golden customer id, e.g. SME000123"
        required: ["CUSTOMER_ID_IN"]
tool_resources:
  portfolio_analyst:
    semantic_view: "SME_BANK_DB.GOLD.SME_PORTFOLIO_SEMANTIC_VIEW"
    execution_environment:
      type: "warehouse"
      warehouse: "SME_WH"
  rm_tf_search:
    name: "SME_BANK_DB.AI.RM_TF_SEARCH"
    max_results: 5
    id_column: "DOC_ID"
    title_column: "COMPANY_NAME"
  credit_memo:
    type: "procedure"
    identifier: "SME_BANK_DB.AI.GENERATE_CREDIT_MEMO"
    execution_environment:
      type: "warehouse"
      warehouse: "SME_WH"
$$;

CREATE SNOWFLAKE INTELLIGENCE IF NOT EXISTS SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;
--ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT ADD AGENT SME_BANK_DB.AI.SME_CREDIT_AGENT;
ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT DROP AGENT SME_BANK_DB.AI.SME_CREDIT_AGENT;
ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT ADD AGENT SME_BANK_DB.AI.SME_CREDIT_AGENT;
-- ============================================================
-- SECTION 14: PERSONA GRANTS (least privilege; secure views only for consumers)
-- ============================================================
GRANT USAGE ON DATABASE SME_BANK_DB TO ROLE DATA_ENGINEER;
GRANT USAGE ON DATABASE SME_BANK_DB TO ROLE CREDIT_ANALYST;
GRANT USAGE ON DATABASE SME_BANK_DB TO ROLE RM_USER;
GRANT USAGE ON DATABASE SME_BANK_DB TO ROLE AUDITOR;

-- Data engineer: pipeline tables, PII tables only via secure views
GRANT USAGE ON SCHEMA RAW TO ROLE DATA_ENGINEER;
GRANT USAGE ON SCHEMA SILVER TO ROLE DATA_ENGINEER;
GRANT USAGE ON SCHEMA GOLD TO ROLE DATA_ENGINEER;
GRANT SELECT ON ALL TABLES IN SCHEMA RAW TO ROLE DATA_ENGINEER;
GRANT SELECT ON ALL TABLES IN SCHEMA SILVER TO ROLE DATA_ENGINEER;
REVOKE SELECT ON TABLE RAW.CRM_DIRECTORS FROM ROLE DATA_ENGINEER;
REVOKE SELECT ON TABLE RAW.CORE_CUSTOMERS FROM ROLE DATA_ENGINEER;
REVOKE SELECT ON TABLE RAW.LOS_CUSTOMERS FROM ROLE DATA_ENGINEER;
REVOKE SELECT ON TABLE SILVER.DIRECTORS FROM ROLE DATA_ENGINEER;
REVOKE SELECT ON TABLE SILVER.RELATED_PARTY_LINKS FROM ROLE DATA_ENGINEER;
REVOKE SELECT ON TABLE SILVER.CORE_CUSTOMERS FROM ROLE DATA_ENGINEER;
REVOKE SELECT ON TABLE SILVER.BUREAU FROM ROLE DATA_ENGINEER;
GRANT SELECT ON VIEW RAW.V_CRM_DIRECTORS_SECURE TO ROLE DATA_ENGINEER;
GRANT SELECT ON VIEW GOLD.CUSTOMER_360_SCORED TO ROLE DATA_ENGINEER;
GRANT SELECT ON DYNAMIC TABLE GOLD.FACT_TXN_DAILY TO ROLE DATA_ENGINEER;
GRANT MONITOR ON ALL TASKS IN SCHEMA RAW TO ROLE DATA_ENGINEER;
GRANT MONITOR ON ALL TASKS IN SCHEMA SILVER TO ROLE DATA_ENGINEER;

-- Consumers
GRANT USAGE ON SCHEMA GOLD TO ROLE CREDIT_ANALYST;
GRANT USAGE ON SCHEMA GOLD TO ROLE RM_USER;
GRANT USAGE ON SCHEMA GOLD TO ROLE AUDITOR;
GRANT USAGE ON SCHEMA ML TO ROLE CREDIT_ANALYST;
GRANT USAGE ON SCHEMA ML TO ROLE RM_USER;
GRANT USAGE ON SCHEMA ML TO ROLE AUDITOR;
GRANT USAGE ON SCHEMA AI TO ROLE CREDIT_ANALYST;
GRANT USAGE ON SCHEMA AI TO ROLE RM_USER;
GRANT USAGE ON SCHEMA GOV TO ROLE AUDITOR;
GRANT SELECT ON TABLE GOV.PII_INVENTORY TO ROLE AUDITOR;
GRANT SELECT ON VIEW GOLD.CUSTOMER_360_SCORED TO ROLE CREDIT_ANALYST;
GRANT SELECT ON VIEW GOLD.CUSTOMER_360_SCORED TO ROLE RM_USER;
GRANT SELECT ON VIEW GOLD.CUSTOMER_360_SCORED TO ROLE AUDITOR;
GRANT SELECT ON VIEW GOLD.V_FACT_LOAN_SECURE TO ROLE CREDIT_ANALYST;
GRANT SELECT ON VIEW GOLD.V_FACT_LOAN_SECURE TO ROLE RM_USER;
GRANT SELECT ON VIEW GOLD.V_FACT_LOAN_SECURE TO ROLE AUDITOR;
GRANT SELECT ON VIEW GOLD.V_FACT_APPLICATION_SECURE TO ROLE CREDIT_ANALYST;
GRANT SELECT ON VIEW GOLD.V_FACT_APPLICATION_SECURE TO ROLE RM_USER;
GRANT SELECT ON VIEW GOLD.V_FACT_APPLICATION_SECURE TO ROLE AUDITOR;
GRANT SELECT ON VIEW GOLD.V_DIM_DIRECTOR_SECURE TO ROLE CREDIT_ANALYST;
GRANT SELECT ON VIEW GOLD.V_DIM_DIRECTOR_SECURE TO ROLE AUDITOR;
GRANT SELECT ON VIEW ML.V_PD_SCORES_SECURE TO ROLE CREDIT_ANALYST;
GRANT SELECT ON VIEW ML.V_PD_SCORES_SECURE TO ROLE RM_USER;
GRANT SELECT ON VIEW ML.V_PD_SCORES_SECURE TO ROLE AUDITOR;
GRANT SELECT ON VIEW ML.V_EARLY_WARNING_WATCHLIST TO ROLE CREDIT_ANALYST;
GRANT SELECT ON VIEW ML.V_EARLY_WARNING_WATCHLIST TO ROLE RM_USER;
GRANT SELECT ON TABLE ML.MODEL_METRICS TO ROLE CREDIT_ANALYST;
GRANT SELECT ON TABLE ML.MODEL_METRICS TO ROLE AUDITOR;
GRANT SELECT ON SEMANTIC VIEW GOLD.SME_PORTFOLIO_SEMANTIC_VIEW TO ROLE CREDIT_ANALYST;
GRANT SELECT ON SEMANTIC VIEW GOLD.SME_PORTFOLIO_SEMANTIC_VIEW TO ROLE RM_USER;
GRANT USAGE ON PROCEDURE AI.GENERATE_CREDIT_MEMO(STRING) TO ROLE CREDIT_ANALYST;
GRANT SELECT ON VIEW AI.V_CREDIT_MEMO_PROMPT TO ROLE CREDIT_ANALYST;
GRANT USAGE ON PROCEDURE AI.GENERATE_CREDIT_MEMO(STRING) TO ROLE RM_USER;
GRANT SELECT ON VIEW AI.V_CREDIT_MEMO_PROMPT TO ROLE RM_USER;
GRANT USAGE ON CORTEX SEARCH SERVICE AI.RM_TF_SEARCH TO ROLE CREDIT_ANALYST;
GRANT USAGE ON CORTEX SEARCH SERVICE AI.RM_TF_SEARCH TO ROLE RM_USER;
GRANT USAGE ON AGENT AI.SME_CREDIT_AGENT TO ROLE CREDIT_ANALYST;
GRANT USAGE ON AGENT AI.SME_CREDIT_AGENT TO ROLE RM_USER;

-- ============================================================
-- SECTION 15: START PIPELINES (children before parents)
-- ============================================================
--USE ROLE SME_ADMIN;
--ALTER TASK SME_BANK_DB.GOLD.TASK_REFRESH_360 SUSPEND;
--ALTER TASK SME_BANK_DB.GOLD.TASK_SCORE_PD RESUME;
--ALTER TASK SME_BANK_DB.GOLD.TASK_REFRESH_360 RESUME;

SHOW TASKS IN DATABASE SME_BANK_DB; 

ALTER TASK GOLD.TASK_SCORE_PD RESUME;
ALTER TASK GOLD.TASK_REFRESH_360 RESUME;
ALTER TASK SILVER.TASK_TXN_STREAM_TO_SILVER RESUME;
ALTER TASK RAW.TASK_SIMULATE_TXN_FEED RESUME;

-- ============================================================
-- SECTION 16: VALIDATION + DEMO QUERIES
-- ============================================================
-- Ingestion lineage
SELECT 'CORE_CUSTOMERS' t, COUNT(*) n FROM RAW.CORE_CUSTOMERS UNION ALL
SELECT 'LOS_APPLICATIONS', COUNT(*) FROM RAW.LOS_APPLICATIONS UNION ALL
SELECT 'CORE_REPAYMENTS', COUNT(*) FROM RAW.CORE_REPAYMENTS UNION ALL
SELECT 'BUREAU_RAW', COUNT(*) FROM RAW.BUREAU_RAW UNION ALL
SELECT 'TXN_EVENTS (silver)', COUNT(*) FROM SILVER.TXN_EVENTS;

-- Entity resolution results
SELECT SOURCE_SYSTEM, MATCH_RULE, COUNT(*) AS RECORDS, ROUND(AVG(MATCH_SCORE), 1) AS AVG_SCORE
FROM SILVER.ENTITY_XREF GROUP BY 1, 2 ORDER BY 1, 2;
SELECT COUNT(*) AS UNRESOLVED_FOR_STEWARD FROM SILVER.V_ER_UNRESOLVED;

-- Portfolio headline
SELECT COUNT(*) AS SMES, SUM(TOTAL_OUTSTANDING_MYR) AS EXPOSURE_MYR,
       ROUND(DIV0(SUM(NPL_OUTSTANDING_MYR), SUM(TOTAL_OUTSTANDING_MYR)) * 100, 2) AS NPL_RATIO_PCT,
       COUNT_IF(EARLY_WARNING_FLAG) AS WATCHLIST, ROUND(AVG(AVG_DECISION_DAYS), 1) AS AVG_TAT_DAYS
FROM GOLD.CUSTOMER_360_SCORED;

-- Model quality + drivers
SELECT * FROM ML.MODEL_METRICS ORDER BY TRAINED_AT DESC LIMIT 1;
SELECT FEATURE, ROUND(IMPORTANCE, 3) AS IMPORTANCE FROM ML.FEATURE_IMPORTANCE
WHERE MODEL_VERSION = (SELECT MAX(MODEL_VERSION) FROM ML.FEATURE_IMPORTANCE) ORDER BY IMPORTANCE DESC;
SELECT * FROM ML.V_EARLY_WARNING_WATCHLIST LIMIT 10;

-- Same query, three personas (masking + row filter via secure views)
USE ROLE CREDIT_ANALYST;
SELECT CUSTOMER_ID, RM_ID, SSM_REG_NO, CTOS_SCORE, TOTAL_OUTSTANDING_MYR FROM SME_BANK_DB.GOLD.CUSTOMER_360_SCORED ORDER BY CUSTOMER_ID LIMIT 5;
SELECT NRIC, DIRECTOR_NAME, DOB FROM SME_BANK_DB.GOLD.V_DIM_DIRECTOR_SECURE LIMIT 3;
USE ROLE RM_USER;
SELECT CUSTOMER_ID, RM_ID, SSM_REG_NO, CTOS_SCORE, TOTAL_OUTSTANDING_MYR FROM SME_BANK_DB.GOLD.CUSTOMER_360_SCORED ORDER BY CUSTOMER_ID LIMIT 5;
SELECT COUNT(*) AS VISIBLE_CUSTOMERS FROM SME_BANK_DB.GOLD.CUSTOMER_360_SCORED;
USE ROLE DATA_ENGINEER;
SELECT CUSTOMER_ID, RM_ID, SSM_REG_NO, CTOS_SCORE, TOTAL_OUTSTANDING_MYR FROM SME_BANK_DB.GOLD.CUSTOMER_360_SCORED ORDER BY CUSTOMER_ID LIMIT 5;
SELECT NRIC, DIRECTOR_NAME FROM SME_BANK_DB.RAW.V_CRM_DIRECTORS_SECURE LIMIT 3;
USE ROLE SME_ADMIN;

-- PII inventory
SELECT * FROM GOV.PII_INVENTORY;

-- Cortex: memo for highest-risk performing customer, search preview
SET top_id = (SELECT CUSTOMER_ID FROM ML.V_EARLY_WARNING_WATCHLIST LIMIT 1);
CALL AI.GENERATE_CREDIT_MEMO($top_id);
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW('SME_BANK_DB.AI.RM_TF_SEARCH',
  '{"query": "buyer delayed payment cash flow tight", "columns": ["DOC_ID","COMPANY_NAME","CONTENT"], "limit": 3}');

-- Near-real-time: push events, then watch the dynamic table move
CALL RAW.SIMULATE_TXN_FEED(500);
CALL SILVER.LOAD_TXN_EVENTS();
SELECT MAX(TXN_DATE), SUM(TXN_CNT) FROM GOLD.FACT_TXN_DAILY;

-- ============================================================
-- SECTION 17: COST GUARD (run after the demo)
-- ============================================================
-- ALTER TASK RAW.TASK_SIMULATE_TXN_FEED SUSPEND;
-- ALTER TASK SILVER.TASK_TXN_STREAM_TO_SILVER SUSPEND;
-- ALTER TASK GOLD.TASK_REFRESH_360 SUSPEND;
-- ALTER DYNAMIC TABLE GOLD.FACT_TXN_DAILY SUSPEND;
-- ALTER CORTEX SEARCH SERVICE AI.RM_TF_SEARCH SUSPEND INDEXING;

