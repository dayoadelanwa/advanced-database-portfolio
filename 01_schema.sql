-- =====================================================================
-- MIT 8103 Portfolio 1: Database Design and Modelling
-- Case study: DayoKoboLedger (simulated Nigerian digital-wallet fintech)
-- DBMS: PostgreSQL 16
-- Run:  psql -U postgres -d koboledger -f 01_schema.sql
-- =====================================================================

DROP SCHEMA IF EXISTS kobo CASCADE;
CREATE SCHEMA kobo;
SET search_path TO kobo;

-- ---------------------------------------------------------------------
-- 1. KYC_TIER  (lookup table)
-- Why separate? Limits depend on the TIER, not on the customer.
-- Keeping daily_limit inside CUSTOMER would create the transitive
-- dependency customer_id -> kyc_tier -> daily_limit (a 3NF violation).
-- ---------------------------------------------------------------------
CREATE TABLE kyc_tier (
    tier            SMALLINT      PRIMARY KEY CHECK (tier BETWEEN 1 AND 3),
    description     VARCHAR(100)  NOT NULL,
    daily_limit     NUMERIC(18,2) NOT NULL CHECK (daily_limit > 0),
    max_balance     NUMERIC(18,2)          CHECK (max_balance > 0)  -- NULL = no cap
);

