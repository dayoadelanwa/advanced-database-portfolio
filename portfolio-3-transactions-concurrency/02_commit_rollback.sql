-- =====================================================================
-- MIT 8103 Portfolio 3: COMMIT, ROLLBACK, automatic rollback, SAVEPOINT,
-- reversal. ONE Query Tool tab (one session).
--
-- HOW TO RUN IN pgAdmin: do NOT press F5 on the whole file.
--   Highlight ONE line (or one statement) at a time and press F5.
--   Keep Auto commit ON: an explicit BEGIN keeps the transaction open
--   until you run COMMIT or ROLLBACK.
-- Screenshot each result marked  📸
-- Run 01_transfer_functions.sql first.
-- =====================================================================
SET search_path TO kobo;

-- ---------------------------------------------------------------------
-- STEP 0: starting balances                                          📸
-- ---------------------------------------------------------------------
SELECT * FROM v_demo_balances;

-- ---------------------------------------------------------------------
-- STEP 1: COMMIT. Ngozi sends Tolu N100,000; the change becomes permanent.
-- ---------------------------------------------------------------------
BEGIN;
SELECT transfer('0123456785', '0123456784', 100000, 'P3-COMMIT-001', 'School fees support');
SELECT * FROM v_demo_balances;          -- Ngozi -100,000, Tolu +100,000 (visible to THIS session only)
COMMIT;
SELECT * FROM v_demo_balances;          -- 📸 now permanent and visible to everyone
SELECT t.reference, t.status, l.direction, l.account_id, l.amount, l.balance_after
FROM txn t JOIN ledger_entry l ON l.txn_id = t.txn_id
WHERE t.reference = 'P3-COMMIT-001';    -- 📸 one event, two balanced legs

-- ---------------------------------------------------------------------
-- STEP 2: explicit ROLLBACK. Ada starts a N50,000 transfer, then cancels.
-- ---------------------------------------------------------------------
BEGIN;
SELECT transfer('0123456781', '0123456783', 50000, 'P3-ROLLBACK-001', 'Cancelled by customer');
SELECT * FROM v_demo_balances;          -- 📸 Ada 175,000 / Musa 135,000 INSIDE the transaction
ROLLBACK;
SELECT * FROM v_demo_balances;          -- 📸 back to Ada 225,000 / Musa 85,000
SELECT count(*) FROM txn WHERE reference = 'P3-ROLLBACK-001';   -- 0: the txn row vanished too

-- ---------------------------------------------------------------------
-- STEP 3: automatic rollback, business rule. Tolu (KYC tier 1, daily limit
-- N50,000) has the money but tries to send N60,000.
-- ---------------------------------------------------------------------
SELECT transfer('0123456784', '0123456783', 60000, 'P3-KYC-001', 'Too much for tier 1');
-- 📸 ERROR: KYC daily limit exceeded ...
SELECT * FROM v_demo_balances;          -- nothing changed

-- ---------------------------------------------------------------------
-- STEP 4: automatic rollback, insufficient funds. Musa has N85,000.
-- ---------------------------------------------------------------------
SELECT transfer('0123456783', '0123456781', 100000, 'P3-NSF-001', 'More than balance');
-- 📸 ERROR: Insufficient funds ...

-- ---------------------------------------------------------------------
-- STEP 5: ATOMICITY. A hand-written transfer where the 2nd step fails.
-- The debit in step 5b SUCCEEDS, then 5c violates a CHECK constraint.
-- ---------------------------------------------------------------------
BEGIN;                                                                         -- 5a
UPDATE account SET balance = balance - 20000 WHERE account_number = '0123456781';  -- 5b ok: UPDATE 1
INSERT INTO ledger_entry (txn_id, account_id, direction, amount, balance_after)
VALUES (1, 1, 'DEBIT', -20000, 205000);                                        -- 5c 📸 ERROR: violates check constraint
SELECT * FROM v_demo_balances;                                                 -- 5d 📸 ERROR: current transaction is aborted
ROLLBACK;                                                                      -- 5e the only command allowed now
SELECT * FROM v_demo_balances;                                                 -- 5f 📸 Ada still 225,000: the debit was undone

-- ---------------------------------------------------------------------
-- STEP 6: SAVEPOINT (partial rollback). Ada pays Musa N10,000; a N50 fee
-- is charged, then waived. Keep the transfer, undo only the fee.
-- ---------------------------------------------------------------------
BEGIN;
SELECT transfer('0123456781', '0123456783', 10000, 'P3-SAVEPOINT-001', 'Rent share');
SAVEPOINT before_fee;
SELECT transfer('0123456781', '9000000004', 50, 'P3-FEE-001', 'Transfer fee');
SELECT * FROM v_demo_balances;          -- 📸 Ada -10,050, fee income +50
ROLLBACK TO SAVEPOINT before_fee;       -- fee waived
COMMIT;
SELECT * FROM v_demo_balances;          -- 📸 Ada -10,000 only; fee income back to 0
SELECT reference FROM txn WHERE reference IN ('P3-SAVEPOINT-001','P3-FEE-001');  -- only the transfer exists

-- ---------------------------------------------------------------------
-- STEP 7: reversing a committed transaction (COMMIT cannot be undone by
-- ROLLBACK; a correcting transaction is posted instead).
-- ---------------------------------------------------------------------
SELECT reverse_transfer('P3-SAVEPOINT-001', 'Customer dispute: wrong recipient');
SELECT reference, txn_type, status, reversal_of FROM txn
WHERE reference IN ('P3-SAVEPOINT-001', 'REV-P3-SAVEPOINT-001');   -- 📸 original REVERSED, linked reversal
SELECT reverse_transfer('P3-SAVEPOINT-001', 'Second attempt');
-- 📸 ERROR: Only a SUCCESSFUL TRANSFER can be reversed: no double refund

-- ---------------------------------------------------------------------
-- STEP 8: CONSISTENCY check after everything above. Expect 0 rows.
-- ---------------------------------------------------------------------
SELECT txn_id FROM ledger_entry GROUP BY txn_id
HAVING SUM(CASE direction WHEN 'DEBIT' THEN amount ELSE -amount END) <> 0;    -- 📸
