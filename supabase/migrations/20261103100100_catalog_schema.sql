-- Catalog schema. Only correctness constraints here (PKs, FKs, natural keys,
-- checks). Workload indexes live in 20261103100700_scale_indexes.sql so the
-- benchmark can show plans with and without them.

create table public.brands (
  id bigint generated always as identity primary key,
  name text not null unique,
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  website text
);

create table public.sources (
  id bigint generated always as identity primary key,
  domain text not null unique check (domain = lower(domain) and domain ~ '^[a-z0-9.-]+\.[a-z]{2,}$'),
  name text not null,
  kind text not null default 'brand_site' check (kind in ('brand_site', 'retailer', 'regulatory', 'manual')),
  trust_level public.trust_level not null default 'unverified',
  trust_checked_at timestamptz,
  trust_note text,
  rate_limit_per_min int not null default 30 check (rate_limit_per_min between 1 and 600),
  created_at timestamptz not null default now()
);

create table public.products (
  id bigint generated always as identity primary key,
  brand_id bigint not null references public.brands (id),
  name text not null check (length(name) between 2 and 200),
  name_key text generated always as (lower(regexp_replace(btrim(name), '\s+', ' ', 'g'))) stored,
  category text not null check (category in ('skincare', 'haircare', 'bodycare', 'suncare')),
  product_type text not null,
  product_url text unique check (product_url ~ '^https://'),
  source_id bigint references public.sources (id),
  status public.product_status not null default 'draft',
  -- Maintained only by repair_product_ingredients (guarded by trigger).
  ingredients_hash text,
  ingredient_count int not null default 0 check (ingredient_count >= 0),
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ingredients (
  id bigint generated always as identity primary key,
  inci_name text not null check (length(inci_name) between 1 and 200),
  normalized_name text not null unique,
  common_name text,
  function text,
  is_allergen boolean not null default false,
  origin text not null default 'curated' check (origin in ('curated', 'synthetic', 'verification_queue')),
  created_at timestamptz not null default now(),
  constraint ingredients_normalized_matches check (normalized_name = public.normalize_inci(inci_name))
);

create table public.ingredient_aliases (
  alias_normalized text primary key,
  alias text not null,
  ingredient_id bigint not null references public.ingredients (id) on delete cascade,
  origin text not null default 'curated' check (origin in ('curated', 'synthetic', 'verification_queue')),
  created_at timestamptz not null default now(),
  constraint aliases_normalized_matches check (alias_normalized = public.normalize_inci(alias))
);

-- The catalog itself: an ordered (label order) list per product.
create table public.product_ingredients (
  product_id bigint not null references public.products (id) on delete cascade,
  ingredient_id bigint not null references public.ingredients (id),
  position smallint not null check (position between 1 and 300),
  raw_name text,
  provenance_kind public.provenance_kind not null,
  source_id bigint references public.sources (id),
  source_url text,
  scraped_at timestamptz,
  confidence numeric(4, 3) check (confidence between 0 and 1),
  updated_at timestamptz not null default now(),
  primary key (product_id, ingredient_id),
  -- Deferrable so a reorder can swap positions inside one statement.
  constraint product_ingredients_position_key unique (product_id, position) deferrable initially deferred,
  constraint scraped_rows_carry_evidence check (
    provenance_kind <> 'scraped'
    or (source_id is not null and source_url is not null and scraped_at is not null and confidence is not null)
  ),
  constraint ai_rows_carry_confidence check (provenance_kind <> 'ai_suggested' or confidence is not null)
);

-- AI outputs (scores + multi-provider narratives) keyed by the exact input.
-- input_hash is computed by the database, so a writer cannot claim an output
-- belongs to an ingredient list it was not generated from.
create table public.analysis_cache (
  id bigint generated always as identity primary key,
  product_id bigint not null references public.products (id) on delete cascade,
  analysis_kind text not null check (analysis_kind in ('ingredient_score', 'safety_narrative', 'routine_narrative')),
  provider text not null check (provider in ('internal', 'anthropic', 'openai', 'google')),
  model text not null,
  prompt_version text not null,
  ingredients_hash text not null,
  input_hash text generated always as (
    md5(ingredients_hash || '|' || analysis_kind || '|' || provider || '|' || model || '|' || prompt_version)
  ) stored,
  output jsonb not null,
  quarantined boolean not null default false,
  quarantine_reason text,
  quarantined_at timestamptz,
  invalidated_at timestamptz,
  invalidated_reason text,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  constraint quarantine_fields_consistent check (quarantined = (quarantined_at is not null))
);

-- Idempotent ingest bookkeeping: one row per product page URL.
create table public.ingest_pages (
  id bigint generated always as identity primary key,
  url text not null unique,
  source_id bigint not null references public.sources (id),
  product_id bigint references public.products (id) on delete set null,
  content_hash text not null,
  parsed jsonb not null,
  status text not null check (status in ('applied', 'unchanged', 'held_for_verification', 'drafted')),
  ingest_count int not null default 1,
  first_seen_at timestamptz not null default now(),
  last_ingested_at timestamptz not null default now()
);

create table public.verification_queue (
  id bigint generated always as identity primary key,
  product_id bigint references public.products (id) on delete cascade,
  ingest_page_id bigint references public.ingest_pages (id) on delete set null,
  raw_name text not null,
  normalized_name text not null,
  reason public.queue_reason not null,
  suggested_ingredient_id bigint references public.ingredients (id) on delete set null,
  similarity real,
  source_id bigint references public.sources (id),
  source_url text,
  status public.queue_status not null default 'pending',
  resolved_ingredient_id bigint references public.ingredients (id),
  resolved_by uuid,
  resolved_at timestamptz,
  resolution_note text,
  created_at timestamptz not null default now(),
  constraint queue_resolution_consistent check ((status = 'pending') = (resolved_at is null)),
  constraint queue_resolved_has_target check (status <> 'resolved' or resolved_ingredient_id is not null)
);
-- Dedupe guarantee: one open item per (product, name, reason).
create unique index verification_queue_open_dedupe
  on public.verification_queue (coalesce(product_id, 0), normalized_name, reason)
  where status = 'pending';

create table public.repair_drafts (
  id bigint generated always as identity primary key,
  product_id bigint not null references public.products (id) on delete cascade,
  proposed jsonb not null check (jsonb_typeof(proposed) = 'array'),
  provenance public.provenance_kind not null,
  source_id bigint references public.sources (id),
  reason text not null check (length(reason) between 3 and 500),
  base_hash text,
  status public.draft_status not null default 'pending',
  created_via text not null check (created_via in ('admin', 'pipeline', 'verification', 'ai')),
  created_by uuid,
  created_at timestamptz not null default now(),
  reviewed_by uuid,
  reviewed_at timestamptz,
  review_note text,
  applied_audit_id bigint,
  constraint draft_review_consistent check ((status = 'pending') = (reviewed_at is null))
);
-- The same proposal for the same product is never queued twice.
create unique index repair_drafts_open_dedupe
  on public.repair_drafts (product_id, md5(proposed::text))
  where status = 'pending';

-- Append-only. No FK to products: the trail must outlive the rows it describes.
create table public.audit_log (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default clock_timestamp(),
  actor_id uuid,
  actor_kind text not null,
  action text not null,
  entity text not null,
  entity_id text,
  product_id bigint,
  diff jsonb not null default '{}',
  context jsonb not null default '{}'
);

create table public.ingest_dead_letter (
  id bigint generated always as identity primary key,
  url text not null,
  source_id bigint references public.sources (id),
  stage text not null check (stage in ('rate_limit', 'fetch', 'parse', 'apply')),
  error text not null,
  http_status int,
  attempts int not null default 1,
  payload jsonb not null default '{}',
  status text not null default 'pending' check (status in ('pending', 'retrying', 'resolved', 'abandoned')),
  next_retry_at timestamptz,
  first_failed_at timestamptz not null default now(),
  last_failed_at timestamptz not null default now()
);
create unique index ingest_dead_letter_open_url
  on public.ingest_dead_letter (url)
  where status in ('pending', 'retrying');

create table public.data_quality_reports (
  id bigint generated always as identity primary key,
  run_at timestamptz not null default now(),
  duration_ms int not null,
  products_total int not null,
  published_total int not null,
  missing_ingredients int not null,
  duplicate_groups int not null,
  low_provenance_products int not null,
  stale_cache_rows int not null,
  quarantined_cache_rows int not null,
  untrusted_source_products int not null,
  pending_queue int not null,
  oldest_pending_hours numeric,
  stale_drafts int not null,
  provenance_mix jsonb not null,
  samples jsonb not null
);

create table public.hygiene_runs (
  id bigint generated always as identity primary key,
  job text not null,
  started_at timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  ok boolean,
  details jsonb not null default '{}'
);

-- Fixed-window rate limiter state, per source.
create table private.source_rate_windows (
  source_id bigint not null references public.sources (id) on delete cascade,
  window_start timestamptz not null,
  used int not null,
  primary key (source_id, window_start)
);

-- Mocked URL trust checks (stand-in for the real HTTP/TLS/redirect probe).
create table private.url_check_mock (
  domain text primary key,
  http_status int not null default 200,
  tls_ok boolean not null default true,
  final_domain text
);
