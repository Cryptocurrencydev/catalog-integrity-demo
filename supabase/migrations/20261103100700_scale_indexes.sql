-- Workload indexes for 40k+ products / 1M+ list rows.
-- Kept in their own migration so scripts/bench.sh can drop them, capture the
-- "before" plans at 50k, re-apply this file and capture "after".

-- Product page + reverse lookup ("which products contain niacinamide?").
-- The PK (product_id, ingredient_id) serves the page; this serves the reverse.
create index if not exists product_ingredients_ingredient_idx
  on public.product_ingredients (ingredient_id, product_id);
create index if not exists product_ingredients_scraped_source_idx
  on public.product_ingredients (source_id) where provenance_kind = 'scraped';

-- Ingredient search: trigram on canonical names and aliases (substring + fuzzy).
create index if not exists ingredients_name_trgm
  on public.ingredients using gin (normalized_name extensions.gin_trgm_ops);
create index if not exists ingredient_aliases_trgm
  on public.ingredient_aliases using gin (alias_normalized extensions.gin_trgm_ops);
create index if not exists ingredient_aliases_ingredient_idx
  on public.ingredient_aliases (ingredient_id);

-- Product search + data-quality report.
create index if not exists products_name_trgm
  on public.products using gin (name_key extensions.gin_trgm_ops);
create index if not exists products_brand_idx on public.products (brand_id);
create index if not exists products_duplicate_key
  on public.products (brand_id, name_key, ingredients_hash) where status <> 'archived';
create index if not exists products_missing_ingredients
  on public.products (id) where status = 'published' and ingredient_count = 0;

-- Cache: one live row per exact input (doubles as cache_put's ON CONFLICT
-- target), purge by age, quarantine review list.
create unique index if not exists analysis_cache_live_key
  on public.analysis_cache (product_id, analysis_kind, provider, input_hash) where invalidated_at is null;
create index if not exists analysis_cache_invalidated_at
  on public.analysis_cache (invalidated_at) where invalidated_at is not null and not quarantined;
create index if not exists analysis_cache_quarantined
  on public.analysis_cache (quarantined_at desc) where quarantined;

-- Queues: partial indexes sized to the open backlog, not the history.
create index if not exists verification_queue_pending
  on public.verification_queue (created_at, id) where status = 'pending';
create index if not exists verification_queue_pending_name
  on public.verification_queue (normalized_name) where status = 'pending';
create index if not exists verification_queue_page
  on public.verification_queue (ingest_page_id) where ingest_page_id is not null;
create index if not exists verification_queue_product
  on public.verification_queue (product_id);
create index if not exists repair_drafts_pending
  on public.repair_drafts (created_at, id) where status = 'pending';
create index if not exists repair_drafts_product on public.repair_drafts (product_id);
create index if not exists ingest_dead_letter_due
  on public.ingest_dead_letter (next_retry_at) where status = 'pending';

-- Audit: per-product history, cheap time-range scans on an append-only heap.
create index if not exists audit_log_product
  on public.audit_log (product_id, id desc) where product_id is not null;
create index if not exists audit_log_occurred_brin
  on public.audit_log using brin (occurred_at);
