-- =====================================================================
-- MIT 8103 Portfolio 2: Q6 is an analytical (OLAP) query on an OLTP schema.
-- It must read most of the ledger, so no index makes it fast: a sequential
-- scan IS the optimal plan. The fix is architectural: pre-aggregate it.
--
-- Works in pgAdmin's Query Tool (F5) and in psql.
-- After this, re-run 02_explain_queries.sql: it adds the view's plan (Q6 again).
-- =====================================================================
SET search_path TO kobo;

DROP MATERIALIZED VIEW IF EXISTS mv_monthly_volume_by_tier;
CREATE MATERIALIZED VIEW mv_monthly_volume_by_tier AS
SELECT date_trunc('month', l.created_at) AS month, c.kyc_tier,
       count(*) AS transfers, sum(l.amount) AS value_ngn
FROM ledger_entry l
JOIN txn      t ON t.txn_id      = l.txn_id
JOIN account  a ON a.account_id  = l.account_id
JOIN customer c ON c.customer_id = a.customer_id
WHERE l.direction = 'DEBIT' AND t.txn_type = 'TRANSFER'
GROUP BY 1, 2;

CREATE UNIQUE INDEX ON mv_monthly_volume_by_tier (month, kyc_tier);  -- allows CONCURRENTLY refresh

-- Measure the nightly refresh cost. CONCURRENTLY lets reports keep reading
-- the old data while the refresh runs. The time appears as a NOTICE
-- (pgAdmin: "Messages" tab).
DO $$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY kobo.mv_monthly_volume_by_tier;
    RAISE NOTICE 'Nightly refresh took % ms',
        round(extract(epoch FROM clock_timestamp() - t0) * 1000, 1);
END $$;

-- The report itself: 39 rows instead of scanning 1.1 million
SELECT * FROM mv_monthly_volume_by_tier ORDER BY month, kyc_tier;
