-- =====================================================================
-- MIT 8103 Portfolio 2: indexes. Each one is justified by a query.
-- Rule of thumb: index what you FILTER, JOIN and SORT on, in that order,
-- and only when the condition is SELECTIVE (returns a small fraction of rows).
-- =====================================================================
SET search_path TO kobo;

-- Q1 + Q2: composite B-tree. Column order matters:
--   equality column first (account_id), range/sort column second (created_at).
--   INCLUDE adds direction+amount to the leaf pages, so Q2 can be answered
--   from the index alone (an index-only scan, never touching the table).
CREATE INDEX ix_ledger_account_time
    ON ledger_entry (account_id, created_at) INCLUDE (direction, amount);

-- Q3: NO new index needed, and that is a finding, not an omission.
-- PostgreSQL does not index foreign keys automatically, BUT the
-- UNIQUE (txn_id, account_id, direction) constraint from Portfolio 1 already
-- created a B-tree whose LEADING column is txn_id. A composite index can serve
-- any query on its leftmost column(s), so Q3 was fast before indexing.
-- Adding ix_ledger_txn (txn_id) was tested: same plan, same speed, +21 MB,
-- and slower inserts. It is redundant, so it is not created:
-- CREATE INDEX ix_ledger_txn ON ledger_entry (txn_id);

-- Q4: expression index. The UNIQUE index on email cannot serve
-- WHERE lower(email) = ... because the indexed values are not lower-cased.
-- (Wrapping a column in a function makes the predicate "non-sargable".)
CREATE INDEX ix_customer_email_lower ON customer (lower(email));

-- Q5: partial index. Only ~3% of transactions are FAILED; indexing only
-- those rows gives a tiny index that is cheap to maintain on every insert.
CREATE INDEX ix_txn_failed_recent ON txn (initiated_at) WHERE status = 'FAILED';

-- Other foreign keys (account.customer_id) for completeness
CREATE INDEX ix_account_customer ON account (customer_id);

-- New indexes need fresh statistics (ANALYZE is allowed inside a transaction).
ANALYZE;
-- ** AFTER this script, run  VACUUM ANALYZE;  ON ITS OWN before 02_explain_queries.sql **
-- (VACUUM cannot run inside a transaction block.)

-- Evidence: index sizes vs table sizes (indexes cost disk and write speed)
SELECT relname AS object, pg_size_pretty(pg_relation_size(oid)) AS size
FROM pg_class
WHERE relnamespace = 'kobo'::regnamespace
  AND relname IN ('ledger_entry','txn','customer','ix_ledger_account_time','ledger_entry_txn_id_account_id_direction_key',
                  'ix_customer_email_lower','ix_txn_failed_recent','ix_account_customer')
ORDER BY pg_relation_size(oid) DESC;
