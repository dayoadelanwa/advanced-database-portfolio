# Portfolio 3: Transactions and Concurrency

This tests for how Transaction behaviours. Screenshots are saved in the screenshots directory under portfolio 3: transactions and Concurrency

## 1. Objective

Show how DayoKoboLedger keeps money correct when operations fail half-way or run at the same time: commit, rollback, savepoints, isolation levels, a real concurrency anomaly (lost update), deadlock, and the locking mechanism that prevents double spending.

## 2. Files and how to run them

| File | Sessions | How |
|---|---|---|
| `01_transfer_functions.sql` | 1 | Run once (F5). Creates `transfer()`, `reverse_transfer()`, two lab wallets and a fee GL account |
| `02_commit_rollback.sql` | 1 | **One statement at a time** (highlight, F5), top to bottom |
| `03_concurrency_two_sessions.sql` | 2 | Open the Query Tool **twice** (tabs A and B). Run each numbered line in the tab shown, in order |

Keep **Auto commit ON**. An explicit `BEGIN` keeps a transaction open until `COMMIT` or `ROLLBACK`. *(If pgAdmin ever reports "there is no transaction in progress" on COMMIT, switch Auto commit OFF for that tab and skip the BEGIN lines.)*

## 3. The transfer as one transaction (ACID)

`transfer(from, to, amount, reference)` performs one business operation as a single unit:

1. Lock both account rows with `SELECT … FOR UPDATE`, **always in account_id order**
2. Validate: accounts active, sufficient funds, KYC daily limit (per customer, all accounts)
3. Insert the TXN row, update both balances, insert the DEBIT and CREDIT ledger legs

| Property | How it is achieved | Evidence |
|---|---|---|
| **Atomicity** | All writes are in one transaction; any exception undoes all of them | 02 Steps 2–5 |
| **Consistency** | Business rules in the function plus CHECK/FK constraints; debits = credits | 02 Steps 3, 4, 8 |
| **Isolation** | Row locks (`FOR UPDATE`) and isolation levels | 03 Scenarios 2–4, 6 |
| **Durability** | PostgreSQL write-ahead log (WAL): a COMMIT is flushed to disk before success is reported | 

## 4. Results: single session (`02_commit_rollback.sql`)

| Step | Demonstrates | Result |
|---|---|---|
| 1 | **COMMIT** | Ngozi → Tolu ₦100,000 becomes permanent; one TXN, two balanced ledger legs |
| 2 | **Explicit ROLLBACK** | Balances changed *inside* the transaction, restored after ROLLBACK; the TXN row is gone too |
| 3 | **Automatic rollback (business rule)** | Tolu, tier 1, has the money but ₦60,000 > ₦50,000 KYC limit → exception, nothing written |
| 4 | **Automatic rollback (funds)** | Musa sends ₦100,000 with ₦85,000 → exception, nothing written |
| 5 | **Atomicity after partial failure** | Debit succeeds, the next statement violates a CHECK → transaction *aborted* (every further command refused) → ROLLBACK undoes the debit |
| 6 | **SAVEPOINT** | Transfer kept, ₦50 fee undone with `ROLLBACK TO SAVEPOINT` (fee waiver) |
| 7 | **Compensating transaction** | A committed transfer cannot be rolled back, so `reverse_transfer()` posts a linked REVERSAL; a second reversal is refused |
| 8 | **Consistency check** | Every transaction still balances (0 rows) |

## 5. Results: two sessions (`03_concurrency_two_sessions.sql`)

| Scenario | Isolation / mechanism | Expected | Observed | Explanation |
|---|---|---|---|---|
| 1 Lost update | READ COMMITTED, read-then-write in app code | 35,000 | **45,000** ❌ | B wrote a value computed from a stale read; A's ₦10,000 withdrawal vanished |
| 2 Pessimistic lock | `SELECT … FOR UPDATE` | 35,000 | 35,000 ✔ | B **waited** (`wait_event_type = Lock`) until A committed, then read 40,000 |
| 3 Optimistic | REPEATABLE READ | 35,000 | 35,000 ✔ | B's update rejected: *could not serialize access due to concurrent update*; retry succeeded |
| 4a Dirty read | READ UNCOMMITTED | 50,000 | 50,000 ✔ | PostgreSQL never shows uncommitted data |
| 4b Non-repeatable read | READ COMMITTED | — | 50,000 then **20,000** | Each statement sees the latest committed data |
| 4c Prevented | REPEATABLE READ | — | 50,000 then **50,000** | The whole transaction reads one snapshot (MVCC) |
| 5 Deadlock | Opposite lock order | — | *deadlock detected* | PostgreSQL detects the cycle (after `deadlock_timeout`, 1 s) and aborts one transaction |
| 6 Double spend | `transfer()` row locks | spent once | Lab A 10,000 / Lab B 90,000 ✔ | B blocked, then saw the new balance and failed *Insufficient funds* |

## 6. Isolation levels in PostgreSQL

| Level | Dirty read | Non-repeatable read | Phantom read | Serialization anomaly |
|---|---|---|---|---|
| Read Uncommitted\* | not possible | possible | possible | possible |
| **Read Committed** (default) | not possible | possible | possible | possible |
| Repeatable Read | not possible | not possible | not possible\*\* | possible |
| Serializable | not possible | not possible | not possible | not possible |

\* PostgreSQL treats Read Uncommitted as Read Committed.
\*\* Stricter than the SQL standard requires, because PostgreSQL's Repeatable Read uses snapshot isolation.

PostgreSQL implements isolation with **MVCC (Multi-Version Concurrency Control)**: an UPDATE writes a *new row version* instead of overwriting, so readers never block writers and writers never block readers. Only two writers to the same row wait for each other.

## 7. Design decisions

- **Why pessimistic locking inside `transfer()`?** Contention on one account is rare but a lost update costs real money, so a short row lock is cheaper than retry logic. Locks are held for milliseconds, only on the two rows involved.
- **Why lock in account_id order?** Two transfers in opposite directions (A→B and B→A) would otherwise lock in opposite orders and deadlock (Scenario 5). A global lock order makes that cycle impossible.
- **Why not SERIALIZABLE everywhere?** It is the safest level, but every conflict becomes an error the application must retry, which reduces throughput under load. Row locks give the same safety for this workload at lower cost.
- **Sequences are not transactional.** The rolled-back transfer in Step 2 still used up a `txn_id`, so IDs have gaps. That is why transaction *references*, not IDs, are the business identifier.

## 8. Reflection
It was a bit surprising that the lost update needed no error to happen; Step 5's "transaction is aborted" instead.