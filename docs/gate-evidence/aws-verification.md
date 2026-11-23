# AWS gate verification (SB-E00-002 / #21)

Run date: 2026-11-23. Region ap-southeast-2 (Sydney), working region for the gate only, not a pilot decision.
Server: EC2 t3.small (2 vCPU, x86_64), Ubuntu 26.04.1 LTS. Launched 16:38:33Z, torn down about 19:52Z (about 3 h 14 min).
Teardown output: `verify: instances=0 volumes=0 elastic_ips=0 sg=0 key=0`, `teardown verified: clean`.

## D1. Packages (GO)

- PostgreSQL 18.6 (Ubuntu 18.6-0ubuntu0.26.04.1) and PostGIS 3.6.2 (GEOS 3.14.1, PROJ 9.7.1) came from Ubuntu's own repository. No outside repository was added.
- Full text: `server-facts.txt`.
- PostgreSQL listened on 127.0.0.1 only. The security group allowed SSH (22) from one /32 address only. Port 5432 was never opened.

## D2. WAL archiving (PASS)

- archive_mode=on, archive_timeout=60s (test value, not a pilot decision), archive_command copies to a folder on the same server.
- archive_timeout proven on a quiet database: archived_count rose 11 -> 13 with no load and no manual switch. failed_count stayed 0 (final row 21 | 0).

## D3. Benchmark (FAIL at the backlog target)

Target: p95 <= 500 ms at every radius, zero errors, 100 clients. Runs were on the server itself (load generator and PostgreSQL share 2 CPUs), direct connection, 50,000 synthetic providers.

| Run | Clients connected | p95 2 km | p95 5 km | p95 10 km | Verdict |
|---|---|---|---|---|---|
| aws-ec2-onserver (100 clients) | 96/100 | 293.9 | 302.3 | 529.2 | FAIL |
| aws-ec2-onserver-c96 (diagnostic) | 96/96 | 240.5 | 308.7 | 528.1 | FAIL |

- Causes of the first failure: (1) 4 connections refused, error text "remaining connection slots are reserved for roles with the SUPERUSER attribute" (max_connections 100, 3 reserved): proven. (2) 10 km p95 above 500 ms: repeated in both runs.
- During the c96 run `vmstat` showed about 96 tasks waiting for 2 CPUs and 0% idle, steal 0 (`vmstat-c96.txt`). The CPUs were saturated. How much was PostgreSQL and how much the Python load generator is NOT measured.
- One unloaded query took 0.7 to 11.4 ms (explain column), so the index works.
- The 96-client run is a labelled diagnostic, not a replacement verdict.
- The benchmark has no pause between requests, so it is harsher than real users. "100 concurrent" is not defined in the backlog: PO to define.
- Note: the hard-coded "Local runs validate the script only" text inside the JSON files is wrong for these cloud runs (known benchmark.py follow-up).

## D4. PITR drill (PASS, with limits)

- Base backup, 5 rows before target time T, 3 rows after, restore on a second instance to T.
- Restored copy: quiet-1, before-T-1..5 and no after-T rows. Live control: all 9 rows. Log: "recovery stopping before commit of transaction 785".
- Elapsed about 32 s, including manual typing, on a tiny database.
- Limits: (1) backup and archive were on the same server, so they do not survive losing the server or account; (2) restore time at pilot data size (REL-05 RTO <= 4 h) is untested; (3) restoring onto a NEW server is untested.

## Network sample (T3, partial)

- 30 x `SELECT 1` from my PC through an SSH tunnel to Sydney: min 424.7, median 426.1, max 854.2 ms.
- One connection, one hour, cannot split home line vs route. Mumbai not measured.

## Not done / unknown

- Pooled (pgbouncer) run not done. Full benchmark from my PC not done (slow home line).
- Real cost: check Billing. Public IPv4 cost and plan-end behaviour: unverified.
- Default 8 GiB root disk was unencrypted (SEC-DATA-01 gap for the pilot).