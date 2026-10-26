#!/usr/bin/env bash
# Deploy the Sky Report website to Cloud Run, and optionally map a custom domain to it.
#
#   GCP_PROJECT=<project id> BASE_URL=https://<domain> \
#   SUPABASE_URL=https://<ref>.supabase.co SUPABASE_ANON_KEY=<public anon key> \
#   [DOMAIN=<domain>] [REGION=us-central1] [SERVICE=bumpcast-site] \
#   marketing/skyreport/deploy_gcp.sh
#
# The anon key is the public one the app already ships with: it can only read the Sky Report,
# the map and the accuracy stats. Re-run to ship changes. See marketing/skyreport/README.md.
set -euo pipefail

: "${GCP_PROJECT:?set GCP_PROJECT}" "${BASE_URL:?set BASE_URL}"
: "${SUPABASE_URL:?set SUPABASE_URL}" "${SUPABASE_ANON_KEY:?set SUPABASE_ANON_KEY}"
REGION="${REGION:-us-central1}"   # domain mappings need a region that supports them, like us-central1
SERVICE="${SERVICE:-bumpcast-site}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  --project "$GCP_PROJECT"

# Upload only what the image needs, not the whole repo.
CONTEXT="$(mktemp -d)"
trap 'rm -rf "$CONTEXT"' EXIT
mkdir -p "$CONTEXT/marketing/skyreport" "$CONTEXT/ios/Shared"
cp -R "$ROOT/site" "$CONTEXT/site"
cp -R "$ROOT/ios/Shared/Fonts" "$CONTEXT/ios/Shared/Fonts"
cp "$ROOT"/marketing/skyreport/{report,build_site,serve}.py "$CONTEXT/marketing/skyreport/"
cp "$ROOT/marketing/skyreport/Dockerfile" "$CONTEXT/Dockerfile"

gcloud run deploy "$SERVICE" --source "$CONTEXT" --project "$GCP_PROJECT" --region "$REGION" \
  --allow-unauthenticated --min-instances 0 --max-instances 4 --memory 256Mi --cpu 1 --concurrency 80 \
  --set-env-vars "BASE_URL=${BASE_URL},SUPABASE_URL=${SUPABASE_URL},SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}"

URL="$(gcloud run services describe "$SERVICE" --project "$GCP_PROJECT" --region "$REGION" --format 'value(status.url)')"
echo "Live at $URL  (check $URL/routes/ and $URL/healthz)"

if [[ -n "${DOMAIN:-}" ]]; then
  # The domain must be verified for this Google account first: gcloud domains verify "$DOMAIN"
  if ! gcloud beta run domain-mappings describe --domain "$DOMAIN" --project "$GCP_PROJECT" --region "$REGION" >/dev/null 2>&1; then
    gcloud beta run domain-mappings create --service "$SERVICE" --domain "$DOMAIN" \
      --project "$GCP_PROJECT" --region "$REGION"
  fi
  echo "Add these DNS records at your registrar (the certificate follows within about an hour):"
  gcloud beta run domain-mappings describe --domain "$DOMAIN" --project "$GCP_PROJECT" --region "$REGION" \
    --format 'table(status.resourceRecords[].type, status.resourceRecords[].name, status.resourceRecords[].rrdata)'
fi
