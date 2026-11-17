#!/usr/bin/env bash
# SB-E00-013 T6: one-command local gate run.
# Steps: db up, schema + seed + index, checks, benchmark.
# Optional: LABEL (default pg18-local), COMPOSE_PROJECT_NAME (separate stack, e.g. sbclean).
# Exit: the benchmark's code (0 PASS, 1 FAIL, 2 cannot start), 3 = setup or check failed.
# Local numbers validate the scripts only. They are not the gate verdict.
set -euo pipefail

LABEL="${LABEL:-pg18-local}"
[[ "$LABEL" =~ ^[A-Za-z0-9-]+$ ]] || { echo "ERROR: LABEL may only contain letters, digits and '-'" >&2; exit 3; }

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
[ -f docker-compose.yml ] || { echo "ERROR: docker-compose.yml not found in $(pwd)" >&2; exit 3; }
command -v docker >/dev/null || { echo "ERROR: docker not found in PATH" >&2; exit 3; }

EXPECTED_ROWS=50000
INDEX_NAME="gate_provider_locations_location_gist"
DSN="postgresql://sb:sb_dev_only@db:5432/skillbazaar"

psql_db() { docker compose exec -T db psql -U sb -d skillbazaar -v ON_ERROR_STOP=1 "$@"; }

echo "[1/5] starting db (waits until healthy)"
docker compose up -d --wait db

for f in 01_schema.sql 02_seed.sql 03_index.sql; do
  echo "[2/5] applying infra/gate/$f"
  psql_db < "infra/gate/$f" > /dev/null || { echo "ERROR: $f failed" >&2; exit 3; }
done

echo "[3/5] checking the table"
rows=$(psql_db -tA -c "SELECT count(*) FROM gate_provider_locations" </dev/null | tr -d '[:space:]')
idx=$(psql_db -tA -c "SELECT count(*) FROM pg_indexes WHERE indexname = '$INDEX_NAME'" </dev/null | tr -d '[:space:]')
echo "      rows=$rows (expected $EXPECTED_ROWS), gist index present=$idx (expected 1)"
[ "$rows" = "$EXPECTED_ROWS" ] || { echo "ERROR: wrong row count" >&2; exit 3; }
[ "$idx" = "1" ] || { echo "ERROR: GiST index missing" >&2; exit 3; }

echo "[4/5] running the benchmark (label $LABEL)"
HERE=$(pwd -W 2>/dev/null || pwd)
mkdir -p docs/gate-evidence
set +e
MSYS_NO_PATHCONV=1 docker compose run --rm -T \
  -v "$HERE/infra/gate:/gate:ro" -v "$HERE/docs/gate-evidence:/out" \
  backend python /gate/benchmark.py --dsn "$DSN" --label "$LABEL" --out-dir /out
rc=$?
set -e

echo "[5/5] benchmark exit code: $rc (0 PASS, 1 FAIL, 2 cannot start)"
echo "Local numbers validate the scripts only. The gate verdict comes from the cloud run."
exit "$rc"
