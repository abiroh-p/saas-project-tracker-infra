#!/usr/bin/env bash
# Run the Django migration job (migrate + createcachetable) and wait for it to finish.
# Run this before rolling out any new API revision. 03-deploy-apps.sh calls it for you.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_common.sh"
ensure_containerapp_ext

PG="$(pg_name)"
require "No Postgres server in $RG." "$PG"
STATE="$(pg_state "$PG")"
[[ "$STATE" == "Ready" ]] || die "Postgres is '$STATE'. Run scripts/resume.sh first."

EXEC="$(azt containerapp job start -n migrate -g "$RG" --query name)"
require "Could not start the migrate job (has phase 2 been deployed?)." "$EXEC"
echo ">> Started execution $EXEC"

deadline=$((SECONDS + 660))   # the job's own replicaTimeout is 600s
status="Unknown"
while :; do
  status="$(azt containerapp job execution show -n migrate -g "$RG" --job-execution-name "$EXEC" --query properties.status)"
  echo "   $status"
  case "$status" in
    Succeeded) echo "Migration finished."; exit 0 ;;
    Failed|Stopped|Degraded) break ;;
  esac
  if (( SECONDS >= deadline )); then echo "Timed out waiting for the job."; break; fi
  sleep 10
done

echo
echo "Migration did not succeed (status: $status). Container logs (they can lag a minute or two):"
az containerapp job logs show -n migrate -g "$RG" --container migrate --execution "$EXEC" --tail 100 --format text \
  || echo "Logs not available yet; try again shortly."
exit 1
