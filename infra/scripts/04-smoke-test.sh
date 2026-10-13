#!/usr/bin/env bash
# Smoke test through the public URL: web -> nginx -> api -> Postgres. Safe to run any time; it only
# does GETs plus one login attempt with bad credentials (nothing is written).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_common.sh"
ensure_containerapp_ext

FQDN="$(web_fqdn)"
require "No 'web' app in $RG. Run 03-deploy-apps.sh first." "$FQDN"
BASE="https://$FQDN"
echo "Target: $BASE"

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
pass=0; fail=0

ok()   { printf '  PASS  %-48s %s\n' "$1" "${2:-}"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %-48s %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }

# check "<name>" "<allowed status codes, regex>" <curl args...>
check() {
  local name="$1" want="$2" code; shift 2
  code="$(curl -s -o "$tmp" -w '%{http_code}' --max-time 60 "$@" || true)"
  if [[ "$code" =~ ^($want)$ ]]; then
    ok "$name" "$code"
  else
    bad "$name" "got $code, want $want"
    head -c 300 "$tmp" | sed 's/^/          /'; echo
  fi
}

# body_has "<name>" "<regex>"  (looks at the body of the previous check)
body_has() {
  if grep -qiE "$2" "$tmp"; then ok "$1"; else bad "$1" "pattern not found: $2"; fi
}

# The web app scales to zero, so the first request can take a while.
echo ">> Waiting for web to answer"
for _ in $(seq 1 24); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE/healthz" || true)"
  [[ "$code" == "200" ]] && break
  sleep 5
done

echo ">> Checks"
check    "web  /healthz"                               200 "$BASE/healthz"
check    "web  index.html"                             200 "$BASE/"
body_has "web  index is the Angular shell"             '<base href'
check    "web  SPA fallback (/projects)"               200 "$BASE/projects"
check    "web  plain HTTP redirects to HTTPS"          "301|302|307|308" "http://$FQDN/"

headers="$(curl -sI --max-time 30 "$BASE/" | tr -d '\r')"
if grep -qi '^x-content-type-options: nosniff' <<<"$headers" && grep -qi '^content-security-policy:' <<<"$headers"; then
  ok "web  security headers present"
else
  bad "web  security headers present" "missing nosniff or CSP"
fi

check    "api  /api/healthz via the proxy"             200 "$BASE/api/healthz"
body_has "api  liveness body"                          '"ok"'
check    "api  /api/readyz (database reachable)"       200 "$BASE/api/readyz"
check    "api  docs are off (/api/schema/)"            404 "$BASE/api/schema/"
check    "api  protected endpoint needs auth"          "401|403" "$BASE/api/v1/projects/"
check    "api  login rejects bad credentials"          "400|401" -X POST \
         -H 'Content-Type: application/json' \
         -d '{"identifier":"smoke@invalid.test","password":"not-a-real-password"}' \
         "$BASE/api/v1/accounts/login/"

echo
echo "$pass passed, $fail failed"
if (( fail > 0 )); then
  cat <<'HINT'
Hints:
  readyz 503 / timeouts     Postgres stopped or unreachable (scripts/status.sh), or DB_SSLMODE/credentials wrong
  login 500                 migration not run: scripts/migrate.sh (creates the cache table the throttle uses)
  login 301                 X-Forwarded-Proto not reaching Django (check nginx + DJANGO_BEHIND_PROXY)
  login 429                 rate limit hit (10/min); wait a minute and re-run
  api 400 DisallowedHost    DJANGO_ALLOWED_HOSTS must include "api" and .azurecontainerapps.io
HINT
  exit 1
fi
