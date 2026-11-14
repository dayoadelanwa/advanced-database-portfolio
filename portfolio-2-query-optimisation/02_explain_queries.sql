-- =====================================================================
-- MIT 8103 Portfolio 2: capture the execution plans of the six business
-- queries (plus the materialized view, once 04_reporting_mv.sql has run).
--
-- Works in pgAdmin's Query Tool (run the whole file with F5) AND in psql.
-- Why a function? A GUI shows only the LAST result of a script, so six
-- separate EXPLAINs would show only Q6. This function runs every EXPLAIN
-- and returns all plans as ONE result set.
--
-- Save the output as evidence:
--   before indexing -> results/before.txt
--   after indexing  -> results/after.txt
-- pgAdmin: click the "Save results to file" (download) button above the Data Output grid,
--          or click a cell, Ctrl+A, Ctrl+C, and paste into the .txt file.
-- psql:    psql -d koboledger -f 02_explain_queries.sql > results/before.txt
--
-- EXPLAIN (ANALYZE, BUFFERS) really executes each query and reports actual
-- time, rows, and pages read (shared hit = from RAM, read = from disk).
-- =====================================================================

CREATE OR REPLACE FUNCTION kobo.capture_plans()
RETURNS TABLE (line_no int, plan_line text)
LANGUAGE plpgsql
SET search_path = kobo
SET max_parallel_workers_per_gather = 0      -- single-process plans: easier to read and compare
AS $fn$
DECLARE
    q    record;
    line text;
BEGIN
    line_no := 0;
    FOR q IN
        SELECT * FROM (VALUES
        (1, 'Q1 Customer statement: last 90 days, newest 50', $q$
            SELECT l.created_at, t.reference, t.narration, l.direction, l.amount, l.balance_after
            FROM ledger_entry l
            JOIN txn t ON t.txn_id = l.txn_id
            WHERE l.account_id = (SELECT account_id FROM account WHERE account_number = '1000028657')
              AND l.created_at >= now() - interval '90 days'
            ORDER BY l.created_at DESC
            LIMIT 50 $q$),

        (2, 'Q2 KYC daily-limit check: total debits today', $q$
            SELECT COALESCE(SUM(amount), 0) AS debited_today
            FROM ledger_entry
            WHERE account_id = (SELECT account_id FROM account WHERE account_number = '1000028657')
              AND direction  = 'DEBIT'
              AND created_at >= date_trunc('day', now()) $q$),

        (3, 'Q3 Dispute desk: find a transfer and its ledger legs', $q$
            SELECT t.reference, t.status, l.account_id, l.direction, l.amount
            FROM txn t
            JOIN ledger_entry l ON l.txn_id = t.txn_id
            WHERE t.reference = 'KL-TR-250000' $q$),

        (4, 'Q4 Support desk: case-insensitive email lookup', $q$
            SELECT customer_id, first_name, last_name, phone, kyc_tier
            FROM customer
            WHERE lower(email) = lower('User4242@Example.com') $q$),

        (5, 'Q5 Operations: failed transfers in the last 7 days', $q$
            SELECT reference, amount, initiated_at
            FROM txn
            WHERE status = 'FAILED'
              AND initiated_at >= now() - interval '7 days'
            ORDER BY initiated_at DESC $q$),

        (6, 'Q6 Management report: monthly transfer volume by KYC tier', $q$
            SELECT date_trunc('month', l.created_at) AS month, c.kyc_tier,
                   count(*) AS transfers, sum(l.amount) AS value_ngn
            FROM ledger_entry l
            JOIN txn      t ON t.txn_id      = l.txn_id
            JOIN account  a ON a.account_id  = l.account_id
            JOIN customer c ON c.customer_id = a.customer_id
            WHERE l.direction = 'DEBIT'
              AND t.txn_type  = 'TRANSFER'
            GROUP BY 1, 2
            ORDER BY 1, 2 $q$),

        (7, 'Q6 again, served from the materialized view (only after 04_reporting_mv.sql)', $q$
            SELECT * FROM mv_monthly_volume_by_tier ORDER BY month, kyc_tier $q$)
        ) AS v(n, title, sql)
        ORDER BY n
    LOOP
        -- skip the materialized-view query until the view exists
        CONTINUE WHEN q.n = 7 AND to_regclass('kobo.mv_monthly_volume_by_tier') IS NULL;

        line_no := line_no + 1;
        plan_line := '================ ' || q.title;
        RETURN NEXT;

        FOR line IN EXECUTE 'EXPLAIN (ANALYZE, BUFFERS) ' || q.sql LOOP
            line_no := line_no + 1;
            plan_line := line;
            RETURN NEXT;
        END LOOP;
    END LOOP;
END
$fn$;

SELECT plan_line FROM kobo.capture_plans() ORDER BY line_no;
