#!/usr/bin/env bash
# Local PITR drill for SB-E00-013 T3 (measuring logic, tested locally before the cloud window).
# Uses a disposable Postgres container and three Docker volumes, all named sb_pitr_*
# and labelled com.skillbazaar.drill=pitr. It never mounts or names any other volume.
# Cleanup removes only resources with that label AND that name prefix.
# KEEP=1 keeps the resources afterwards (the next run cleans them up first).
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: stop /archive being rewritten to a Windows path

IMAGE="${PITR_IMAGE:-postgis/postgis:18-3.7}"
LABEL="com.skillbazaar.drill=pitr"
SRV=sb-pitr-drill
RST=sb-pitr-restore
RPO_FIGURE_S=900      # SRS v3.0 REL-04 (15 min)
RTO_FIGURE_S=14400    # SRS v3.0 REL-05 (4 h)
EXPECTED="pre-backup,before-T-1,before-T-2,before-T-3,before-T-4,before-T-5"

psql_in() { local c="$1"; shift; docker exec "$c" psql -U postgres -v ON_ERROR_STOP=1 -qAt "$@"; }

cleanup() {
  local c v name
  for c in $(docker ps -aq --filter "label=$LABEL"); do
    name=$(docker inspect -f '{{.Name}}' "$c" | sed 's#^/##')
    case "$name" in
      sb-pitr-*) docker rm -f "$c" >/dev/null && echo "cleanup: removed container $name" \
                   || echo "cleanup: could not remove $name" ;;
    esac
  done
  for v in $(docker volume ls -q --filter "label=$LABEL"); do
    case "$v" in
      sb_pitr_*) docker volume rm "$v" >/dev/null && echo "cleanup: removed volume $v" \
                   || echo "cleanup: could not remove $v" ;;
    esac
  done
}

guard_volume() {  # refuse to touch a volume that is not ours
  local l
  l=$(docker volume inspect -f '{{index .Labels "com.skillbazaar.drill"}}' "$1")
  case "$1" in sb_pitr_*) ;; *) echo "refusing: $1 is not a drill volume" >&2; exit 1 ;; esac
  [ "$l" = "pitr" ] || { echo "refusing: $1 has no drill label" >&2; exit 1; }
}

trap 'echo "FAILED at line $LINENO (run with KEEP=1 to keep the drill resources)" >&2' ERR
trap '[ "${KEEP:-0}" = 1 ] || cleanup' EXIT

echo "== 1. clean start"
cleanup
for v in data archive backup; do docker volume create --label "$LABEL" "sb_pitr_$v" >/dev/null; done
docker run --rm --user root -v sb_pitr_archive:/archive -v sb_pitr_backup:/backup "$IMAGE" \
  chown postgres:postgres /archive /backup

echo "== 2. server with WAL archiving"
docker run -d --name "$SRV" --label "$LABEL" -e POSTGRES_PASSWORD=drill_only \
  -v sb_pitr_data:/var/lib/postgresql -v sb_pitr_archive:/archive -v sb_pitr_backup:/backup \
  "$IMAGE" postgres -c archive_mode=on \
  -c "archive_command=test ! -f /archive/%f && cp %p /archive/%f" >/dev/null
for i in $(seq 1 90); do
  if docker exec "$SRV" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then break; fi
  sleep 1
done
docker exec "$SRV" pg_isready -h 127.0.0.1 -U postgres >/dev/null

echo "== 3. markers, base backup, more markers around T"
psql_in "$SRV" -c "CREATE TABLE drill_markers (id serial PRIMARY KEY, label text NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp());" \
               -c "INSERT INTO drill_markers(label) VALUES ('pre-backup');"
docker exec -u postgres "$SRV" pg_basebackup -U postgres -D /backup/base -Fp -X none -c fast
line=$(docker exec "$SRV" grep '^START WAL LOCATION' /backup/base/backup_label)
[[ $line =~ \(file\ ([0-9A-F]{24})\) ]] || { echo "cannot read backup start segment" >&2; exit 1; }
START_SEG="${BASH_REMATCH[1]}"
for i in 1 2 3 4 5; do psql_in "$SRV" -c "INSERT INTO drill_markers(label) VALUES ('before-T-$i');"; sleep 1; done
sleep 1
T=$(psql_in "$SRV" -c "SELECT clock_timestamp();")
sleep 2
for i in 1 2 3; do psql_in "$SRV" -c "INSERT INTO drill_markers(label) VALUES ('after-T-$i');"; sleep 1; done
docker exec -u postgres "$SRV" sh -c "echo '$T' > /backup/target_time.txt"
DISASTER_TS=$(psql_in "$SRV" -c "SELECT max(created_at) FROM drill_markers;")
echo "target T: $T | backup starts at segment $START_SEG"

