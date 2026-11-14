-- =====================================================================
-- MIT 8103 Portfolio 2: generate realistic data volume
-- Indexes only matter at scale. With 7 rows every plan is a seq scan.
-- Produces approx: 50,000 customers, 70,000 accounts, 570,000 transactions,
-- 1.1 million ledger entries. Takes 1-3 minutes on a laptop.
--
-- Prerequisite: a FRESH Portfolio 1 database (run 01_schema.sql and
-- 02_seed.sql first; 01_schema.sql drops and recreates everything).
--
-- Works in psql AND in GUI clients (pgAdmin, DBeaver, DataGrip):
--   * no psql-only commands (\timing, \gset, :variables)
--   * uses ordinary work tables (gen_*), not TEMP tables, because a
--     TEMP table only exists in the session that created it, and GUI
--     clients may run statements on different sessions
-- In a GUI, run it with "Execute script" (pgAdmin: F5 with nothing selected),
-- not "Execute current statement", and with auto-commit ON.
--
-- psql:  psql -d koboledger -f 01_generate_data.sql
-- =====================================================================
SET search_path TO kobo;

-- Guard: stop if the data was already generated (would duplicate rows)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM kobo.account WHERE account_number = '9000000003') THEN
    RAISE EXCEPTION 'Data already generated. Re-run Portfolio 1 01_schema.sql and 02_seed.sql first, then this script.';
  END IF;
END $$;

SELECT setseed(0.42);   -- repeatable "random" data

-- Clean up work tables from any earlier, interrupted run
DROP TABLE IF EXISTS gen_dep, gen_acc, gen_tr;

-- GL account that is debited for every cash deposit
INSERT INTO account (account_number, customer_id, account_type, account_name)
VALUES ('9000000003', NULL, 'GL', 'Cash Deposits Control');

-- ---------------------------------------------------------------- customers
INSERT INTO customer (bvn, first_name, last_name, email, phone, date_of_birth, kyc_tier, created_at)
SELECT lpad((22200000000 + g)::text, 11, '0'),
       (ARRAY['Ada','Musa','Tolu','Ngozi','Emeka','Fatima','Chidi','Aisha',
              'Bola','Ifeanyi','Zainab','Segun','Halima','Kunle','Amaka','Yusuf'])[1 + floor(random()*16)::int],
       (ARRAY['Okafor','Bello','Adeyemi','Eze','Ibrahim','Nwosu','Okonkwo','Abubakar',
              'Balogun','Obi','Lawal','Danjuma','Ogunleye','Usman','Nnamdi','Akande'])[1 + floor(random()*16)::int],
       'user' || g || '@example.com',
       '+23480' || lpad(g::text, 8, '0'),
       DATE '1960-01-01' + floor(random()*15000)::int,          -- all are 18+
       (ARRAY[1,1,2,2,2,3])[1 + floor(random()*6)::int],          -- more tier 1/2 than 3
       now() - interval '1 year' - random() * interval '2 years'  -- joined 1-3 years ago
FROM generate_series(1, 50000) AS g;

-- ----------------------------------------------------------------- accounts
-- Every new customer gets a wallet; ~40% also open a savings account.
INSERT INTO account (account_number, customer_id, account_type, opened_at)
SELECT lpad((1000000000 + customer_id)::text, 10, '0'), customer_id, 'WALLET', created_at
FROM customer WHERE customer_id > 4;

INSERT INTO account (account_number, customer_id, account_type, opened_at)
SELECT lpad((2000000000 + customer_id)::text, 10, '0'), customer_id, 'SAVINGS', created_at
FROM customer WHERE customer_id > 4 AND random() < 0.4;

-- --------------------------------------------------------- opening deposits
CREATE TABLE gen_dep AS
SELECT account_id, opened_at, round((200000 + random()*1800000)::numeric, 2) AS amt
FROM account WHERE account_type <> 'GL' AND customer_id > 4;

INSERT INTO txn (reference, txn_type, amount, status, narration, initiated_at)
SELECT 'DEP-' || account_id, 'DEPOSIT', amt, 'SUCCESSFUL', 'Opening deposit', opened_at FROM gen_dep;

