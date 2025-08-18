# scripts/verify-theorems.sh
#!/usr/bin/env bash
set -euo pipefail
docker exec -i acbp-pg psql -v ON_ERROR_STOP=1 -U postgres -d postgres < sql/verify_theorems_public_auto.sql
echo "✓ ACBP theorems verified (soundness/coverage/dedup)."