echo "== 4. archive the last WAL and check the archive is complete"
LAST=$(psql_in "$SRV" -c "SELECT pg_walfile_name(pg_switch_wal());")
A=""
for i in $(seq 1 60); do
  A=$(psql_in "$SRV" -c "SELECT last_archived_wal FROM pg_stat_archiver;")
  if [ "$A" = "$LAST" ]; then break; fi
  sleep 1
done
[ "$A" = "$LAST" ] || { echo "last segment $LAST was not archived" >&2; exit 1; }
[ "$(psql_in "$SRV" -c "SELECT failed_count FROM pg_stat_archiver;")" = 0 ] \
  || { echo "archiver reported failures" >&2; exit 1; }
# Segment name = 8 hex timeline + 8 hex log + 8 hex segment. Same log id is assumed (tiny drill).
[ "${START_SEG:0:16}" = "${LAST:0:16}" ] || { echo "segments span two log ids" >&2; exit 1; }
need=0
for n in $(seq $((16#${START_SEG:16:8})) $((16#${LAST:16:8}))); do
  seg=$(printf '%s%08X' "${START_SEG:0:16}" "$n")
  docker exec "$SRV" test -f "/archive/$seg" || { echo "MISSING WAL segment $seg" >&2; exit 1; }
  need=$((need+1))
done
echo "WAL segments needed $START_SEG to $LAST: $need, all present in the archive"
docker stop "$SRV" >/dev/null
docker rm "$SRV" >/dev/null

echo "== 5. disaster: wipe the disposable data directory"
guard_volume sb_pitr_data
docker run --rm --user root -e START_SEG="$START_SEG" -e LAST="$LAST" \
  -v sb_pitr_data:/data -v sb_pitr_archive:/archive:ro -v sb_pitr_backup:/backup:ro \
  "$IMAGE" sh -c '
set -e
ls "/archive/$START_SEG" "/archive/$LAST" /backup/base/backup_label /backup/target_time.txt >/dev/null
echo "files before wipe: $(ls -A /data | wc -l)"
find /data -mindepth 1 -delete
echo "files after wipe: $(ls -A /data | wc -l)"
'

echo "== 6. restore to T (timed)"
guard_volume sb_pitr_data
START=$(date +%s%3N)
docker run --rm --user root -v sb_pitr_data:/data -v sb_pitr_backup:/backup:ro "$IMAGE" \
  sh -c 'mkdir -p /data/18/docker && cp -a /backup/base/. /data/18/docker/ && touch /data/18/docker/recovery.signal && chown -R postgres:postgres /data && chmod 700 /data/18/docker'
docker run -d --name "$RST" --label "$LABEL" \
  -v sb_pitr_data:/var/lib/postgresql -v sb_pitr_archive:/archive:ro "$IMAGE" \
  postgres -c "restore_command=cp /archive/%f %p" -c "recovery_target_time=$T" \
  -c recovery_target_action=promote >/dev/null
R=""
for i in $(seq 1 180); do
  R=$(psql_in "$RST" -c "SELECT pg_is_in_recovery();" 2>/dev/null) || R=""
  if [ "$R" = "f" ]; then break; fi
  sleep 1
done
END=$(date +%s%3N)
[ "$R" = "f" ] || { echo "restore did not finish" >&2; docker logs "$RST" 2>&1 | tail -20 >&2; exit 1; }
MS=$((END-START))
RESTORE_S="$((MS/1000)).$(printf '%03d' $((MS%1000)))"

echo "== 7. verify"
GOT=$(psql_in "$RST" -c "SELECT string_agg(label, ',' ORDER BY id) FROM drill_markers;")
LAST_REC=$(psql_in "$RST" -c "SELECT max(created_at) FROM drill_markers;")
LOSS=$(psql_in "$RST" -c "SELECT round(extract(epoch FROM ('$DISASTER_TS'::timestamptz - '$LAST_REC'::timestamptz))::numeric, 1);")
echo "recovered markers: $GOT"
OK=no
if [ "$GOT" = "$EXPECTED" ]; then OK=yes; fi

echo
echo "== PITR drill result (local) =="
echo "markers before T present, markers after T absent: $OK"
echo "restore time: ${RESTORE_S} s (REL-05 figure: ${RTO_FIGURE_S} s; tiny data set, not an RTO proof)"
echo "data-loss window: ${LOSS} s (REL-04 figure: ${RPO_FIGURE_S} s)"
echo "RPO note: this is an RPO measurement-logic demonstration. T is chosen by the drill,"
echo "so it does not prove the 15-minute RPO. That is tested on Cloud SQL in week 2."
if [ "$OK" = yes ]; then echo "DRILL RESULT: PASS (marker check)"; else echo "DRILL RESULT: FAIL (marker check)"; exit 1; fi