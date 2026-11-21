#!/usr/bin/env python3
"""Gate benchmark for SB-E00-013 / SB-E00-004.

Runs a nearest-first ST_DWithin query from many concurrent clients against
gate_provider_locations, and reports latency, error rate and throughput.
It measures speed, errors, and database performance.
Takes a DSN, so it runs against local Postgres, Cloud SQL or DigitalOcean.

Exit code: 0 = PASS, 1 = FAIL, 2 = could not start.
Local runs validate the script only. They are not the gate verdict.
"""
import argparse
import collections
import json
import math
import os
import random
import sys
import threading
import time
from datetime import datetime, timezone

import psycopg
from psycopg.conninfo import conninfo_to_dict

# Same centres and weights as 02_seed.sql
CITIES = [
    ("karachi", 67.0011, 24.8607, 0.40),
    ("lahore", 74.3587, 31.5204, 0.35),
    ("islamabad", 73.0479, 33.6844, 0.25),
]
P95_TARGET_MS = 500       # backlog gate target
P95_REFERENCE_MS = 2000   # SRS v3.0 PERF-03, shown for reference only

QUERY = """
SELECT id FROM gate_provider_locations
WHERE online
  AND category_id = %(cat)s
  AND ST_DWithin(location,
                 ST_SetSRID(ST_MakePoint(%(lon)s, %(lat)s), 4326)::geography,
                 %(radius)s)
ORDER BY location <-> ST_SetSRID(ST_MakePoint(%(lon)s, %(lat)s), 4326)::geography
LIMIT %(limit)s
"""


def percentile(sorted_vals, p):
    if not sorted_vals:
        return None
    k = max(0, math.ceil(p / 100 * len(sorted_vals)) - 1)
    return sorted_vals[k]


def make_params(rng, radius_m, limit):
    _, lon, lat, _ = rng.choices(CITIES, weights=[c[3] for c in CITIES])[0]
    # Same bell-shaped spread as the seed
    dlon = (rng.random() + rng.random() + rng.random() - 1.5) * 0.1
    dlat = (rng.random() + rng.random() + rng.random() - 1.5) * 0.1
    return {
        "cat": rng.randint(1, 10),
        "lon": lon + dlon,
        "lat": lat + dlat,
        "radius": float(radius_m),
        "limit": limit,
    }


def node_types(plan):
    found = [plan["Node Type"]]
    for child in plan.get("Plans", []):
        found += node_types(child)
    return found


def explain_once(conn, params):
    # Client-side binding: EXPLAIN does not take server-side parameters
    with psycopg.ClientCursor(conn) as cur:
        cur.execute("EXPLAIN (ANALYZE, FORMAT JSON) " + QUERY, params)
        doc = cur.fetchone()[0]
    if isinstance(doc, str):
        doc = json.loads(doc)
    top = doc[0]
    return {
        "execution_ms": top["Execution Time"],
        "planning_ms": top["Planning Time"],
        "nodes": node_types(top["Plan"]),
    }


def worker(conn, rng, radius_m, n_queries, limit, barrier, results, idx):
    latencies, errors = [], []
    barrier.wait()
    for _ in range(n_queries):
        params = make_params(rng, radius_m, limit)
        t0 = time.perf_counter()
        try:
            with conn.cursor() as cur:
                cur.execute(QUERY, params)
                cur.fetchall()
            latencies.append((time.perf_counter() - t0) * 1000)
        except Exception as exc:
            errors.append(type(exc).__name__)
    results[idx] = (latencies, errors)


