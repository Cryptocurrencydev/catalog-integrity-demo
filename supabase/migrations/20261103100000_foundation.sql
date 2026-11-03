-- Foundation: extensions, schemas, enums, caller identity, INCI normalisation.
--
-- Everything that decides "who is calling" and "what does this ingredient name
-- mean" lives here, in the database, so every write path (RPC, pipeline,
-- cron, SQL editor) gets the same answer.

create extension if not exists pg_trgm with schema extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_cron;

-- private: helpers, rate-limit state, mocks. Never exposed through the Data API.
create schema if not exists private;
revoke all on schema private from public;

-- Provenance is ordered by trust: later labels outrank earlier ones.
-- Comparisons like `provenance_kind > 'scraped'` rely on this order.
create type public.provenance_kind as enum ('ai_suggested', 'scraped', 'manual', 'verified');
create type public.trust_level as enum ('blocked', 'suspect', 'unverified', 'trusted');
create type public.product_status as enum ('draft', 'published', 'archived');
create type public.queue_status as enum ('pending', 'resolved', 'rejected');
create type public.queue_reason as enum ('unknown_ingredient', 'low_confidence', 'alias_conflict');
create type public.draft_status as enum ('pending', 'applied', 'rejected', 'stale');

-- Tunables the integrity rules read. One row, edited only by migrations / SQL editor.
create table private.settings (
  id boolean primary key default true check (id),
  min_scraped_confidence numeric(4, 3) not null default 0.900,
  fuzzy_suggest_threshold real not null default 0.45,
  max_ingredients_per_product int not null default 120,
  cache_invalidated_retention interval not null default '30 days',
  learned_ingredient_grace interval not null default '30 days'
);
insert into private.settings default values;

-- ---------------------------------------------------------------------------
-- Caller identity
-- ---------------------------------------------------------------------------
-- 'service' : service_role JWT (edge functions, workers)
-- 'admin'   : authenticated user whose app_metadata.role = 'admin'
--             (app_metadata is only writable with the service key)
-- 'system'  : no JWT at all and a superuser session (pg_cron, migrations, psql)
-- 'user'    : anyone else (anon, ordinary authenticated users)
create or replace function private.caller_kind()
returns text
language sql
stable
set search_path = ''
as $$
  with c as (
    select nullif(current_setting('request.jwt.claims', true), '')::jsonb as claims
  )
  select case
    when (select claims ->> 'role' from c) = 'service_role' then 'service'
    when (select claims -> 'app_metadata' ->> 'role' from c) = 'admin'
         and (select claims ->> 'role' from c) = 'authenticated' then 'admin'
    when (select claims from c) is null
         and session_user in ('postgres', 'supabase_admin')
         and current_setting('role') in ('none', 'postgres') then 'system'
    else 'user'
  end
$$;

create or replace function private.is_admin()
returns boolean
language sql
stable
set search_path = ''
as $$
  select private.caller_kind() in ('admin', 'system')
$$;

create or replace function private.actor_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid
$$;

-- ---------------------------------------------------------------------------
-- INCI normalisation (mirrored 1:1 in supabase/functions/_shared/inci.ts;
-- tests/normalize_vectors.json is checked against both implementations).
-- ---------------------------------------------------------------------------
-- lower-case, fold accents, unify dashes/quotes, drop footnote markers
-- (* † ‡ ° ^ ¹ ² ³), tighten spacing around / - , and collapse whitespace,
-- British "sulph" -> "sulf", strip surrounding punctuation.
create or replace function public.normalize_inci(p_name text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select nullif(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(
              translate(
                lower(p_name),
                E'   ‐‑‒–—―’‘´`àáâäãåèéêëìíîïòóôöõùúûüçñÀÁÂÄÃÅÈÉÊËÌÍÎÏÒÓÔÖÕÙÚÛÜÇÑ*†‡°^¹²³',
                '   ------''''''''aaaaaaeeeeiiiiooooouuuucnaaaaaaeeeeiiiiooooouuuucn'
              ),
              '\s*([/,-])\s*', '\1', 'g'
            ),
            'sulph', 'sulf', 'g'
          ),
          '\s+', ' ', 'g'
        ),
        '^[\s.,;:]+', ''
      ),
      '[\s.,;:]+$', ''
    ),
    ''
  )
$$;

comment on function public.normalize_inci(text) is
  'Canonical comparison key for INCI names. Must match normalizeInci() in supabase/functions/_shared/inci.ts.';
