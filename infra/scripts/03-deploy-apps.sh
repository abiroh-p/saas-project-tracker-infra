#!/usr/bin/env bash
# Phase 2b: deploy the web + api apps and the migration job, run the migration, then smoke-test.
# Uses the newest api/web tags in the registry unless API_IMAGE_TAG / WEB_IMAGE_TAG are set.
#
#   SKIP_MIGRATE=1   deploy only
#   SKIP_SMOKE=1     skip the smoke test
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_common.sh"
# shellcheck disable=SC1091
source "$INFRA/.deploy.env"

ACR="$(acr_name)"
require "No registry in $RG. Run 01-deploy-platform.sh first." "$ACR"
PG="$(pg_name)"
require "No Postgres server in $RG. Run 01-deploy-platform.sh first." "$PG"

STATE="$(pg_state "$PG")"
[[ "$STATE" == "Ready" ]] || die "Postgres is '$STATE'. Run scripts/resume.sh first (deploying against a stopped server fails)."

latest_tag() { azt acr repository show-tags -n "$ACR" --repository "$1" --orderby time_desc --top 1 2>/dev/null || true; }
API_IMAGE_TAG="${API_IMAGE_TAG:-$(latest_tag api)}"
WEB_IMAGE_TAG="${WEB_IMAGE_TAG:-$(latest_tag web)}"
require "No 'api' image in $ACR. Run 02-build-push.sh first." "$API_IMAGE_TAG"
require "No 'web' image in $ACR. Run 02-build-push.sh first." "$WEB_IMAGE_TAG"
export DEPLOY_APPS=true API_IMAGE_TAG WEB_IMAGE_TAG

echo "Deploying api:$API_IMAGE_TAG and web:$WEB_IMAGE_TAG from $ACR"
cd "$INFRA"
az bicep upgrade -o none

echo ">> What-if (nothing is changed yet)"
az deployment group what-if -g "$RG" -p main.bicepparam

read -rp "Apply this deployment? [y/N] " ans
[[ "$ans" == "y" ]] || { echo "Aborted."; exit 0; }

az deployment group create -g "$RG" -n apps -p main.bicepparam \
  --query properties.outputs -o json

[[ "${SKIP_MIGRATE:-0}" == "1" ]] || bash "$HERE/migrate.sh"
[[ "${SKIP_SMOKE:-0}" == "1" ]] || bash "$HERE/04-smoke-test.sh"
