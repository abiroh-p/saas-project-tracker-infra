#!/usr/bin/env bash
# Phase 2a: build the api and web images and push them to the registry, tagged with the git commit.
# The build runs inside ACR (az acr build), so local Docker is not needed.
#
#   BUILD_MODE=local   build with local Docker and push instead (use if ACR Tasks are blocked)
#   ONLY=api|web       build just one image
#   BACKEND_DIR        checkout containing the API Dockerfile      (default: the repo that holds infra/)
#   FRONTEND_DIR       checkout containing the web Dockerfile      (default: ../saas-project-tracker-frontend)
#
# The Dockerfiles live on chore/production-readiness (backend) and chore/containerize (frontend) until
# those are merged, so check out the right branch first.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_common.sh"

BUILD_MODE="${BUILD_MODE:-acr}"
ONLY="${ONLY:-all}"
BACKEND_DIR="${BACKEND_DIR:-$INFRA/../backend}"
FRONTEND_DIR="${FRONTEND_DIR:-$INFRA/../saas-project-tracker-frontend}"

ACR="$(acr_name)"
require "No registry in $RG. Run 01-deploy-platform.sh first." "$ACR"
LOGIN="$ACR.azurecr.io"

if [[ "$BUILD_MODE" == "local" ]]; then
  az acr login -n "$ACR"
fi

build_image() {
  local name="$1" dir branch sha tag
  dir="$(cd "$2" 2>/dev/null && pwd)" || die "$name: directory not found: $2 (set ${name^^}_DIR... see header)"
  [[ -f "$dir/Dockerfile" ]] || die "$name: no Dockerfile in $dir (wrong branch? see header)"

  # The backend image does COPY . . — never let the local secrets file ride along.
  if [[ -e "$dir/infra/.deploy.env" ]] && ! grep -qxE 'infra/?' "$dir/.dockerignore" 2>/dev/null; then
    die "$name: $dir/infra/.deploy.env would be copied into the image. Add 'infra' to $dir/.dockerignore first."
  fi

  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
  sha="$(git -C "$dir" rev-parse --short HEAD)"
  tag="$sha"
  if [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
    tag="$sha-dirty$(date -u +%d%H%M%S)"
    echo "WARN: $name has uncommitted changes, tagging $tag"
  fi

  echo ">> $name  branch=$branch  tag=$tag  mode=$BUILD_MODE"
  if [[ "$BUILD_MODE" == "local" ]]; then
    docker build -t "$LOGIN/$name:$tag" "$dir"
    docker push "$LOGIN/$name:$tag"
  else
    az acr build -r "$ACR" -t "$name:$tag" "$dir" || {
      echo "Build failed. If the error mentions TasksOperationsNotAllowed, retry with BUILD_MODE=local." >&2
      exit 1
    }
  fi
}

[[ "$ONLY" == "all" || "$ONLY" == "api" ]] && build_image api "$BACKEND_DIR"
[[ "$ONLY" == "all" || "$ONLY" == "web" ]] && build_image web "$FRONTEND_DIR"

echo
echo "Newest tags in $ACR:"
for repo in api web; do
  printf '  %-4s %s\n' "$repo" "$(azt acr repository show-tags -n "$ACR" --repository "$repo" --orderby time_desc --top 1 2>/dev/null || echo '-')"
done
echo "Next: scripts/03-deploy-apps.sh"