def run_phase(conns, radius_km, args, seed_base):
    n = len(conns)
    barrier = threading.Barrier(n + 1)
    results = [([], [])] * n
    threads = []
    for i, conn in enumerate(conns):
        rng = random.Random(seed_base + i)
        t = threading.Thread(
            target=worker,
            args=(conn, rng, radius_km * 1000, args.queries_per_client,
                  args.limit, barrier, results, i),
        )
        t.start()
        threads.append(t)
    barrier.wait()  # all clients start together
    t0 = time.perf_counter()
    for t in threads:
        t.join()
    wall = time.perf_counter() - t0

    lat = sorted(x for r in results for x in r[0])
    errs = collections.Counter(e for r in results for e in r[1])
    ok = len(lat)
    n_err = sum(errs.values())
    return {
        "radius_km": radius_km,
        "queries_ok": ok,
        "query_errors": n_err,
        "error_types": dict(errs),
        "error_rate": n_err / (ok + n_err) if (ok + n_err) else None,
        "qps": ok / wall if wall > 0 else None,
        "p50_ms": percentile(lat, 50),
        "p95_ms": percentile(lat, 95),
        "p99_ms": percentile(lat, 99),
        "max_ms": lat[-1] if lat else None,
        "wall_s": wall,
    }


def warmup(conns, radius_km, args):
    """One untimed real query per connection, all connections in parallel.
    Not part of any timed phase. Returns (sorted times in ms, error type names)."""
    times = [None] * len(conns)
    errors = [None] * len(conns)

    def one(i, conn):
        params = make_params(random.Random(args.seed * 7919 + i), radius_km * 1000, args.limit)
        t0 = time.perf_counter()
        try:
            with conn.cursor() as cur:
                cur.execute(QUERY, params)
                cur.fetchall()
            times[i] = (time.perf_counter() - t0) * 1000
        except Exception as exc:
            errors[i] = type(exc).__name__

    threads = [threading.Thread(target=one, args=(i, c)) for i, c in enumerate(conns)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return sorted(t for t in times if t is not None), [e for e in errors if e]


def fmt(v, spec=".1f"):
    return "n/a" if v is None else format(v, spec)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dsn", default=os.environ.get("GATE_DSN"),
                    help="Postgres connection string (or set GATE_DSN)")
    ap.add_argument("--clients", type=int, default=100)
    ap.add_argument("--queries-per-client", type=int, default=20)
    ap.add_argument("--radii-km", default="2,5,10")
    ap.add_argument("--limit", type=int, default=20,
                    help="nearest providers returned (assumption, SRS gives none)")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--label", default="local",
                    help="used in the output file name, e.g. local or gcp-mumbai")
    ap.add_argument("--out-dir", default="docs/gate-evidence")
    ap.add_argument("--provider", default="local-docker",
                    help="Evidence label: where the database runs, e.g. aws-ec2")
    ap.add_argument("--region", default="local",
                    help="Evidence label: cloud region, e.g. ap-south-1")
    ap.add_argument("--endpoint-type", default="direct", choices=["direct", "pooled"],
                    help="Evidence label: direct or pooled connection")
    ap.add_argument("--no-warmup", action="store_true",
                    help="skip the untimed warm-up query per connection (old behaviour)")
    args = ap.parse_args()

    if not args.dsn:
        print("ERROR: give --dsn or set GATE_DSN", file=sys.stderr)
        return 2
    radii = [int(x) for x in args.radii_km.split(",")]

    try:
        main_conn = psycopg.connect(args.dsn, autocommit=True, connect_timeout=10)
        with main_conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM gate_provider_locations")
            row_count = cur.fetchone()[0]
    except Exception as exc:
        print(f"ERROR: cannot read gate table: {type(exc).__name__}", file=sys.stderr)
        return 2

    # Unloaded EXPLAIN per radius (also warms the cache)
    explains = {}
    for km in radii:
        p = make_params(random.Random(args.seed), km * 1000, args.limit)
        explains[km] = explain_once(main_conn, p)

    # One connection per client
    conns, connect_failures = [], []
    for _ in range(args.clients):
        try:
            conns.append(psycopg.connect(args.dsn, autocommit=True, connect_timeout=10))
        except Exception as exc:
            msg = str(exc).splitlines()[0] if str(exc) else ""
            connect_failures.append(f"{type(exc).__name__}: {msg}")

    print(f"rows={row_count} clients_connected={len(conns)}/{args.clients} "
          f"connect_failures={len(connect_failures)}")

    warm_ms, warm_errs = [], []
    if conns and not args.no_warmup:
        warm_ms, warm_errs = warmup(conns, max(radii), args)
        print(f"warm-up (untimed, {max(radii)} km): {len(warm_ms)}/{len(conns)} ok, "
              f"errors={len(warm_errs)}, p50={fmt(percentile(warm_ms, 50))} "
              f"p95={fmt(percentile(warm_ms, 95))} p99={fmt(percentile(warm_ms, 99))} ms")
    elif args.no_warmup:
        print("warm-up: skipped (--no-warmup)")
    phases = []
    for i, km in enumerate(radii):
        if conns:
            phases.append(run_phase(conns, km, args, args.seed * 1000 + i * 1000))
    for c in conns:
        c.close()
    main_conn.close()

    passed = (not connect_failures and not warm_errs and len(phases) == len(radii) and all(
        ph["query_errors"] == 0 and ph["p95_ms"] is not None
        and ph["p95_ms"] <= P95_TARGET_MS for ph in phases))
    ref_passed = bool(phases) and all(
        ph["p95_ms"] is not None and ph["p95_ms"] <= P95_REFERENCE_MS for ph in phases)

    print(f"{'km':>3} {'ok':>6} {'err':>4} {'err%':>6} {'qps':>8} "
          f"{'p50':>8} {'p95':>8} {'p99':>8} {'explain':>9}")
    for ph in phases:
        print(f"{ph['radius_km']:>3} {ph['queries_ok']:>6} {ph['query_errors']:>4} "
              f"{fmt((ph['error_rate'] or 0) * 100, '.2f'):>6} {fmt(ph['qps']):>8} "
              f"{fmt(ph['p50_ms']):>8} {fmt(ph['p95_ms']):>8} {fmt(ph['p99_ms']):>8} "
              f"{fmt(explains[ph['radius_km']]['execution_ms']):>9}")
    print("(times in ms; explain = server-side time, one unloaded query)")
    print(f"VERDICT: {'PASS' if passed else 'FAIL'} "
          f"(target: p95 <= {P95_TARGET_MS} ms at every radius, zero errors)")
    print(f"Reference only (SRS PERF-03, not the dispatch target): "
          f"p95 <= {P95_REFERENCE_MS} ms -> {'yes' if ref_passed else 'no'}")

    info = conninfo_to_dict(args.dsn)  # never write the password
    now = datetime.now(timezone.utc)
    doc = {
        "timestamp_utc": now.isoformat(timespec="seconds"),
        "label": args.label,
                "target": {
            "provider": args.provider, "region": args.region,
            "endpoint_type": args.endpoint_type,
            "port": info.get("port"), "dbname": info.get("dbname"),
        },
        "psycopg_version": psycopg.__version__,
        "row_count": row_count,
        "parameters": {
            "clients": args.clients, "queries_per_client": args.queries_per_client,
            "radii_km": radii, "limit": args.limit, "seed": args.seed,
            "query": " ".join(QUERY.split()),
        },
        "connect_failures": connect_failures,
        "warmup": {
            "enabled": not args.no_warmup, "radius_km": max(radii),
            "ok": len(warm_ms), "errors": warm_errs,
            "p50_ms": percentile(warm_ms, 50), "p95_ms": percentile(warm_ms, 95),
            "p99_ms": percentile(warm_ms, 99), "max_ms": warm_ms[-1] if warm_ms else None,
        },
        "explain_unloaded": {str(k): v for k, v in explains.items()},
        "results": phases,
        "verdict": {
            "passed": passed, "target_p95_ms": P95_TARGET_MS,
            "reference_p95_ms": P95_REFERENCE_MS, "reference_passed": ref_passed,
        },
        "note": "Local runs validate the script only. They are not the gate verdict.",
    }
    os.makedirs(args.out_dir, exist_ok=True)
    path = os.path.join(
        args.out_dir, f"benchmark-{args.label}-{now.strftime('%Y%m%dT%H%M%SZ')}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)
    print(f"wrote {path}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())