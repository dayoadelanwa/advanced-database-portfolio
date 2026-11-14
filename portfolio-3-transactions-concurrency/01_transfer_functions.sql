-- =====================================================================
-- MIT 8103 Portfolio 3: Transactions and Concurrency
-- 01: the atomic, concurrency-safe transfer and its reversal.
--
-- Prerequisite: the Portfolio 1 + 2 database (koboledger).
-- Run once in pgAdmin's Query Tool (F5) or psql. Safe to re-run.
-- =====================================================================
SET search_path TO kobo;

-- ------------------------------------------------------- lab accounts
-- Two wallets owned by Ngozi (KYC tier 3, so daily limits never get in the
-- way) used ONLY for the concurrency experiments in 03. A fee-income GL
-- account is used for the SAVEPOINT demo in 02.
INSERT INTO account (account_number, customer_id, account_type, account_name, balance) VALUES
  ('0123456790', 4,    'WALLET', 'Concurrency Lab A', 50000.00),
  ('0123456791', 4,    'WALLET', 'Concurrency Lab B', 50000.00),
  ('9000000004', NULL, 'GL',     'Transfer Fee Income', 0)
ON CONFLICT (account_number) DO NOTHING;

-- Helper view: the accounts used in the demos, with owner and balance
CREATE OR REPLACE VIEW v_demo_balances AS
SELECT a.account_number,
       COALESCE(c.first_name || ' ' || c.last_name, a.account_name) AS owner,
       COALESCE(a.account_name, a.account_type)                     AS account,
       a.balance
FROM account a
LEFT JOIN customer c ON c.customer_id = a.customer_id
WHERE a.account_number IN ('0123456781','0123456783','0123456784','0123456785',
                           '0123456790','0123456791','9000000004')
ORDER BY a.account_number;

