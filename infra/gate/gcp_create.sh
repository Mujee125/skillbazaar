#!/usr/bin/env bash
# Create the Cloud SQL gate instance (SB-E00-013 T4).
# Required: PROJECT, REGION, AUTHORIZED_NETWORKS (your public IP as x.x.x.x/32).
# Optional: CPU (2), MEMORY (8GiB), BACKUP_START_UTC (21:00), BACKUP_LOCATION, DRY_RUN=1.
# No password is handled here. Set it afterwards with the command printed at the end.
# Not tested against real GCP until the week 2 window.
set -euo pipefail

: "${PROJECT:?set PROJECT (GCP project id)}"
: "${REGION:?set REGION (for example asia-south1; verify the region list)}"
: "${AUTHORIZED_NETWORKS:?set AUTHORIZED_NETWORKS to your public IP as x.x.x.x/32}"
CPU="${CPU:-2}"
MEMORY="${MEMORY:-8GiB}"
BACKUP_START_UTC="${BACKUP_START_UTC:-21:00}"
DRY_RUN="${DRY_RUN:-0}"

valid_host_cidr() {  # exactly one IPv4 address with /32, never 0.0.0.0
  [[ $1 == */32 ]] || return 1
  local ip="${1%/32}" o
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local -a oct
  IFS=. read -r -a oct <<< "$ip"
  for o in "${oct[@]}"; do (( 10#$o <= 255 )) || return 1; done
  [ "$ip" != "0.0.0.0" ]
}
valid_host_cidr "$AUTHORIZED_NETWORKS" \
  || { echo "AUTHORIZED_NETWORKS must be one address like 203.0.113.7/32 (got: $AUTHORIZED_NETWORKS)" >&2; exit 1; }
[[ $REGION =~ ^[a-z]+-[a-z]+[0-9]+$ ]] \
  || { echo "REGION does not look like a GCP region: $REGION" >&2; exit 1; }

INSTANCE="sb-gate-${REGION}-$(date -u +%Y%m%d%H%M)"

FLAGS=(
  --region="$REGION"
  --database-version=POSTGRES_18
  --edition=enterprise
  --cpu="$CPU"
  --memory="$MEMORY"
  --availability-type=zonal
  --storage-size=10
  --backup
  --backup-start-time="$BACKUP_START_UTC"
  --enable-point-in-time-recovery
  --retained-transaction-log-days=7
  --no-deletion-protection
  --assign-ip
  --authorized-networks="$AUTHORIZED_NETWORKS"
)
if [ -n "${BACKUP_LOCATION:-}" ]; then FLAGS+=(--backup-location="$BACKUP_LOCATION"); fi

# Self-check: every flag used must exist in this gcloud version's help (no login needed)
command -v gcloud >/dev/null || { echo "gcloud not found" >&2; exit 1; }
HELP=$(mktemp); trap 'rm -f "$HELP"' EXIT
gcloud sql instances create --help > "$HELP" 2>&1
missing=0
for f in "${FLAGS[@]}"; do
  name="${f%%=*}"; name="${name#--}"; name="${name#no-}"
  grep -Eq -- "^[[:space:]]+--(\[no-\]|no-)?${name}([ =]|$)" "$HELP" \
    || { echo "flag not found in this gcloud version: --$name" >&2; missing=1; }
done
[ "$missing" = 0 ] || exit 1
echo "flag self-check: ${#FLAGS[@]} flags found in gcloud help"

CMD=(gcloud sql instances create "$INSTANCE" --project="$PROJECT" "${FLAGS[@]}")
echo "instance: $INSTANCE"
printf '%q ' "${CMD[@]}"; echo

if [ "$DRY_RUN" = 1 ]; then
  echo "DRY RUN: nothing was created"
  exit 0
fi

read -r -p "Create this instance now (it costs credit)? Type yes: " ans
[ "$ans" = yes ] || { echo "aborted"; exit 1; }
"${CMD[@]}"
echo
echo "Next, set the password yourself (typed, not shown):"
echo "  gcloud sql users set-password postgres --instance=$INSTANCE --project=$PROJECT --prompt-for-password"