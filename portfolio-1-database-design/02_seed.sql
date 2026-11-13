-- =====================================================================
-- Portfolio 1: sample data (small and readable). Portfolio 2 will add
-- 100,000+ rows with generate_series so indexes actually matter.
-- Run after 01_schema.sql
-- =====================================================================
SET search_path TO kobo;

INSERT INTO kyc_tier (tier, description, daily_limit, max_balance) VALUES
 (1, 'Phone number + BVN only',            50000.00,   300000.00),
 (2, 'Tier 1 + valid government ID',      200000.00,   500000.00),
 (3, 'Full KYC incl. address verification',5000000.00, NULL);

INSERT INTO customer (bvn, first_name, last_name, email, phone, date_of_birth, kyc_tier) VALUES
 ('22100000001','Ada',    'Okafor',  'ada.okafor@example.com',   '+2348030000001','1990-04-12',3),
 ('22100000002','Musa',   'Bello',   'musa.bello@example.com',   '+2348030000002','1985-09-30',2),
 ('22100000003','Tolu',   'Adeyemi', 'tolu.adeyemi@example.com', '+2348030000003','1998-01-05',1),
 ('22100000004','Ngozi',  'Eze',     'ngozi.eze@example.com',    '+2348030000004','1979-11-21',3);

INSERT INTO account (account_number, customer_id, account_type, balance) VALUES
 ('0123456781', 1, 'WALLET',  250000.00),
 ('0123456782', 1, 'SAVINGS', 1200000.00),
 ('0123456783', 2, 'WALLET',  80000.00),
 ('0123456784', 3, 'WALLET',  15000.00),
 ('0123456785', 4, 'CURRENT', 3400000.00);

-- One successful transfer: Ada (wallet) -> Musa, N5,000
INSERT INTO txn (reference, txn_type, amount, status, narration)
VALUES ('KL-20261112-0001','TRANSFER',5000.00,'SUCCESSFUL','Lunch refund');

INSERT INTO ledger_entry (txn_id, account_id, direction, amount, balance_after) VALUES
 (1, 1, 'DEBIT',  5000.00, 245000.00),
 (1, 3, 'CREDIT', 5000.00,  85000.00);

UPDATE account SET balance = 245000.00 WHERE account_id = 1;
UPDATE account SET balance =  85000.00 WHERE account_id = 3;

-- Internal GL (settlement) accounts owned by KoboLedger itself -> ids 6, 7
INSERT INTO account (account_number, customer_id, account_type, account_name) VALUES
 ('9000000001', NULL, 'GL', 'NIP Outward Settlement'),
 ('9000000002', NULL, 'GL', 'NIP Inward Settlement');

-- A beneficiary at another bank (fictional bank)
INSERT INTO external_counterparty (bank_code, bank_name, account_number, account_name)
VALUES ('999001', 'Example Bank Plc', '3012345678', 'CHIDI NWOSU');

-- Outward inter-bank transfer: Ada -> Chidi at Example Bank, N20,000
-- Ledger: DEBIT Ada's wallet, CREDIT our NIP Outward Settlement GL.
INSERT INTO txn (reference, txn_type, amount, status, narration, counterparty_id, external_session_id)
VALUES ('KL-20261113-0002','TRANSFER',20000.00,'SUCCESSFUL','Rent contribution', 1,
        '999001261113164000000000000001');

INSERT INTO ledger_entry (txn_id, account_id, direction, amount, balance_after) VALUES
 (2, 1, 'DEBIT',  20000.00, 225000.00),
 (2, 6, 'CREDIT', 20000.00,  20000.00);

UPDATE account SET balance = 225000.00 WHERE account_id = 1;
UPDATE account SET balance =  20000.00 WHERE account_id = 6;
