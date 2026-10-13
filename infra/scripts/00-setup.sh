#!/usr/bin/env bash
# One-time preflight (safe to re-run): subscription check, resource providers, resource group,
# local secrets file, and the monthly cost budget. Creates nothing that bills.
set -euo pipefail

LOCATION="${LOCATION:-centralindia}"
RG="${RG:-rg-ptracker-prod}"
MONTHLY_BUDGET="${MONTHLY_BUDGET:-40}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$(cd "$HERE/.." && pwd)"
ENV_FILE="$INFRA/.deploy.env"

az account show >/dev/null 2>&1 || az login --use-device-code
SUB_NAME="$(az account show --query name -o tsv)"
SUB_ID="$(az account show --query id -o tsv)"
ALERT_EMAIL="${ALERT_EMAIL:-$(az account show --query user.name -o tsv)}"
echo "Subscription : $SUB_NAME ($SUB_ID)"
echo "Region / RG  : $LOCATION / $RG"
echo "Alert email  : $ALERT_EMAIL"
read -rp "Continue with this subscription? [y/N] " ans
[[ "$ans" == "y" ]] || { echo "Aborted."; exit 1; }

# Refuse to create a secrets file that git could pick up.
if git -C "$INFRA" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$INFRA" check-ignore -q "$ENV_FILE" || {
    echo "ERROR: add 'infra/.deploy.env' to .gitignore first, then re-run."; exit 1; }
fi

echo ">> Registering resource providers (first time can take a few minutes)"
for ns in Microsoft.App Microsoft.OperationalInsights Microsoft.ContainerRegistry \
          Microsoft.DBforPostgreSQL Microsoft.Insights Microsoft.ManagedIdentity Microsoft.Consumption; do
  az provider register --namespace "$ns" --wait
done

echo ">> Resource group"
az group create -n "$RG" -l "$LOCATION" \
  --tags project=saas-project-tracker environment=prod -o none

if [[ ! -f "$ENV_FILE" ]]; then
  echo ">> Generating secrets into $ENV_FILE (chmod 600)"
  umask 077
  cat > "$ENV_FILE" <<EOS
export DB_ADMIN_PASSWORD='Pt1$(openssl rand -hex 20)'
export DJANGO_SECRET_KEY='$(openssl rand -base64 60 | tr -d '\n=+/')'
EOS
else
  echo ">> Keeping existing $ENV_FILE"
fi

echo ">> Monthly budget ($MONTHLY_BUDGET) with email alerts"
az deployment sub create -l "$LOCATION" -n ptracker-budget -f "$INFRA/budget.bicep" \
  -p monthlyBudget="$MONTHLY_BUDGET" contactEmails="[\"$ALERT_EMAIL\"]" \
  startDate="$(date -u +%Y-%m-01T00:00:00Z)" -o none \
  || echo "WARN: budget not created (offer may not support it). Watch the Credits blade in Cost Management instead."

echo "Done. Next: scripts/01-deploy-platform.sh"
