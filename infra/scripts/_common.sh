#!/usr/bin/env bash
# Shared helpers for the deploy scripts. Sourced by them, never run directly.

# Git Bash on Windows rewrites arguments that start with "/" (e.g. /subscriptions/...). Switch that off.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'
# az streams build logs as UTF-8; the default Windows console codec chokes on them.
export PYTHONIOENCODING=utf-8
# Install the containerapp extension without stopping to ask.
export AZURE_EXTENSION_USE_DYNAMIC_INSTALL=yes_without_prompt

RG="${RG:-rg-ptracker-prod}"
INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

# az -o tsv on Windows ends lines with CRLF, which breaks comparisons and URLs. Strip it.
azt() { az "$@" -o tsv | tr -d '\r'; }

# Fail with a message when a value is empty or az printed "None".
require() { [[ -n "${2:-}" && "${2:-}" != "None" ]] || die "$1"; }

ensure_containerapp_ext() {
  az extension show -n containerapp >/dev/null 2>&1 || az extension add -n containerapp -y --only-show-errors
}

acr_name()  { azt acr list -g "$RG" --query "[0].name" 2>/dev/null || true; }
pg_name()   { azt postgres flexible-server list -g "$RG" --query "[0].name" 2>/dev/null || true; }
web_fqdn()  { azt containerapp show -n web -g "$RG" --query properties.configuration.ingress.fqdn 2>/dev/null || true; }
pg_state()  { azt postgres flexible-server show -g "$RG" -n "$1" --query state; }

iso_now()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch_of()  { date -u -d "$1" +%s; }
fmt_epoch() { date -u -d "@$1" '+%Y-%m-%d %H:%M UTC'; }
