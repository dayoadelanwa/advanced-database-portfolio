-- =====================================================================
-- MIT 8103 Portfolio 3: concurrency anomalies and how PostgreSQL controls them.
-- You need TWO sessions, i.e. two separate connections:
--   pgAdmin: open the Query Tool TWICE on the same database (two tabs).
--   Name them in your head:  [A] = left tab,  [B] = right tab.
--   Arrange them side by side if you can; your screenshots should show both.
--
-- Run ONE line at a time (highlight it, press F5) in the tab shown in [ ],
-- in the numbered order. Keep Auto commit ON.
-- When a step says "WAITS", that tab shows a spinner: this is the lock working.
-- Leave it and go to the next step in the OTHER tab.
--
-- Uses the two lab wallets created in 01 (Lab A = 0123456790, Lab B = 0123456791),
-- so experiments never disturb real customer balances.
-- Every tab: run this first
SET search_path TO kobo;
-- =====================================================================


-- =====================================================================
-- SCENARIO 1: the LOST UPDATE problem (READ COMMITTED, PostgreSQL's default)
-- An app reads a balance, subtracts in application code, writes it back.
-- An ATM withdrawal (N10,000) and a POS payment (N5,000) hit Lab A at once.
-- Correct final balance: 50,000 - 10,000 - 5,000 = 35,000
-- =====================================================================
/* 1  [A] */ UPDATE account SET balance = 50000 WHERE account_number = '0123456790';   -- reset
/* 2  [A] */ BEGIN;
/* 3  [A] */ SELECT balance FROM account WHERE account_number = '0123456790';          -- 50,000
/* 4  [B] */ BEGIN;
/* 5  [B] */ SELECT balance FROM account WHERE account_number = '0123456790';          -- 50,000
/* 6  [A] */ UPDATE account SET balance = 40000 WHERE account_number = '0123456790';   -- app: 50,000 - 10,000
/* 7  [A] */ COMMIT;
/* 8  [B] */ UPDATE account SET balance = 45000 WHERE account_number = '0123456790';   -- app: 50,000 - 5,000 (stale read!)
/* 9  [B] */ COMMIT;
/* 10 [A] */ SELECT balance FROM account WHERE account_number = '0123456790';
-- 📸 45,000, not 35,000. The ATM withdrawal was LOST: the customer got N10,000 for free.


-- =====================================================================
-- SCENARIO 2: control mechanism 1, PESSIMISTIC LOCKING (SELECT ... FOR UPDATE)
-- "Lock the row before you read it for an update."
-- =====================================================================
/* 1  [A] */ UPDATE account SET balance = 50000 WHERE account_number = '0123456790';   -- reset
/* 2  [A] */ BEGIN;
/* 3  [A] */ SELECT balance FROM account WHERE account_number = '0123456790' FOR UPDATE;   -- 50,000 + row lock
/* 4  [B] */ BEGIN;
/* 5  [B] */ SELECT balance FROM account WHERE account_number = '0123456790' FOR UPDATE;   -- WAITS (spinner)
-- 6 [A] 📸 evidence of the wait, while B is blocked:
/* 6  [A] */ SELECT pid, state, wait_event_type, wait_event, left(query, 60) AS query
             FROM pg_stat_activity
             WHERE datname = current_database() AND pid <> pg_backend_pid() AND state <> 'idle';
             -- B shows wait_event_type = Lock, wait_event = transactionid
/* 7  [A] */ UPDATE account SET balance = 40000 WHERE account_number = '0123456790';
/* 8  [A] */ COMMIT;                                          -- B's spinner stops: B now reads 40,000
/* 9  [B] */ UPDATE account SET balance = 35000 WHERE account_number = '0123456790';   -- app: 40,000 - 5,000
/* 10 [B] */ COMMIT;
/* 11 [A] */ SELECT balance FROM account WHERE account_number = '0123456790';
-- 📸 35,000. Correct. Cost: B had to wait (less concurrency).


-- =====================================================================
-- SCENARIO 3: control mechanism 2, OPTIMISTIC: REPEATABLE READ detects the conflict
-- No waiting on reads; the second writer is rejected and must retry.
-- =====================================================================
/* 1  [A] */ UPDATE account SET balance = 50000 WHERE account_number = '0123456790';   -- reset
/* 2  [A] */ BEGIN ISOLATION LEVEL REPEATABLE READ;
/* 3  [A] */ SELECT balance FROM account WHERE account_number = '0123456790';          -- 50,000
/* 4  [B] */ BEGIN ISOLATION LEVEL REPEATABLE READ;
/* 5  [B] */ SELECT balance FROM account WHERE account_number = '0123456790';          -- 50,000
/* 6  [A] */ UPDATE account SET balance = 40000 WHERE account_number = '0123456790';
/* 7  [A] */ COMMIT;
/* 8  [B] */ UPDATE account SET balance = 45000 WHERE account_number = '0123456790';
-- 📸 ERROR: could not serialize access due to concurrent update
/* 9  [B] */ ROLLBACK;
-- the application RETRIES the whole transaction:
/* 10 [B] */ BEGIN ISOLATION LEVEL REPEATABLE READ;
/* 11 [B] */ SELECT balance FROM account WHERE account_number = '0123456790';          -- 40,000 (fresh)
/* 12 [B] */ UPDATE account SET balance = 35000 WHERE account_number = '0123456790';
/* 13 [B] */ COMMIT;
/* 14 [A] */ SELECT balance FROM account WHERE account_number = '0123456790';
-- 📸 35,000. Correct.
-- (Simplest fix of all: let the database do the arithmetic:
--    UPDATE account SET balance = balance - 5000 ...
--  The UPDATE re-reads the latest committed value, so no update is lost.)


-- =====================================================================
-- SCENARIO 4: ISOLATION LEVELS, dirty read and non-repeatable read
-- =====================================================================
-- 4a. DIRTY READ is impossible in PostgreSQL (even READ UNCOMMITTED behaves as READ COMMITTED)
/* 1  [A] */ UPDATE account SET balance = 50000 WHERE account_number = '0123456790';   -- reset
/* 2  [B] */ BEGIN;
/* 3  [B] */ UPDATE account SET balance = 1 WHERE account_number = '0123456790';       -- not committed
/* 4  [A] */ BEGIN ISOLATION LEVEL READ UNCOMMITTED;
/* 5  [A] */ SELECT balance FROM account WHERE account_number = '0123456790';
-- 📸 50,000. A never sees B's uncommitted value.
/* 6  [B] */ ROLLBACK;
/* 7  [A] */ COMMIT;

-- 4b. NON-REPEATABLE READ under READ COMMITTED
/* 1  [A] */ BEGIN;                                                                     -- READ COMMITTED
/* 2  [A] */ SELECT balance FROM account WHERE account_number = '0123456790';          -- 50,000
/* 3  [B] */ UPDATE account SET balance = 20000 WHERE account_number = '0123456790';   -- auto-committed
/* 4  [A] */ SELECT balance FROM account WHERE account_number = '0123456790';
-- 📸 20,000: same query, same transaction, different answer
/* 5  [A] */ COMMIT;

-- 4c. ...prevented by REPEATABLE READ (snapshot isolation)
/* 1  [A] */ UPDATE account SET balance = 50000 WHERE account_number = '0123456790';   -- reset
/* 2  [A] */ BEGIN ISOLATION LEVEL REPEATABLE READ;
/* 3  [A] */ SELECT balance FROM account WHERE account_number = '0123456790';          -- 50,000
/* 4  [B] */ UPDATE account SET balance = 20000 WHERE account_number = '0123456790';   -- auto-committed
/* 5  [A] */ SELECT balance FROM account WHERE account_number = '0123456790';
-- 📸 still 50,000: A reads from the snapshot taken at its first query
/* 6  [A] */ COMMIT;
/* 7  [A] */ SELECT balance FROM account WHERE account_number = '0123456790';          -- 20,000 now


-- =====================================================================
-- SCENARIO 5: DEADLOCK, and why transfer() can never cause one
-- A sends Lab A -> Lab B while B sends Lab B -> Lab A, each locking
-- "their" sender row first.
-- =====================================================================
/* 1  [A] */ UPDATE account SET balance = 50000 WHERE account_number IN ('0123456790','0123456791');  -- reset
/* 2  [A] */ BEGIN;
/* 3  [A] */ UPDATE account SET balance = balance - 1000 WHERE account_number = '0123456790';  -- locks Lab A
/* 4  [B] */ BEGIN;
/* 5  [B] */ UPDATE account SET balance = balance - 1000 WHERE account_number = '0123456791';  -- locks Lab B
/* 6  [A] */ UPDATE account SET balance = balance + 1000 WHERE account_number = '0123456791';  -- WAITS for B
/* 7  [B] */ UPDATE account SET balance = balance + 1000 WHERE account_number = '0123456790';  -- waits for A: CYCLE
-- 📸 within ~1 second one tab gets: ERROR: deadlock detected ... (the other proceeds)
/* 8  [A] */ COMMIT;     -- run COMMIT in the tab that did NOT get the error
/* 9  [B] */ ROLLBACK;   -- and ROLLBACK in the tab that did
-- transfer() avoids this: it always locks the LOWER account_id first, so two
-- opposite transfers queue on the same row instead of forming a cycle.


-- =====================================================================
-- SCENARIO 6: the real control mechanism: two simultaneous transfer() calls
-- try to spend the same N40,000 twice (a "double spend"). Lab A has N50,000.
-- =====================================================================
/* 1  [A] */ UPDATE account SET balance = 50000 WHERE account_number IN ('0123456790','0123456791');  -- reset
/* 2  [A] */ BEGIN;
/* 3  [A] */ SELECT transfer('0123456790', '0123456791', 40000, 'P3-RACE-' || txid_current(), 'Race A');
/* 4  [B] */ SELECT transfer('0123456790', '0123456791', 40000, 'P3-RACE-' || txid_current(), 'Race B');
             -- WAITS: blocked by A's FOR UPDATE lock inside transfer()
/* 5  [A] */ COMMIT;
-- 📸 [B] immediately fails: ERROR: Insufficient funds in 0123456790: balance 10000.00, requested 40000
/* 6  [A] */ SELECT * FROM v_demo_balances;
-- 📸 Lab A 10,000, Lab B 90,000: spent once, never twice.