INSERT INTO ledger_entry (txn_id, account_id, direction, amount, balance_after, created_at)
SELECT t.txn_id, d.account_id, 'CREDIT', d.amt, 0, d.opened_at
FROM gen_dep d JOIN txn t ON t.reference = 'DEP-' || d.account_id
UNION ALL
SELECT t.txn_id, (SELECT account_id FROM account WHERE account_number = '9000000003'), 'DEBIT', d.amt, 0, d.opened_at
FROM gen_dep d JOIN txn t ON t.reference = 'DEP-' || d.account_id;

-- ---------------------------------------------------- 500,000 transfers
-- gen_acc numbers the customer accounts 1..N so we can pick them at random
CREATE TABLE gen_acc AS
SELECT row_number() OVER (ORDER BY account_id) AS rn, account_id
FROM account WHERE account_type <> 'GL' AND customer_id > 4;

CREATE TABLE gen_tr AS
SELECT x.g, s.account_id AS sender, r.account_id AS receiver,
       round((100 + random()*9900)::numeric, 2)            AS amt,
       now() - random() * interval '365 days'               AS ts,
       CASE WHEN random() < 0.03 THEN 'FAILED' ELSE 'SUCCESSFUL' END AS st   -- 3% fail
FROM (SELECT g,
             1 + floor(random() * (SELECT count(*) FROM gen_acc))::int AS a,
             1 + floor(random() * (SELECT count(*) FROM gen_acc))::int AS b
      FROM generate_series(1, 500000) AS g) x
JOIN gen_acc s ON s.rn = x.a
JOIN gen_acc r ON r.rn = x.b
WHERE x.a <> x.b;                                       -- no transfers to self

INSERT INTO txn (reference, txn_type, amount, status, narration, initiated_at)
SELECT 'KL-TR-' || g, 'TRANSFER', amt, st, 'Transfer', ts FROM gen_tr;

-- Only SUCCESSFUL transfers are posted to the ledger (double entry)
INSERT INTO ledger_entry (txn_id, account_id, direction, amount, balance_after, created_at)
SELECT t.txn_id, tr.sender, 'DEBIT', tr.amt, 0, tr.ts
FROM gen_tr tr JOIN txn t ON t.reference = 'KL-TR-' || tr.g WHERE tr.st = 'SUCCESSFUL'
UNION ALL
SELECT t.txn_id, tr.receiver, 'CREDIT', tr.amt, 0, tr.ts
FROM gen_tr tr JOIN txn t ON t.reference = 'KL-TR-' || tr.g WHERE tr.st = 'SUCCESSFUL';

-- ------------------------------------- running balances (window function)
-- balance_after = cumulative (credits - debits) per account, in time order
UPDATE ledger_entry l
SET balance_after = s.bal
FROM (SELECT entry_id,
             SUM(CASE direction WHEN 'CREDIT' THEN amount ELSE -amount END)
               OVER (PARTITION BY account_id ORDER BY created_at, entry_id) AS bal
      FROM ledger_entry
      WHERE account_id >= 8) s          -- skip the hand-made Portfolio 1 seed accounts
WHERE l.entry_id = s.entry_id;

-- account.balance = the latest balance_after (keeps the denormalised column true)
UPDATE account a
SET balance = s.bal
FROM (SELECT DISTINCT ON (account_id) account_id, balance_after AS bal
      FROM ledger_entry WHERE account_id >= 8
      ORDER BY account_id, created_at DESC, entry_id DESC) s
WHERE a.account_id = s.account_id;

-- Work tables are no longer needed
DROP TABLE gen_dep, gen_acc, gen_tr;

-- Refresh planner statistics. ANALYZE is allowed inside a transaction,
-- so this works even when a GUI sends the whole script as one transaction.
ANALYZE;
-- ** AFTER this script finishes, run this ONE line ON ITS OWN: **
--      VACUUM ANALYZE;
-- VACUUM cannot run inside a transaction block. It sets the visibility map
-- that index-only scans (Q2) depend on, and cleans up the dead rows left
-- by the UPDATEs above.

-- --------------------------------------------------------------- summary
SELECT 'customer' AS table_name, count(*) FROM customer
UNION ALL SELECT 'account', count(*) FROM account
UNION ALL SELECT 'txn', count(*) FROM txn
UNION ALL SELECT 'ledger_entry', count(*) FROM ledger_entry;

-- Integrity check: every transaction must balance (expect 0 rows)
SELECT txn_id FROM ledger_entry GROUP BY txn_id
HAVING SUM(CASE direction WHEN 'DEBIT' THEN amount ELSE -amount END) <> 0;