-- =====================================================================
-- transfer(): moves money between two KoboLedger accounts.
--
-- A (Atomicity)   : the txn row, both balance updates and both ledger legs
--                   happen in ONE transaction. Any RAISE EXCEPTION undoes
--                   everything already done.
-- C (Consistency) : business rules (active accounts, funds, KYC daily
--                   limit) are checked; CHECK/FK constraints back them up.
-- I (Isolation)   : SELECT ... FOR UPDATE locks both account rows, so a
--                   concurrent transfer from the same account WAITS and then
--                   sees the new balance. No lost update, no double spend.
--                   Rows are locked in account_id order, so two transfers in
--                   opposite directions cannot deadlock.
-- D (Durability)  : guaranteed by PostgreSQL's write-ahead log once the
--                   caller COMMITs.
-- =====================================================================
CREATE OR REPLACE FUNCTION transfer(
    p_from       CHAR(10),
    p_to         CHAR(10),
    p_amount     NUMERIC(18,2),
    p_reference  VARCHAR(30),
    p_narration  VARCHAR(140) DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = kobo
AS $fn$
DECLARE
    v_from   account%ROWTYPE;
    v_to     account%ROWTYPE;
    v_limit  NUMERIC(18,2);
    v_today  NUMERIC(18,2);
    v_txn    BIGINT;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be greater than zero';
    END IF;
    IF p_from = p_to THEN
        RAISE EXCEPTION 'Cannot transfer to the same account';
    END IF;

    -- 1. LOCK both rows, always in the same order (lowest account_id first).
    --    A second transfer touching either account blocks here until we finish.
    PERFORM 1 FROM account
    WHERE account_number IN (p_from, p_to)
    ORDER BY account_id
    FOR UPDATE;

    -- 2. Read the (now locked, therefore current) rows
    SELECT * INTO v_from FROM account WHERE account_number = p_from;
    IF NOT FOUND THEN RAISE EXCEPTION 'Sender account % not found', p_from; END IF;
    SELECT * INTO v_to   FROM account WHERE account_number = p_to;
    IF NOT FOUND THEN RAISE EXCEPTION 'Receiver account % not found', p_to; END IF;

    IF v_from.status <> 'ACTIVE' OR v_to.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Both accounts must be ACTIVE (sender %, receiver %)', v_from.status, v_to.status;
    END IF;

    -- 3. Business rule: sufficient funds (GL accounts are exempt)
    IF v_from.account_type <> 'GL' AND v_from.balance < p_amount THEN
        RAISE EXCEPTION 'Insufficient funds in %: balance %, requested %',
                        p_from, v_from.balance, p_amount;
    END IF;

    -- 4. Business rule: KYC daily limit, per CUSTOMER across all their accounts
    --    (uses the Portfolio 2 index ix_ledger_account_time)
    IF v_from.customer_id IS NOT NULL THEN
        SELECT k.daily_limit INTO v_limit
        FROM customer c JOIN kyc_tier k ON k.tier = c.kyc_tier
        WHERE c.customer_id = v_from.customer_id;

        SELECT COALESCE(SUM(l.amount), 0) INTO v_today
        FROM ledger_entry l
        JOIN txn t ON t.txn_id = l.txn_id
        WHERE l.account_id IN (SELECT account_id FROM account WHERE customer_id = v_from.customer_id)
          AND l.direction  = 'DEBIT'
          AND t.txn_type   = 'TRANSFER'
          AND l.created_at >= date_trunc('day', now());

        IF v_today + p_amount > v_limit THEN
            RAISE EXCEPTION 'KYC daily limit exceeded: tier limit %, already sent today %, requested %',
                            v_limit, v_today, p_amount;
        END IF;
    END IF;

    -- 5. Write: one business event + two balanced ledger legs
    INSERT INTO txn (reference, txn_type, amount, status, narration)
    VALUES (p_reference, 'TRANSFER', p_amount, 'SUCCESSFUL', p_narration)
    RETURNING txn_id INTO v_txn;

    UPDATE account SET balance = balance - p_amount WHERE account_id = v_from.account_id;
    UPDATE account SET balance = balance + p_amount WHERE account_id = v_to.account_id;

    INSERT INTO ledger_entry (txn_id, account_id, direction, amount, balance_after) VALUES
        (v_txn, v_from.account_id, 'DEBIT',  p_amount, v_from.balance - p_amount),
        (v_txn, v_to.account_id,   'CREDIT', p_amount, v_to.balance   + p_amount);

    RETURN v_txn;
END
$fn$;

-- =====================================================================
-- reverse_transfer(): undo a successful transfer (e.g. a dispute).
-- Posts the opposite legs as a new REVERSAL transaction linked through
-- reversal_of, and marks the original as REVERSED.
-- The UNIQUE constraint on txn.reversal_of guarantees a transfer can be
-- reversed only once, even if two staff try at the same moment.
-- =====================================================================
CREATE OR REPLACE FUNCTION reverse_transfer(
    p_reference VARCHAR(30),
    p_reason    VARCHAR(140)
) RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = kobo
AS $fn$
DECLARE
    v_orig   txn%ROWTYPE;
    v_debit  ledger_entry%ROWTYPE;   -- original sender leg
    v_credit ledger_entry%ROWTYPE;   -- original receiver leg
    v_bal_s  NUMERIC(18,2);
    v_bal_r  NUMERIC(18,2);
    v_rev    BIGINT;
BEGIN
    -- Lock the original transaction row: two concurrent reversals queue here
    SELECT * INTO v_orig FROM txn WHERE reference = p_reference FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Transaction % not found', p_reference; END IF;
    IF v_orig.txn_type <> 'TRANSFER' OR v_orig.status <> 'SUCCESSFUL' THEN
        RAISE EXCEPTION 'Only a SUCCESSFUL TRANSFER can be reversed (% is % %)',
                        p_reference, v_orig.status, v_orig.txn_type;
    END IF;

    SELECT * INTO v_debit  FROM ledger_entry WHERE txn_id = v_orig.txn_id AND direction = 'DEBIT';
    SELECT * INTO v_credit FROM ledger_entry WHERE txn_id = v_orig.txn_id AND direction = 'CREDIT';

    -- Lock both accounts in account_id order (same deadlock rule as transfer)
    PERFORM 1 FROM account WHERE account_id IN (v_debit.account_id, v_credit.account_id)
    ORDER BY account_id FOR UPDATE;

    -- Money goes back: debit the original receiver, credit the original sender.
    -- If the receiver has already spent it, the CHECK no_customer_overdraft
    -- fails and the WHOLE reversal is rolled back (atomicity).
    UPDATE account SET balance = balance - v_orig.amount WHERE account_id = v_credit.account_id
    RETURNING balance INTO v_bal_r;
    UPDATE account SET balance = balance + v_orig.amount WHERE account_id = v_debit.account_id
    RETURNING balance INTO v_bal_s;

    INSERT INTO txn (reference, txn_type, amount, status, narration, reversal_of)
    VALUES ('REV-' || p_reference, 'REVERSAL', v_orig.amount, 'SUCCESSFUL', p_reason, v_orig.txn_id)
    RETURNING txn_id INTO v_rev;

    INSERT INTO ledger_entry (txn_id, account_id, direction, amount, balance_after) VALUES
        (v_rev, v_credit.account_id, 'DEBIT',  v_orig.amount, v_bal_r),
        (v_rev, v_debit.account_id,  'CREDIT', v_orig.amount, v_bal_s);

    UPDATE txn SET status = 'REVERSED' WHERE txn_id = v_orig.txn_id;
    RETURN v_rev;
END
$fn$;

SELECT * FROM v_demo_balances;
