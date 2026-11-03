#!/usr/bin/env bash
# Grow the local database to ~50k synthetic products (~1.15M list rows).
# Usage: scripts/seed-scale.sh [products=50000] [db_url]
set -euo pipefail
N="${1:-50000}"
DB="${2:-postgresql://postgres:postgres@127.0.0.1:56322/postgres}"
psql "$DB" -X -v ON_ERROR_STOP=1 -c "select synthetic.generate_catalog($N, 7);" \
  -c "select private.run_hygiene_job('quality_report');" \
  -c "vacuum analyze public.products, public.product_ingredients, public.analysis_cache, public.verification_queue, public.audit_log, public.repair_drafts;"
