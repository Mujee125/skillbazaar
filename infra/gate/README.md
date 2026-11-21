# Gate-in-a-box (SB-E00-013)

Scripts for the Sprint 0 gate: 50,000 provider locations in PostgreSQL/PostGIS,
a nearby-search benchmark, a recovery drill, and create/teardown scripts for a
Cloud SQL instance.

**Verdict rule (our backlog target):** p95 <= 500 ms at every radius (2, 5, 10 km)
with zero errors. The SRS PERF-03 figure (2 s) is printed for reference only.
**Local numbers validate the scripts only.** The gate verdict comes from the
cloud run (week 2, 23-27 Nov).

## Files

| File | Purpose |
|---|---|
| `01_schema.sql` | Drops and recreates `gate_provider_locations` (GEOGRAPHY Point 4326) |
| `02_seed.sql` | 50,000 rows around Karachi, Lahore, Islamabad (fixed seed) |
| `03_index.sql` | GiST index on `location` |
| `benchmark.py` | 100 clients, ST_DWithin at 2/5/10 km, p50/p95/p99, JSON evidence |
| `run_local.sh` | One command: db up, schema + seed + index, checks, benchmark |
| `pitr_drill.sh` | Local point-in-time-recovery drill on throwaway containers |
| `gcp_create.sh` | Creates the Cloud SQL gate instance (`DRY_RUN=1` supported) |
| `gcp_teardown.sh` | Deletes `sb-gate-` instances, then lists what remains |

## 1. Local run (one command)

Needs Docker. From the repo root:

    bash infra/gate/run_local.sh

It starts the db, loads the table, checks 50,000 rows and the GiST index, then
runs the benchmark. Exit code: 0 PASS, 1 FAIL, 2 benchmark could not start,
3 setup or check failed. Optional: `LABEL=...` (letters, digits, `-`).

It only drops and recreates `gate_provider_locations`. Django tables are not touched.

Clean-volume run (separate stack, your normal data is not touched):

    docker compose stop
    COMPOSE_PROJECT_NAME=sbclean bash infra/gate/run_local.sh
    docker compose -p sbclean down -v
    docker compose up -d --wait

Result files go to `docs/gate-evidence/`. Files whose name contains `-local-`
are ignored by git. Use a label such as `gcp-asia-south1` for cloud runs so
the evidence is committed.

## 2. Benchmark against any database

The script takes a connection string (`--dsn`, or the env var `GATE_DSN`), so it
runs the same way locally, on Cloud SQL and on DigitalOcean. Local example
(this is the command `run_local.sh` uses):

    MSYS_NO_PATHCONV=1 docker compose run --rm -T -v "$(pwd -W)/infra/gate:/gate:ro" -v "$(pwd -W)/docs/gate-evidence:/out" backend python /gate/benchmark.py --dsn "postgresql://sb:sb_dev_only@db:5432/skillbazaar" --label pg18-local --out-dir /out

Never commit a real password. The JSON output does not contain it.
Options: `--provider`, `--region`, `--endpoint-type`, `--clients`, `--queries-per-client`, `--radii-km`, `--limit`, `--seed`, `--no-warmup`.
Small runs are noisy. Do not read a verdict from them.

## 3. Local recovery drill

    bash infra/gate/pitr_drill.sh

Uses its own containers and volumes (`sb-pitr-*`, `sb_pitr_*`), never your
`pgdata` volumes. `KEEP=1` keeps them for inspection. The RPO result is a
demonstration of the measuring logic. It does not prove the 15-minute RPO,
and the restore time is from a tiny data set. The real test is on Cloud SQL.

## 4. Cloud SQL (week 2)

Billing starts when the instance is created. Check Google's pricing page first
and tear down the same day.

    PROJECT=<id> REGION=<region> AUTHORIZED_NETWORKS=<your-ip>/32 DRY_RUN=1 bash infra/gate/gcp_create.sh
    PROJECT=<id> REGION=<region> AUTHORIZED_NETWORKS=<your-ip>/32 bash infra/gate/gcp_create.sh

Then set the password yourself with the command printed at the end (typed, not
shown). Load the table with the same three SQL files against the new instance,
then run the benchmark with its connection string (verify: how to connect,
authorized network or Cloud SQL Auth Proxy).

Teardown (dry run first):

    PROJECT=<id> DRY_RUN=1 bash infra/gate/gcp_teardown.sh
    PROJECT=<id> bash infra/gate/gcp_teardown.sh

Check the console afterwards for backups and billing. The script does not.

## Notes: warm-up and ramp-up (measured locally on PG18, cause not established)

`benchmark.py` runs one untimed real query per connection before the timed
phases (at the largest radius). The warm-up times are written to the JSON under
`warmup`. `--no-warmup` restores the old behaviour.

What was measured (local, single machine, several runs each):
- Without warm-up, the first radius had a high p99 (2 km: 1190 to 1361 ms in
  3 of 3 runs). With warm-up, 2 km p99 was 174 to 234 ms in 4 of 4 runs in the
  normal order (2, 5, 10).
- In the reverse order (10, 5, 2), the first radius (10 km) still had p95
  502 to 752 ms in 5 of 5 runs with warm-up, at either 2 km or 10 km.
- With `10,10,10` the same radius got faster in each phase (p95 497, 426, 250 ms
  and 384, 323, 269 ms). The settled 10 km level is about 250 to 270 ms p95.

Not known: the cause (data pages, Docker VM, host CPU load and the 100 client
threads were not separated). The warm-up time includes contention between the
100 parallel queries, so it is not the cost of one query.

Rule for the week-2 cloud run: run the benchmark twice in a row and report both
runs. The verdict still uses every phase, including the first. If a first radius
is close to 500 ms, repeat before drawing a conclusion.

## Verify in week 2

- `SELECT postgis_full_version();` on Cloud SQL (Google sets the PostGIS version).
- A real point-in-time recovery on Cloud SQL (SRS TEST-07).
- Cloud SQL connection limit at 2 CPU / 8 GiB, and the benchmark's connect failures.
- Whether `delete` takes a final backup by default, and the real `--uri` output.
- Prices, backup location, and the default database user.
