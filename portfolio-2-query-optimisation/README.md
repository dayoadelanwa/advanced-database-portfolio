# Portfolio 2: Query Processing and Optimisation

Effectiveness and efficiency of queries was measured and optimised to give faster results for when the database grows. Anonymised records of over 1 million ledger entries were added for the stress tests.

Scripts were run locally for this session, on local machine. 

Results are stored in results directory in repo. 

## 1. Objective

Identify the queries DayoKoboLedger runs most often, measure how PostgreSQL executes them on a realistic data volume, apply targeted optimisations, and prove each improvement with before/after execution plans.

## 2. Test environment and data volume

| Item | Value |
|---|---|
| DBMS | PostgreSQL 16, single node, `max_parallel_workers_per_gather = 0` (serial plans, easier to compare) |
| Machine | Local laptop: CPU - 1.7ghz, RAM - 16gb, OS - Windows 11 |
| Data | 50,004 customers · 69,943 accounts · 569,928 transactions · **1,109,958 ledger entries** |
| Generator | `01_generate_data.sql` (set-based `generate_series` + window function for running balances; ~55 s) |
| Integrity | after generation, every transaction balances (debits = credits): 0 violating rows |

## 3. How to reproduce

```bash
# Portfolio 1 schema + seed first, then:
psql -d koboledger -f 01_generate_data.sql      > results/generate.txt
psql -d koboledger -c "VACUUM ANALYZE;"         # on its own: VACUUM cannot run inside a transaction
psql -d koboledger -f 02_explain_queries.sql    > results/before.txt
psql -d koboledger -f 03_indexes.sql            > results/indexes.txt
psql -d koboledger -c "VACUUM ANALYZE;"         # sets the visibility map for index-only scans
psql -d koboledger -f 02_explain_queries.sql    > results/after.txt
psql -d koboledger -f 04_reporting_mv.sql       > results/materialized_view.txt
```

## 4. The workload: six business queries

| # | Business need | Who runs it | Frequency |
|---|---|---|---|
| Q1 | Customer statement: last 90 days, newest 50 | Mobile app | Very high |
| Q2 | KYC daily-limit check: debits so far today | Every transfer, before posting | Very high |
| Q3 | Find a transfer by reference and show its ledger legs | Dispute/support desk | Medium |
| Q4 | Find a customer by email (case-insensitive) | Support desk | Medium |
| Q5 | Failed transfers in the last 7 days | Operations/reconciliation | Daily |
| Q6 | Monthly transfer volume by KYC tier | Management/regulatory report | Monthly |

## 5. Results

| Query | Plan BEFORE | Time before | Optimisation | Plan AFTER | Time after | Speed-up |
|---|---|---|---|---|---|---|
| Q1 Statement | Seq Scan on ledger_entry (1.1 M rows) | 103.6 ms | Composite index `(account_id, created_at)` | Index Scan **Backward** | 0.24 ms | ~430× |
| Q2 Daily limit | Seq Scan on ledger_entry | 99.2 ms | Same index + `INCLUDE (direction, amount)` | **Index Only Scan** | 0.036 ms | ~2,700× |
| Q3 Dispute lookup | Index Scan on `txn_reference_key` + existing UNIQUE index | 0.069 ms | **None needed** (see 6.3) | unchanged | 0.037 ms | already optimal |
| Q4 Email lookup | Seq Scan on customer (UNIQUE index ignored) | 15.9 ms | Expression index on `lower(email)` | Index Scan | 0.030 ms | ~530× |
| Q5 Failed transfers | Seq Scan on txn (570 K rows) | 57.3 ms | Partial index `WHERE status = 'FAILED'` | Bitmap Index Scan | 1.7 ms | ~34× |
| Q6 Monthly report | 4 Seq Scans + 3 Hash Joins + Sort | 1,321 ms | Index: **no effect** (1,337 ms) → materialized view | Seq Scan on 39-row view | 0.039 ms | ~34,000× (refresh 0.86 s nightly) |

Full plans: In github repo - (results/before.txt), (results/after.txt), (results/materialized_view.txt). 

## 6. Analysis

### 6.1 Q1: why a composite index, and why this column order
Before indexing, the optimiser had no way to find one account's rows, so it read all 1.1 million ledger rows (about 23,000 pages) to return 14. The index `(account_id, created_at)` puts **the equality column first and the range/sort column second**. Within one `account_id`, entries are already sorted by time, so PostgreSQL walks the index *backwards* (newest first) and stops after `LIMIT 50`. There is **no Sort node** in the new plan. The reverse order `(created_at, account_id)` would be much worse: the range on `created_at` would cover 90 days of *every* customer.

