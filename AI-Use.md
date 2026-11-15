**Claude** (Anthropic), used as a tutor and coding assistant through the Claude app.

## What it was used for

| Portfolio | Use |
|---|---|
| All | Explaining concepts (normalisation, execution plans, MVCC, isolation levels, CAP, NoSQL modelling); suggesting the KoboLedger case study |
| 1 | Design guidance, starter DDL, seed data and constraint-test scripts, README template |
| 2 | Data generator, query and index scripts, guidance on reading `EXPLAIN ANALYZE` |
| 3 | `transfer()` / `reverse_transfer()` functions and the step-by-step two-session scripts |
| 4 | Starter MongoDB, Redis and Cypher scripts and the suitability analysis structure |
| 5 | Structure of the distributed-design discussion; pointers to the CBN FAQ and NDPA provisions |
| Documentation | Structuring the LMS summary and the READMEs |
| Debugging | Diagnosing errors in my environment (see section 3) |

## How I reviewed, corrected, tested and verified the output
- **Ran every script myself** on my own PostgreSQL (pgAdmin), MongoDB, Redis and Neo4j instances. The outputs and timings in `results/` and `screenshots/` come from my runs. ✏️
- **Problems I hit and fixed** (each committed separately):
  - Inward transfers to a GL account were rejected by a `balance_after >= 0` CHECK; the rule was moved to the account level.
  - `relation "dep" does not exist`: temporary tables are scoped to the session, and the GUI client ran statements on different connections.
  - `VACUUM cannot run inside a transaction block`: pgAdmin runs a script as one transaction, so VACUUM became a separate step.
  - A rolled-back run left gaps in the identity sequences (sequences are not transactional), so the database was rebuilt from the schema.
  - psql meta-commands (`\echo`) are not SQL, and the PSQL Tool needed a local psql binary, so the plan capture was moved into a function.
  - `current transaction is aborted`: `search_path` had not been set in the second session.
  - `SET TRANSACTION ISOLATION LEVEL must be called before any query`: two statements had run as one batch.
- **Rewrote all explanations** (✏️ sections of each README, and the reflection) in my own words.
- **Checked facts against sources:** PostgreSQL and MongoDB documentation, the NDPA 2023, and the CBN data localisation FAQ.
- I can explain every design decision and result in this repository.


- Claude was used for design guidance and starter scripts.
- I personally ran scripts, tests myself, made modificationst to documentation and other changes.
- https://aiven.io was used for the postgresql simulation for number 1
- when it came to query optmization, I had to switch to posgres on docker with my local machine and subsequent scripts were run from there
- Claude was used for commit/rollback and concurrency(for 2 sessions) test scripts
- docker was used for mongo db container. Time constraints could not allow for redis and neo4j
