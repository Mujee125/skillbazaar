#!/usr/bin/env bash
# SB-E00-013 T5: delete the Cloud SQL gate instances (name prefix sb-gate-), then list what remains.
# Required: PROJECT. Optional: DRY_RUN=1 (list only, delete nothing).
# Usage: PROJECT=my-project DRY_RUN=1 bash infra/gate/gcp_teardown.sh
set -euo pipefail

PREFIX="sb-gate-"
: "${PROJECT:?set PROJECT (the GCP project id)}"
DRY_RUN="${DRY_RUN:-0}"

command -v gcloud >/dev/null || { echo "ERROR: gcloud not found in PATH" >&2; exit 1; }

# 1. Flag self-check against the installed gcloud help (read-only, needs no login)
HELP_DIR=$(mktemp -d)
trap 'rm -rf "$HELP_DIR"' EXIT
gcloud sql instances delete --help > "$HELP_DIR/delete.txt"
gcloud sql instances patch --help > "$HELP_DIR/patch.txt"
gcloud sql instances list --help > "$HELP_DIR/list.txt"

missing=0
found=0
check() {  # file, regex, label
  if grep -q -E -e "$2" "$HELP_DIR/$1"; then
    found=$((found + 1))
  else
    echo "ERROR: not found in gcloud help ($1): $3" >&2
    missing=1
  fi
}
check patch.txt '^[[:space:]]+--(\[no-\]|no-)?deletion-protection([ =]|$)' "--[no-]deletion-protection"
check list.txt '^[[:space:]]+--uri([ =]|$)' "--uri"
check delete.txt '^[[:space:]]+INSTANCE$' "INSTANCE argument"
check delete.txt '--project' "--project"
check delete.txt '--quiet' "--quiet"
[ "$missing" -eq 0 ] || { echo "Stopping: this gcloud version differs from the one the script was written for." >&2; exit 1; }
echo "flag self-check: $found items found in gcloud help"

# 2. List instance names (last part of each URI). A failed list stops the script.
list_names() {
  local uris u
  uris=$(gcloud sql instances list --project="$PROJECT" --uri) || return 1
  while IFS= read -r u; do
    u=${u%$'\r'}
    if [ -n "$u" ]; then echo "${u##*/}"; fi
  done <<< "$uris"
}

names=$(list_names) || { echo "ERROR: could not list instances (not logged in? wrong PROJECT?). Nothing was deleted." >&2; exit 1; }

targets=()
while IFS= read -r n; do
  case "$n" in
    "$PREFIX"*) [[ "$n" =~ ^sb-gate-[a-z0-9-]+$ ]] && targets+=("$n") ;;
  esac
done <<< "$names"

echo "Project: $PROJECT"
if [ "${#targets[@]}" -eq 0 ]; then
  echo "No instances with prefix $PREFIX. Nothing to delete."
else
  echo "Instances to delete (${#targets[@]}):"
  printf '  %s\n' "${targets[@]}"
fi

# 3. Dry run: show the commands only
if [ "$DRY_RUN" = "1" ]; then
  for n in "${targets[@]+"${targets[@]}"}"; do
    echo "would run: gcloud sql instances patch $n --project=$PROJECT --no-deletion-protection --quiet"
    echo "would run: gcloud sql instances delete $n --project=$PROJECT --quiet"
  done
  echo "DRY RUN: nothing was deleted"
  exit 0
fi

# 4. Real run: ask, then patch and delete one instance at a time
failed=0
if [ "${#targets[@]}" -gt 0 ]; then
  read -r -p "Type yes to DELETE these instances and all their data: " answer || answer=""
  [ "$answer" = "yes" ] || { echo "Aborted. Nothing was deleted."; exit 1; }
  for n in "${targets[@]}"; do
    echo "--- $n: disabling deletion protection"
    if ! gcloud sql instances patch "$n" --project="$PROJECT" --no-deletion-protection --quiet; then
      echo "ERROR: patch failed for $n" >&2; failed=1; continue
    fi
    echo "--- $n: deleting"
    if ! gcloud sql instances delete "$n" --project="$PROJECT" --quiet; then
      echo "ERROR: delete failed for $n" >&2; failed=1
    fi
  done
fi

# 5. List what remains
final=$(list_names) || { echo "ERROR: could not list what remains. Check the console." >&2; exit 1; }
left_gate=(); left_other=()
while IFS= read -r n; do
  [ -n "$n" ] || continue
  case "$n" in
    "$PREFIX"*) left_gate+=("$n") ;;
    *) left_other+=("$n") ;;
  esac
done <<< "$final"

if [ "${#left_gate[@]}" -gt 0 ]; then
  echo "STILL PRESENT (sb-gate-):"; printf '  %s\n' "${left_gate[@]}"
  failed=1
elif [ "${#left_other[@]}" -eq 0 ]; then
  echo "nothing left: the project has no Cloud SQL instances"
else
  echo "nothing left: no $PREFIX instances remain"
fi
if [ "${#left_other[@]}" -gt 0 ]; then
  echo "Other instances (not touched by this script):"; printf '  %s\n' "${left_other[@]}"
fi
echo "Not checked here (verify in the console): final or on-demand backups, and Billing."
exit "$failed"