-- ---------------------------------------------------------------------
-- 2. CUSTOMER
-- Surrogate PK (customer_id) + natural candidate keys (bvn, email, phone)
-- enforced with UNIQUE. Every determinant is a candidate key -> BCNF.
-- ---------------------------------------------------------------------
CREATE TABLE customer (
    customer_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bvn             CHAR(11)      NOT NULL UNIQUE CHECK (bvn ~ '^[0-9]{11}$'),
    first_name      VARCHAR(50)   NOT NULL,
    last_name       VARCHAR(50)   NOT NULL,
    email           VARCHAR(120)  NOT NULL UNIQUE,
    phone           VARCHAR(14)   NOT NULL UNIQUE,
    date_of_birth   DATE          NOT NULL CHECK (date_of_birth <= CURRENT_DATE - INTERVAL '18 years'),
    kyc_tier        SMALLINT      NOT NULL DEFAULT 1 REFERENCES kyc_tier(tier),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 3. ACCOUNT  (one customer -> many accounts)
-- Holds two kinds of account:
--   * customer accounts (WALLET/SAVINGS/CURRENT): owned by a customer
--   * internal GL accounts (GL): owned by KoboLedger itself, e.g. the
--     "NIP Outward Settlement" account. Money leaving to another bank is
--     credited HERE, so every ledger row still points at a real account
--     and referential integrity is preserved.
-- balance is a deliberate, controlled DENORMALISATION: it could be derived
-- from SUM(ledger_entry), but reading it on every transfer would be slow.
-- Integrity is protected by CHECKs and by only changing it inside
-- transactions (Portfolio 3).
-- ---------------------------------------------------------------------
CREATE TABLE account (
    account_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_number  CHAR(10)      NOT NULL UNIQUE CHECK (account_number ~ '^[0-9]{10}$'), -- NUBAN
    customer_id     BIGINT        REFERENCES customer(customer_id) ON DELETE RESTRICT,     -- NULL only for GL
    account_type    VARCHAR(10)   NOT NULL CHECK (account_type IN ('WALLET','SAVINGS','CURRENT','GL')),
    account_name    VARCHAR(100),                                   -- e.g. 'NIP Outward Settlement'
    currency        CHAR(3)       NOT NULL DEFAULT 'NGN',
    balance         NUMERIC(18,2) NOT NULL DEFAULT 0,
    status          VARCHAR(10)   NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','FROZEN','CLOSED')),
    opened_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    -- a GL account has no customer; every customer account must have one
    CONSTRAINT gl_has_no_customer CHECK ((account_type = 'GL') = (customer_id IS NULL)),
    -- customers cannot be overdrawn; GL accounts may carry either sign
    CONSTRAINT no_customer_overdraft CHECK (account_type = 'GL' OR balance >= 0)
);

-- ---------------------------------------------------------------------
-- 3b. EXTERNAL_COUNTERPARTY  (accounts at OTHER banks)
-- These are not our accounts, so they never appear in ACCOUNT or
-- LEDGER_ENTRY. We store only what we need to describe the beneficiary
-- (from the NIP name-enquiry response).
-- ---------------------------------------------------------------------
CREATE TABLE external_counterparty (
    counterparty_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bank_code       VARCHAR(6)    NOT NULL,                 -- destination bank's institution code
    bank_name       VARCHAR(60)   NOT NULL,
    account_number  CHAR(10)      NOT NULL CHECK (account_number ~ '^[0-9]{10}$'),
    account_name    VARCHAR(100)  NOT NULL,                 -- as returned by name enquiry
    UNIQUE (bank_code, account_number)                      -- NUBANs are only unique WITHIN a bank
);

-- ---------------------------------------------------------------------
-- 4. TXN  (the business event: "Ada sent N5,000 to Musa")
-- reversal_of is a self-referencing FK: a REVERSAL points at the
-- transaction it undoes (supports "reverse failed transactions").
-- ---------------------------------------------------------------------
CREATE TABLE txn (
    txn_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reference       VARCHAR(30)   NOT NULL UNIQUE,
    txn_type        VARCHAR(12)   NOT NULL CHECK (txn_type IN ('DEPOSIT','WITHDRAWAL','TRANSFER','REVERSAL')),
    amount          NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    status          VARCHAR(10)   NOT NULL DEFAULT 'PENDING'
                                  CHECK (status IN ('PENDING','SUCCESSFUL','FAILED','REVERSED')),
    narration       VARCHAR(140),
    counterparty_id BIGINT        REFERENCES external_counterparty(counterparty_id), -- NULL = internal transfer
    external_session_id VARCHAR(30) UNIQUE,                        -- switch session ID, for reconciliation
    reversal_of     BIGINT        UNIQUE REFERENCES txn(txn_id),   -- a txn can be reversed at most once
    initiated_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT reversal_has_parent CHECK ((txn_type = 'REVERSAL') = (reversal_of IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- 5. LEDGER_ENTRY  (double-entry book-keeping)
-- A transfer = 1 DEBIT row on the sender + 1 CREDIT row on the receiver.
-- This resolves the M:N relationship between TXN and ACCOUNT.
-- Rule (checked in Portfolio 3): for every txn, SUM(debits) = SUM(credits).
-- ---------------------------------------------------------------------
CREATE TABLE ledger_entry (
    entry_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    txn_id          BIGINT        NOT NULL REFERENCES txn(txn_id),
    account_id      BIGINT        NOT NULL REFERENCES account(account_id),
    direction       CHAR(6)       NOT NULL CHECK (direction IN ('DEBIT','CREDIT')),
    amount          NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    balance_after   NUMERIC(18,2) NOT NULL CHECK (balance_after >= 0),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    UNIQUE (txn_id, account_id, direction)
);

-- ---------------------------------------------------------------------
-- 6. AUDIT_LOG  (who changed what; required for regulated finance / NDPA)
-- old_value/new_value are JSONB: a semi-structured column, which
-- links forward to the NoSQL discussion in Portfolio 4.
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name      VARCHAR(40)   NOT NULL,
    record_id       BIGINT        NOT NULL,
    action          VARCHAR(10)   NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
    changed_by      VARCHAR(60)   NOT NULL DEFAULT current_user,
    changed_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    old_value       JSONB,
    new_value       JSONB
);

-- Foreign-key columns are NOT indexed automatically in PostgreSQL.
-- Leave these for Portfolio 2 so you can show the before/after
-- EXPLAIN ANALYZE difference.
