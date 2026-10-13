#!/usr/bin/env bash
# Phase 1: platform only (logs, App Insights, ACR, Postgres, Container Apps environment).
# Billing starts here (Postgres is the main fixed cost). Shows a what-if before changing anything.
set -euo pipefail

RG="${RG:-rg-ptracker-prod}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$(cd "$HERE/.." && pwd)"

# shellcheck disable=SC1091
source "$INFRA/.deploy.env"
export DEPLOY_APPS=false

cd "$INFRA"
az bicep upgrade -o none

echo ">> What-if (nothing is changed yet)"
az deployment group what-if -g "$RG" -p main.bicepparam

read -rp "Apply this deployment? [y/N] " ans
[[ "$ans" == "y" ]] || { echo "Aborted."; exit 0; }

az deployment group create -g "$RG" -n platform -p main.bicepparam \
  --query properties.outputs -o json
