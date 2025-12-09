#!/bin/bash
# k8s/purge-gcr.sh — FINAL GCR EXECUTIONER (one-time use)
set -euo pipefail

echo "FRANK AIGRILLO FINAL PURGE INITIATED"
echo "TARGET: k8s/ directory"
echo "WEAPON: sed + fire"

cd "$(dirname "$0")" || exit 1

find . -type f \( -name "*.yaml" -o -name "*.sh" \) -print0 | while IFS= read -r -d '' file; do
  if grep -q "gcr\.io" "$file"; then
    echo "EXECUTING: $file"
    sed -i'' \
      -e 's|gcr\.io/${GCP_PROJECT_ID}|us-central1-docker.pkg.dev/${GCP_PROJECT_ID_LOWERCASE}/darkseek|g' \
      -e 's|gcr\.io/${GCP_PROJECT_ID_LOWERCASE}|us-central1-docker.pkg.dev/${GCP_PROJECT_ID_LOWERCASE}/darkseek|g' \
      -e 's|gcr\.io/\${GCP_PROJECT_ID}|us-central1-docker.pkg.dev/${GCP_PROJECT_ID_LOWERCASE}/darkseek|g' \
      -e 's|gcr\.io/\${GCP_PROJECT_ID_LOWERCASE}|us-central1-docker.pkg.dev/${GCP_PROJECT_ID_LOWERCASE}/darkseek|g' \
      -e 's|gcr\.io/[a-zA-Z0-9_-]*\/|us-central1-docker.pkg.dev/${GCP_PROJECT_ID_LOWERCASE}/darkseek/|g' \
      "$file"
  fi
done

echo "GCR PURGE COMPLETE."
if grep -r "gcr\.io" .; then
  echo "ERROR: GCR STILL DETECTED"
  exit 1
else
  echo "CONFIRMED: GCR IS DEAD IN k8s/"
  echo "VICTORY."
fi
