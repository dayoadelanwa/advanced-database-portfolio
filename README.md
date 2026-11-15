# mit8103
2026/2027 Academic Session First Semester Continuous Assessment

# MIT 8103 Advanced Database Systems: Practical Database Portfolio

**Student:** Adedayo Adelanwa · Student ID - 301925126
**Case study:** **DayoKoboLedger**, a *simulated* Nigerian digital-wallet fintech (Bank/Fintech category). All data is synthetic, and no real organisation's data is used.

KoboLedger lets customers hold Naira in a mobile wallet, receive deposits, and send instant transfers to other wallets and other banks. The same case study is used in all five portfolios.

## Repository structure

| Folder | Portfolio | Highlights |
|---|---|---|
| [`portfolio-1-database-design/`](portfolio-1-database-design/) | Database Design and Modelling | ER diagram (Mermaid), BCNF schema, double-entry ledger, 10 constraint tests |
| [`portfolio-2-query-optimisation/`](portfolio-2-query-optimisation/) | Query Processing and Optimisation | 1.1 M-row dataset, 6 queries with before/after `EXPLAIN ANALYZE`, materialized view |
| [`portfolio-3-transactions-concurrency/`](portfolio-3-transactions-concurrency/) | Transactions and Concurrency | `transfer()` with row locking, commit/rollback/savepoint, 6 two-session concurrency scenarios |
| [`portfolio-4-nosql/`](portfolio-4-nosql/) | NoSQL and Advanced Data Models | MongoDB (document), Redis (key-value), Neo4j (graph), Cassandra design |
| [`portfolio-5-distributed-cloud/`](portfolio-5-distributed-cloud/) | Distributed and Cloud Database | Replication, failover, sharding, CAP, CBN data localisation (design discussion) |
| [`AI-USE.md`](AI-USE.md) | AI Use Declaration | Tool, purpose, and how outputs were verified |

Each folder has its own README explaining what was built, how to run it, the results, and a reflection.

## Environment

| Component | Version |
|---|---|
| PostgreSQL | 16 (pgAdmin 4 Query Tool) |
| MongoDB | 8.0 with mongosh |
| Redis | 7 |
| Neo4j | Aura Free |
| Containers | Docker for over 90% of posgres DB used |

## Quick start

1. **PostgreSQL:** create a database, then run Portfolio 1 `01_schema.sql` and `02_seed.sql`, followed by Portfolios 2 and 3 in their numbered order (see each README).
2. **MongoDB / Redis / Neo4j:** see `portfolio-4-nosql/README.md`.

## Key results at a glance

| Area | Result |
|---|---|
| Customer statement query (Q1) | 103.6 ms → 0.24 ms with a composite index |
| Daily KYC limit check (Q2) | 99.2 ms → 0.036 ms, index-only scan |
| Monthly report (Q6) | 1,321 ms → 0.039 ms via materialized view |
| Lost update | Reproduced (₦10,000 lost, no error), then prevented with `FOR UPDATE` and REPEATABLE READ |
| Double spend | Blocked by `transfer()` row locks |
| MongoDB statement query | COLLSCAN of 60,000 docs → IXSCAN of 20 |

## Academic integrity
Individual work. AI assistance is declared in [`AI-USE.md`](AI-USE.md); all scripts were run, tested and verified by the student.
