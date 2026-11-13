-- =====================================================================
-- Portfolio 1: constraint tests. EVERY statement below SHOULD FAIL.
-- Screenshot each error: it is your evidence that the constraints work.
-- Run:  psql -U postgres -d koboledger -f 03_constraint_tests.sql
-- =====================================================================
SET search_path TO kobo;
\set ON_ERROR_STOP off

\echo '--- Test 1: negative balance (CHECK balance >= 0)'
UPDATE account SET balance = -100 WHERE account_id = 4;

\echo '--- Test 2: duplicate BVN (UNIQUE)'
INSERT INTO customer (bvn, first_name, last_name, email, phone, date_of_birth)
VALUES ('22100000001','Fake','Person','fake@example.com','+2348039999999','1990-01-01');

\echo '--- Test 3: account for a customer that does not exist (FOREIGN KEY)'
INSERT INTO account (account_number, customer_id, account_type) VALUES ('0999999999', 999, 'WALLET');

\echo '--- Test 4: invalid account type (CHECK ... IN)'
INSERT INTO account (account_number, customer_id, account_type) VALUES ('0888888888', 1, 'CRYPTO');

\echo '--- Test 5: under-18 customer (CHECK on date_of_birth)'
INSERT INTO customer (bvn, first_name, last_name, email, phone, date_of_birth)
VALUES ('22100000099','Young','User','young@example.com','+2348038888888', CURRENT_DATE - INTERVAL '10 years');

\echo '--- Test 6: REVERSAL with no parent transaction (table CHECK)'
INSERT INTO txn (reference, txn_type, amount) VALUES ('KL-BAD-0001','REVERSAL',100);

\echo '--- Test 7: deleting a customer who still has accounts (ON DELETE RESTRICT)'
DELETE FROM customer WHERE customer_id = 1;

\echo '--- Test 8: ledger entry for an account that is not ours (FOREIGN KEY)'
INSERT INTO ledger_entry (txn_id, account_id, direction, amount, balance_after) VALUES (2, 999, 'CREDIT', 100, 100);

\echo '--- Test 9: customer wallet with no owner (gl_has_no_customer)'
INSERT INTO account (account_number, customer_id, account_type) VALUES ('0777777777', NULL, 'WALLET');

\echo '--- Test 10: GL account assigned to a customer (gl_has_no_customer)'
INSERT INTO account (account_number, customer_id, account_type, account_name) VALUES ('9000000009', 1, 'GL', 'Bad GL');