**Heuristic optimisation (relational algebra).** The SQL is equivalent to

  π<sub>created_at, reference, …</sub> ( σ<sub>account_id = X ∧ created_at ≥ t</sub> ( LEDGER_ENTRY ⋈<sub>txn_id</sub> TXN ) )

The optimiser **pushes the selection down** below the join, so it filters the ledger to 14 rows first and then joins only those to TXN (a Nested Loop with 14 index lookups):

  π ( σ<sub>account_id = X ∧ created_at ≥ t</sub>(LEDGER_ENTRY) ⋈ TXN )

```
 Unoptimised tree               Optimised tree
      π                              π
      |                              |
      σ  account_id = X              ⋈  txn_id   (Nested Loop)
      |                            /    \
      ⋈  txn_id                   σ      TXN  (Index Scan txn_pkey)
    /    \                        |
 LEDGER   TXN                 LEDGER  (Index Scan ix_ledger_account_time)
```

### 6.2 Q2: covering index → index-only scan
Q2 needs only `account_id`, `created_at`, `direction`, `amount`. Adding `INCLUDE (direction, amount)` stores those in the index leaf pages, so the table is never touched (`Index Only Scan`, 7 buffers). This query runs on **every** transfer, so the gain applies to the busiest code path. Index-only scans depend on the visibility map, which is why the scripts run `VACUUM ANALYZE`.

### 6.3 Q3: the index I did *not* create
PostgreSQL does not index foreign keys automatically, so I expected `ledger_entry.txn_id` to need an index. The *before* plan proved otherwise. The Portfolio 1 constraint `UNIQUE (txn_id, account_id, direction)` already created a B-tree **whose leading column is `txn_id`**, and a composite index can serve any search on its leftmost column. I tested a separate `(txn_id)` index: same plan, same speed, 21 MB extra, and slower inserts. It was redundant and has been removed. **Lesson: measure before indexing; every index costs write speed and storage.**

### 6.4 Q4: non-sargable predicates
`email` already had a UNIQUE index, yet the plan was a Seq Scan. `lower(email)` produces a value that is not stored in that index, so the predicate is not *sargable* (search-argument-able). An expression index on `lower(email)` fixes it. An alternative would be storing emails lower-cased at insert time (a CHECK or trigger).

### 6.5 Q5: partial index
Only about 3% of transactions are `FAILED`. A partial index on just those rows is **344 kB, versus 53 MB** for the main ledger index. It is cheap to maintain because 97% of inserts never touch it. Selectivity is what makes it worthwhile.

### 6.6 Q6: when a sequential scan *is* the best plan
Q6 must aggregate about 485,000 rows, roughly half the ledger. At that low selectivity, random index lookups would cost more than reading the table sequentially, so the cost-based optimiser **correctly ignored the new indexes** (1,321 ms → 1,337 ms, no change). It chose hash joins, building in-memory hash tables on the smaller inputs. I also tested `work_mem = 64MB`: the sort moved from disk (12.8 MB external merge) into memory, but total time did not improve. The bottleneck is the volume of rows, not memory.

The real issue is that this is an **OLAP query running on an OLTP schema**. The fix is architectural: a **materialized view** pre-computes the 39-row result (0.039 ms to read) and is refreshed nightly (0.86 s, `CONCURRENTLY`, so readers are not blocked). The trade-off is freshness: the report is up to one day stale, which is acceptable for a monthly management report. At larger scale, this workload belongs in a data warehouse (see Portfolio 5).

### 6.7 Costs of indexing (trade-offs)

| Object | Size |
|---|---|
| ledger_entry (table) | 180 MB |
| ix_ledger_account_time | 53 MB |
| ix_customer_email_lower | 2 MB |
| ix_account_customer | 1.5 MB |
| ix_txn_failed_recent | 0.3 MB |

Every index must be updated on each INSERT/UPDATE, so on a write-heavy ledger, indexes slow down transfers. That is why each index here is justified by a specific high-frequency query, and the redundant one (6.3) was not kept. 

## 7. Limitations of this test
- Single machine with warm cache: production timings would include disk and network latency and concurrent load.
- Synthetic, uniformly random data: real customers are skewed (a few very active accounts), which can change plans.
- `EXPLAIN ANALYZE` executes the query, so repeated runs benefit from caching.

